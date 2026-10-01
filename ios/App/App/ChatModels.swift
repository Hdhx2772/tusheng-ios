import Foundation

// MARK: - 消息角色
enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

// MARK: - 聊天消息
struct ChatMessage: Identifiable, Equatable, Codable {
    var id: UUID
    var role: MessageRole
    var content: String
    var isStreaming: Bool = false

    // isStreaming 仅用于界面展示，不持久化
    enum CodingKeys: String, CodingKey {
        case id, role, content
    }

    init(id: UUID = UUID(), role: MessageRole, content: String, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(MessageRole.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        isStreaming = false // 历史消息一律不在“流式中”
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
    }
}

// MARK: - 聊天会话
struct ChatSession: Identifiable, Equatable, Codable {
    var id: UUID
    var title: String
    var messages: [ChatMessage]
    var nottrackChatId: String? // NotTrack 多轮上下文 chat_id
    var createdAt: Date
    var updatedAt: Date
}

// MARK: - SSE 事件模型
struct SSEEvent: Decodable {
    let type: String
    let chat_id: String?
    let message_id: String?
    let speaker: String?
    let turn: Int?
    let chunk: String?
    let content: String?
    let msg: String?
}

// MARK: - 会话与授权的全局存储
@MainActor
final class ChatStore: ObservableObject {
    @Published var sessions: [ChatSession] = []
    @Published var authorized = false
    @Published var isCheckingAuth = true
    @Published var showAuthAlert = false
    @Published var authMessage = ""

    let deviceCode: String
    private var hasCheckedAuth = false
    private let apiBase = "https://wutong.xyz/api_ai_record.php"
    private let authSession: URLSession
    private let fileURL: URL

    init(deviceCode: String) {
        self.deviceCode = deviceCode
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        self.authSession = URLSession(configuration: cfg)
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = dir.appendingPathComponent("ai_chats.json")
        load()
    }

    // 最新更新的会话排最前
    var sortedSessions: [ChatSession] {
        sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    func session(_ id: UUID) -> ChatSession? {
        sessions.first { $0.id == id }
    }

    // MARK: - 持久化
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let arr = try? dec.decode([ChatSession].self, from: data) {
            sessions = arr
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(sessions) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - 会话增删
    @discardableResult
    func createSession() -> ChatSession {
        let now = Date()
        let s = ChatSession(id: UUID(), title: "新对话", messages: [],
                            nottrackChatId: nil, createdAt: now, updatedAt: now)
        sessions.insert(s, at: 0)
        save()
        return s
    }

    func deleteSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        save()
    }

    func clearSession(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].messages.removeAll()
        sessions[i].nottrackChatId = nil
        sessions[i].title = "新对话"
        sessions[i].updatedAt = Date()
        save()
    }

    private func touch(_ i: Int) {
        sessions[i].updatedAt = Date()
    }

    // MARK: - 消息操作
    func appendMessage(_ m: ChatMessage, to id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].messages.append(m)
        // 第一条用户消息作为会话标题
        if m.role == .user && (sessions[i].title == "新对话" || sessions[i].title.isEmpty) {
            let t = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count > 20 {
                sessions[i].title = String(t.prefix(20)) + "…"
            } else {
                sessions[i].title = t
            }
        }
        touch(i)
        save()
    }

    func appendDelta(_ chunk: String, to id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        if let mi = sessions[i].messages.lastIndex(where: { $0.isStreaming }) {
            sessions[i].messages[mi].content += chunk
            touch(i)
            save()
        }
    }

    func setNottrackChatId(_ cid: String, for id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].nottrackChatId = cid
        save()
    }

    // message / consensus：用完整内容收尾
    func finishAssistant(content: String?, id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        if let mi = sessions[i].messages.lastIndex(where: { $0.isStreaming }) {
            if let content = content, !content.isEmpty {
                sessions[i].messages[mi].content = content
            }
            sessions[i].messages[mi].isStreaming = false
            touch(i)
            save()
        }
    }

    // done：正常结束；若占位仍为空则给提示
    func markDone(id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        if let mi = sessions[i].messages.lastIndex(where: { $0.isStreaming }) {
            sessions[i].messages[mi].isStreaming = false
            if sessions[i].messages[mi].content.isEmpty {
                sessions[i].messages[mi].content = "（未返回内容，请重试）"
            }
            touch(i)
            save()
        }
    }

    // 网络/服务错误：把占位气泡变成错误提示
    func failAssistant(_ msg: String, id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        if let mi = sessions[i].messages.lastIndex(where: { $0.isStreaming }) {
            sessions[i].messages[mi].content = "请求失败：\(msg)"
            sessions[i].messages[mi].isStreaming = false
            touch(i)
            save()
        }
    }

    // 网络中断但已有部分内容：保留已生成内容，追加中断提示，不覆盖
    func markInterrupted(id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        if let mi = sessions[i].messages.lastIndex(where: { $0.isStreaming }) {
            let current = sessions[i].messages[mi].content
            if current.isEmpty {
                sessions[i].messages[mi].content = "请求失败：网络中断"
            } else {
                sessions[i].messages[mi].content = current + "\n\n⚠️ 网络中断，内容可能不完整"
            }
            sessions[i].messages[mi].isStreaming = false
            touch(i)
            save()
        }
    }

    // 自动重连前清空占位气泡内容（保持 isStreaming=true），重新生成完整回复
    func resetStreamingContent(id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        if let mi = sessions[i].messages.lastIndex(where: { $0.isStreaming }) {
            sessions[i].messages[mi].content = ""
            touch(i)
            save()
        }
    }

    // MARK: - 打开界面时检查一次授权（本次打开期间缓存，不重复请求）
    func checkAuthOnOpen() async {
        guard !hasCheckedAuth else { return }
        isCheckingAuth = true
        authorized = await checkAuthorization()
        hasCheckedAuth = true
        isCheckingAuth = false
        if !authorized {
            authMessage = "当前设备未授权，请联系管理员授权后使用\n设备码：\(deviceCode)"
            showAuthAlert = true
        }
    }

    func checkAuthorization() async -> Bool {
        guard let url = URL(string: apiBase), !deviceCode.isEmpty else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "action=check_auth&device_id=\(deviceCode)".data(using: .utf8)
        do {
            let (data, _) = try await authSession.data(for: req)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let banned = json["status"] as? String, banned == "banned" {
                    authMessage = json["reason"] as? String ?? "设备已被封禁"
                    showAuthAlert = true
                    return false
                }
                return json["authorized"] as? Bool ?? false
            }
        } catch {
            NSLog("❌ [授权] 检查失败: \(error)")
        }
        return false
    }

    // MARK: - 记录使用（复用后台 upload 动作）
    func recordUsage(prompt: String) async {
        guard let url = URL(string: apiBase), !deviceCode.isEmpty else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comp = URLComponents()
        comp.queryItems = [
            URLQueryItem(name: "action", value: "upload"),
            URLQueryItem(name: "device_id", value: deviceCode),
            URLQueryItem(name: "prompt", value: "[AI对话] " + prompt)
        ]
        req.httpBody = comp.percentEncodedQuery?.data(using: .utf8)
        _ = try? await authSession.data(for: req)
    }
}
