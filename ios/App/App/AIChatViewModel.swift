import Foundation

// MARK: - AI 聊天 ViewModel（绑定到某个会话，流式逻辑）
@MainActor
final class AIChatViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var inputText = ""

    let sessionId: UUID
    private weak var store: ChatStore?
    private var streamSession: URLSession?
    private var dataTask: URLSessionDataTask?
    private var sseDelegate: SSEDelegate?

    // 关键修复：nottrack.ai 在国内 DNS 无法解析（实测直连失败、永久“思考中”），
    // 官方备用域名 nottrack.com 接口完全相同，国内直连实测 HTTP 200 且 SSE 正常。
    private let apiURL = "https://nottrack.com/api/dispatch"

    init(store: ChatStore, sessionId: UUID) {
        self.store = store
        self.sessionId = sessionId
    }

    var messages: [ChatMessage] {
        store?.session(sessionId)?.messages ?? []
    }

    // MARK: - 发送消息
    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }
        guard let store = store else { return }

        guard store.authorized else {
            store.authMessage = "当前设备未授权，请联系管理员授权后使用\n设备码：\(store.deviceCode)"
            store.showAuthAlert = true
            return
        }

        inputText = ""
        isLoading = true

        // 用户消息 + AI 占位气泡
        store.appendMessage(ChatMessage(role: .user, content: text), to: sessionId)
        store.appendMessage(ChatMessage(role: .assistant, content: "", isStreaming: true), to: sessionId)

        // 后台记录使用
        await store.recordUsage(prompt: text)

        // 发起流式请求
        await sendStreamRequest(text: text)
    }

    // MARK: - SSE 流式请求
    private func sendStreamRequest(text: String) async {
        guard let url = URL(string: apiURL) else {
            store?.failAssistant("无效的 API 地址", id: sessionId)
            isLoading = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/147.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://nottrack.com", forHTTPHeaderField: "Origin")
        request.setValue("https://nottrack.com/zh-CN/chat", forHTTPHeaderField: "Referer")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        let chatId = store?.session(sessionId)?.nottrackChatId
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

        let sid = sessionId
        let delegate = SSEDelegate(
            onEvent: { [weak self] event in
                Task { @MainActor in self?.handleSSEEvent(event) }
            },
            onError: { [weak self] msg in
                Task { @MainActor in self?.store?.failAssistant(msg, id: sid) }
            }
        )
        self.sseDelegate = delegate

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 180
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: .main)
        self.streamSession = session

        NSLog("🚀 [SSE] 开始请求 \(self.apiURL)，续聊 chat_id: \(chatId ?? "首轮(nil)")")

        // 等待连接结束（成功或失败都会回调 onComplete）
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegate.onComplete = { continuation.resume() }
            let task = session.dataTask(with: request)
            self.dataTask = task
            task.resume()
        }

        // 兜底：正常情况下 message/done 已收尾；若占位仍在流式（空响应等），这里补上结束状态
        store?.markDone(id: sessionId)
        isLoading = false
    }

    // MARK: - 处理 SSE 事件
    private func handleSSEEvent(_ event: SSEEvent) {
        guard let store = store else { return }
        switch event.type {
        case "chat_meta":
            if let cid = event.chat_id {
                store.setNottrackChatId(cid, for: sessionId)
            }
        case "delta":
            if let chunk = event.chunk {
                store.appendDelta(chunk, to: sessionId)
            }
        case "message", "consensus":
            store.finishAssistant(content: event.content, id: sessionId)
        case "done":
            store.markDone(id: sessionId)
        case "error":
            store.failAssistant(event.msg ?? "服务返回错误", id: sessionId)
        default:
            // thinking / busy / user 等事件无需处理
            break
        }
    }

    // MARK: - 清空当前会话
    func clearChat() {
        store?.clearSession(sessionId)
    }

    // MARK: - 停止生成
    func stopGeneration() {
        dataTask?.cancel()
        store?.markDone(id: sessionId)
        isLoading = false
    }
}

// MARK: - SSE URLSession Delegate（带完整日志与错误回调）
class SSEDelegate: NSObject, URLSessionDataDelegate {
    private var buffer = ""
    private let onEvent: (SSEEvent) -> Void
    private let onError: (String) -> Void
    var onComplete: (() -> Void)?

    private var httpOK = false
    private var statusCode = 0
    private var finished = false

    init(onEvent: @escaping (SSEEvent) -> Void, onError: @escaping (String) -> Void) {
        self.onEvent = onEvent
        self.onError = onError
    }

    // 收到响应头：记录状态码
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            statusCode = http.statusCode
            httpOK = (200...299).contains(http.statusCode)
            NSLog("🔵 [SSE] 响应状态: \(http.statusCode)，Content-Type: \(http.mimeType ?? "-")")
        }
        completionHandler(.allow)
    }

    // 收到数据：按 SSE 协议切分事件
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        buffer += text
        // 统一换行符，兼容 \r\n / \r
        buffer = buffer.replacingOccurrences(of: "\r\n", with: "\n")
                       .replacingOccurrences(of: "\r", with: "\n")

        let blocks = buffer.components(separatedBy: "\n\n")
        buffer = blocks.last ?? ""

        for block in blocks.dropLast() {
            let lines = block.components(separatedBy: "\n")
            for line in lines {
                var l = line
                guard l.hasPrefix("data:") else { continue }
                l = String(l.dropFirst(5))
                if l.hasPrefix(" ") { l = String(l.dropFirst()) }
                guard let jsonData = l.data(using: .utf8),
                      let event = try? JSONDecoder().decode(SSEEvent.self, from: jsonData) else {
                    NSLog("⚠️ [SSE] 无法解析: \(l.prefix(120))")
                    continue
                }
                NSLog("🟢 [SSE] 事件: \(event.type)")
                onEvent(event)
            }
        }
    }

    // 请求结束（成功 error=nil；失败/取消携带 error）
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                NSLog("🟡 [SSE] 请求被取消（用户停止）")
            } else {
                NSLog("🔴 [SSE] 请求错误: \(error.localizedDescription)（\(ns.domain) \(ns.code)）")
                onError(error.localizedDescription)
            }
        } else if !httpOK {
            NSLog("🔴 [SSE] HTTP 异常状态码: \(statusCode)")
            onError("服务器返回状态码 \(statusCode)")
        } else {
            NSLog("✅ [SSE] 请求正常结束")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if !self.finished {
                self.finished = true
                self.onComplete?()
            }
        }
    }
}
