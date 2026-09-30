import Foundation

// MARK: - 聊天消息模型
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: MessageRole
    var content: String
    var isStreaming: Bool = false
    
    enum MessageRole: String {
        case user
        case assistant
        case system
    }
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

// MARK: - AI 聊天 ViewModel
@MainActor
final class AIChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isLoading: Bool = false
    @Published var inputText: String = ""
    @Published var showAuthAlert: Bool = false
    @Published var authMessage: String = ""
    
    private var chatId: String? = nil
    private var urlSession: URLSession?
    private var dataTask: URLSessionDataTask?
    private var sseDelegate: SSEDelegate?
    
    // 授权配置
    private let authURL = "https://wutong.xyz/api_ai_record.php"
    private let recordURL = "https://wutong.xyz/api_ai_record.php"
    private let apiURL = "https://nottrack.ai/api/dispatch"
    
    // 设备码
    private var deviceCode: String {
        if let saved = UserDefaults.standard.string(forKey: "dev_code") {
            return saved
        }
        let code = "DEV_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        UserDefaults.standard.set(code, forKey: "dev_code")
        return code
    }
    
    init() {
        // 普通请求用的 session
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        urlSession = URLSession(configuration: config)
    }
    
    // MARK: - 检查授权
    func checkAuthorization() async -> Bool {
        guard let url = URL(string: authURL) else { return false }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = "action=check_auth&device_id=\(deviceCode)"
        request.httpBody = body.data(using: .utf8)
        
        do {
            let (data, _) = try await urlSession!.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let banned = json["status"] as? String, banned == "banned" {
                    authMessage = json["reason"] as? String ?? "设备已被封禁"
                    showAuthAlert = true
                    return false
                }
                return json["authorized"] as? Bool ?? false
            }
        } catch {
            print("授权检查失败: \(error)")
        }
        return false
    }
    
    // MARK: - 记录使用
    private func recordUsage() async {
        guard let url = URL(string: recordURL) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = "action=record&device_id=\(deviceCode)&type=ai_chat"
        request.httpBody = body.data(using: .utf8)
        
        _ = try? await urlSession!.data(for: request)
    }
    
    // MARK: - 发送消息
    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }
        
        // 检查授权
        let authorized = await checkAuthorization()
        guard authorized else {
            authMessage = "未授权，请先在后台授权设备"
            showAuthAlert = true
            return
        }
        
        inputText = ""
        isLoading = true
        
        // 添加用户消息
        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        
        // 添加 AI 占位消息
        let assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMessage)
        
        // 记录使用
        await recordUsage()
        
        // 发送流式请求
        await sendStreamRequest(text: text)
    }
    
    // MARK: - 发送 SSE 流式请求
    private func sendStreamRequest(text: String) async {
        guard let url = URL(string: apiURL) else {
            finishWithError("无效的 API 地址")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/147.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://nottrack.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://nottrack.ai/zh-CN/chat", forHTTPHeaderField: "Referer")
        
        let payload: [String: Any] = [
            "user_input": text,
            "mode": "usual",
            "model": "C",
            "persona": "normal",
            "max_turns": 3,
            "chat_id": chatId ?? NSNull(),
            "attachments": [],
            "regenerate": false,
            "edit": false,
            "edit_mid": NSNull(),
            "via": "typed"
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        
        // 创建 SSE delegate
        let delegate = SSEDelegate { [weak self] event in
            self?.handleSSEEvent(event)
        }
        self.sseDelegate = delegate
        
        // 流式请求用的 session
        let streamConfig = URLSessionConfiguration.default
        streamConfig.timeoutIntervalForRequest = 120
        streamConfig.timeoutIntervalForResource = 300
        let streamSession = URLSession(configuration: streamConfig, delegate: delegate, delegateQueue: .main)
        
        // 使用 withCheckedContinuation 等待任务完成
        await withCheckedContinuation { continuation in
            delegate.onComplete = {
                continuation.resume()
            }
            
            let task = streamSession.dataTask(with: request)
            self.dataTask = task
            task.resume()
        }
        
        isLoading = false
    }
    
    // MARK: - 处理 SSE 事件
    private func handleSSEEvent(_ event: SSEEvent) {
        switch event.type {
        case "chat_meta":
            chatId = event.chat_id
        case "delta":
            if let chunk = event.chunk, let index = messages.lastIndex(where: { $0.isStreaming }) {
                messages[index].content += chunk
            }
        case "message", "consensus":
            if let content = event.content, let index = messages.lastIndex(where: { $0.isStreaming }) {
                messages[index].content = content
                messages[index].isStreaming = false
            }
        case "done":
            if let index = messages.lastIndex(where: { $0.isStreaming }) {
                messages[index].isStreaming = false
            }
        case "error":
            finishWithError(event.msg ?? "未知错误")
        default:
            break
        }
    }
    
    // MARK: - 错误处理
    private func finishWithError(_ message: String) {
        if let index = messages.lastIndex(where: { $0.isStreaming }) {
            messages[index].content = "错误: \(message)"
            messages[index].isStreaming = false
        }
        isLoading = false
    }
    
    // MARK: - 清空对话
    func clearChat() {
        messages.removeAll()
        chatId = nil
    }
    
    // MARK: - 停止生成
    func stopGeneration() {
        dataTask?.cancel()
        isLoading = false
        if let index = messages.lastIndex(where: { $0.isStreaming }) {
            messages[index].isStreaming = false
        }
    }
}

// MARK: - SSE URLSession Delegate
class SSEDelegate: NSObject, URLSessionDataDelegate {
    private var buffer = ""
    private let onEvent: (SSEEvent) -> Void
    var onComplete: (() -> Void)?
    
    init(onEvent: @escaping (SSEEvent) -> Void) {
        self.onEvent = onEvent
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        buffer += text
        
        // 按空行分割事件
        let events = buffer.components(separatedBy: "\n\n")
        buffer = events.last ?? ""
        
        for eventText in events.dropLast() {
            let lines = eventText.components(separatedBy: "\n")
            for line in lines {
                if line.hasPrefix("data: ") {
                    let jsonString = String(line.dropFirst(6))
                    if let jsonData = jsonString.data(using: .utf8),
                       let event = try? JSONDecoder().decode(SSEEvent.self, from: jsonData) {
                        DispatchQueue.main.async { [weak self] in
                            self?.onEvent(event)
                        }
                    }
                }
            }
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("请求完成，错误: \(error)")
        }
        DispatchQueue.main.async { [weak self] in
            self?.onComplete?()
        }
    }
}
