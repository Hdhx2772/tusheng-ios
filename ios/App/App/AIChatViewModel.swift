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

    // 自动重连：网络中断（切后台/断网）时自动恢复，避免直接显示"生成失败"
    private var pendingText: String?          // 当前请求的文本，用于重连
    private var retryCount = 0
    private let maxRetry = 2                  // 最多自动重连 2 次
    private var isRetrying = false            // 当前请求已被重连接管，收尾时跳过
    private var lastDataTime = Date()         // 最后收到 SSE 数据的时间（心跳检测）

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
        pendingText = text
        retryCount = 0
        lastDataTime = Date()

        // 用户消息 + AI 占位气泡
        store.appendMessage(ChatMessage(role: .user, content: text), to: sessionId)
        store.appendMessage(ChatMessage(role: .assistant, content: "", isStreaming: true), to: sessionId)

        // 后台记录使用
        await store.recordUsage(prompt: text)

        // 发起流式请求
        await sendStreamRequest(text: text)
    }

    // MARK: - SSE 流式请求
    // isRetry=true 表示自动重连：不再新增占位气泡，复用现有 streaming 气泡继续输出
    private func sendStreamRequest(text: String, isRetry: Bool = false) async {
        guard let url = URL(string: apiURL) else {
            if !isRetry {
                store?.failAssistant("无效的 API 地址", id: sessionId)
            }
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
        request.timeoutInterval = 120

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
            onError: { [weak self] msg, error in
                Task { @MainActor in self?.handleStreamError(msg, error: error) }
            }
        )
        self.sseDelegate = delegate

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300    // 两次数据到达之间的空闲超时，长文本思考期可能较长
        cfg.timeoutIntervalForResource = 900   // 总时长上限 15 分钟，避免长文本生成超时
        cfg.waitsForConnectivity = true        // 网络恢复后自动继续（切后台/断网恢复）
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: .main)
        self.streamSession = session

        if isRetry {
            NSLog("🔄 [SSE] 自动重连请求，续聊 chat_id: \(chatId ?? "首轮(nil)")")
        } else {
            NSLog("🚀 [SSE] 开始请求 \(self.apiURL)，续聊 chat_id: \(chatId ?? "首轮(nil)")")
        }

        // 等待连接结束（成功或失败都会回调 onComplete）
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegate.onComplete = { continuation.resume() }
            let task = session.dataTask(with: request)
            self.dataTask = task
            task.resume()
        }

        // 兜底：正常情况下 message/done 已收尾；若占位仍在流式（空响应等），这里补上结束状态。
        // 注意：若本请求已被错误处理器标记为"重连接管"，则跳过收尾，
        // 避免把占位气泡提前结束、导致重连后的 delta 无处追加。
        if isRetrying {
            isRetrying = false
            return
        }
        store?.markDone(id: sessionId)
        isLoading = false
    }

    // MARK: - 处理 SSE 错误（含自动重连逻辑）
    private func handleStreamError(_ msg: String, error: Error?) {
        let nsError = error as NSError?
        let code = nsError?.code ?? -1
        // 可恢复的网络类错误：切后台连接被系统断开、断网、超时等
        let recoverableCodes: [Int] = [
            NSURLErrorTimedOut,                // -1001
            NSURLErrorCannotFindHost,          // -1003
            NSURLErrorCannotConnectToHost,     // -1004
            NSURLErrorNetworkConnectionLost,   // -1005
            NSURLErrorDNSLookupFailed,         // -1006
            NSURLErrorNotConnectedToInternet,  // -1009
            NSURLErrorInternationalRoamingOff  // -1018
        ]
        let isRecoverable = recoverableCodes.contains(code)
        let hasContent = !(store?.session(sessionId)?.messages.last?.content.isEmpty ?? true)

        if isRecoverable && !hasContent && retryCount < maxRetry {
            // 尚未收到任何内容就断了（刚发消息/思考中）：自动重连继续
            retryCount += 1
            let text = pendingText ?? ""
            isRetrying = true   // 标记旧请求被接管，避免其收尾提前结束占位气泡
            NSLog("🔄 [SSE] 网络错误(\(code))，自动重连 \(retryCount)/\(maxRetry)")
            Task { await sendStreamRequest(text: text, isRetry: true) }
            return
        }

        if hasContent {
            // 已有部分内容：绝不自动清空重来。内容已实时缓存到本地文件，
            // 保留现状并标记"已保存"，由用户决定是否重新生成。
            store?.markInterrupted(id: sessionId)
            isLoading = false
            return
        }

        // 其他错误：正常失败提示
        store?.failAssistant(msg, id: sessionId)
        isLoading = false
    }

    // MARK: - 处理 SSE 事件
    private func handleSSEEvent(_ event: SSEEvent) {
        guard let store = store else { return }
        // 心跳：收到任何事件都刷新最后活动时间
        lastDataTime = Date()
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

    // MARK: - 回前台恢复（切后台回来时，若任务已断且占位仍在流式，自动重连）
    func resumeIfNeeded() {
        guard isLoading else { return }
        guard let store = store,
              store.session(sessionId)?.messages.last?.isStreaming == true else { return }
        // 三种情况判定连接是否已死：
        // 1) dataTask 已结束（didComplete 已触发）但占位还在流式 → 连接已断
        // 2) dataTask 仍挂着但超过 20 秒没有任何 SSE 数据 → 实际已断（waitsForConnectivity 等待中）
        let taskEnded = (dataTask == nil || dataTask?.state == .completed)
        let silentTooLong = Date().timeIntervalSince(lastDataTime) > 20
        guard taskEnded || silentTooLong else { return }

        // 已有内容：保留（已实时缓存），不清空重来，标记已保存即可
        if !(store.session(sessionId)?.messages.last?.content.isEmpty ?? true) {
            store.markInterrupted(id: sessionId)
            isLoading = false
            return
        }
        // 尚无内容（刚发消息就切后台）：自动重连继续生成
        guard retryCount < maxRetry else {
            store.markInterrupted(id: sessionId)
            isLoading = false
            return
        }
        retryCount += 1
        let text = pendingText ?? ""
        isRetrying = true
        NSLog("🔄 [SSE] 回前台恢复，自动重连 \(retryCount)/\(maxRetry)")
        Task { await sendStreamRequest(text: text, isRetry: true) }
    }

    // MARK: - 重新生成中断的回复（用户主动点击，保留原问题重新生成完整内容）
    func retryGeneration(messageId: UUID? = nil) {
        guard !isLoading else { return }
        guard let store = store,
              let text = pendingText, !text.isEmpty else { return }
        guard store.authorized else {
            store.authMessage = "当前设备未授权，请联系管理员授权后使用\n设备码：\(store.deviceCode)"
            store.showAuthAlert = true
            return
        }
        // 若指定了消息 ID，只允许重试该条中断消息；未指定则回退到最后一条 assistant
        if let mid = messageId {
            guard let m = store.session(sessionId)?.messages.last(where: { $0.id == mid }),
                  m.role == .assistant, m.isInterrupted else { return }
        } else {
            guard let last = store.session(sessionId)?.messages.last,
                  last.role == .assistant, last.isInterrupted else { return }
        }
        // 把目标中断的 AI 消息清空并重新置为流式，复用占位气泡
        store.resetInterruptedMessage(id: sessionId, messageId: messageId)
        isLoading = true
        retryCount = 0
        lastDataTime = Date()
        Task { await sendStreamRequest(text: text) }
    }

    // MARK: - 停止生成
    func stopGeneration() {
        dataTask?.cancel()
        isRetrying = false
        store?.markDone(id: sessionId)
        isLoading = false
    }
}

// MARK: - SSE URLSession Delegate（带完整日志与错误回调）
class SSEDelegate: NSObject, URLSessionDataDelegate {
    private var buffer = ""
    private let onEvent: (SSEEvent) -> Void
    private let onError: (String, Error?) -> Void
    var onComplete: (() -> Void)?

    private var httpOK = false
    private var statusCode = 0
    private var finished = false

    init(onEvent: @escaping (SSEEvent) -> Void, onError: @escaping (String, Error?) -> Void) {
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
        // 关键修复：不能用 String(data:encoding:) —— UTF-8 多字节字符被拆到两个
        // data 块时会解码失败返回 nil，导致整块数据丢失（长文本生成时必现）。
        // String(decoding:as:) 永不解码失败，可安全拼接。
        let text = String(decoding: data, as: UTF8.self)
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
                onError(error.localizedDescription, error)
            }
        } else if !httpOK {
            NSLog("🔴 [SSE] HTTP 异常状态码: \(statusCode)")
            onError("服务器返回状态码 \(statusCode)", nil)
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
