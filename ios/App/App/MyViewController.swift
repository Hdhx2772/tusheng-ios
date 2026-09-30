import UIKit
import Capacitor
import CommonCrypto

class MyViewController: CAPBridgeViewController, WKNavigationDelegate {
    
    private var nativeLogs: [String] = []
    
    // SSL Pinning：只对这些域名做证书锁定
    // 其他域名（freemaker.net、r2.dev 等）走系统默认验证
    private let pinnedHosts: Set<String> = ["wutong.xyz", "www.wutong.xyz"]
    
    // 允许的公钥 SHA-256 哈希（Base64）
    // 用公钥而非证书，证书续期后公钥不变，无需更新 App
    private let pinnedPublicKeyHashes: Set<String> = [
        "0N5PsYbLsX3MHFyWp0KwqcgC++uJ9Brzwv3yphZzpTo=" // wutong.xyz 公钥
    ]
    
    // 保存 Capacitor 原始 delegate，避免覆盖内部逻辑
    private weak var capDelegate: WKNavigationDelegate?
    
    private func log(_ msg: String) {
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss.SSS"
        let timestamp = time.string(from: Date())
        let entry = "[\(timestamp)][NATIVE] \(msg)"
        nativeLogs.append(entry)
        print(entry)
        sendLogsToJS()
    }
    
    private func sendLogsToJS() {
        guard let webView = bridge?.webView else { return }
        let logsJson = nativeLogs.map { $0.replacingOccurrences(of: "'", with: "\\'") }.joined(separator: "\\n")
        let js = "if(window.nativeLog){window.nativeLog('\(logsJson)')}"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
    
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        log("MyViewController init(nibName) 被调用")
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        log("MyViewController init(coder) 被调用")
    }
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        log("MyViewController viewDidLoad, bridge=\(String(describing: bridge))")
        
        // 接管 WKWebView 的 navigationDelegate 以实现 SSL Pinning
        if let webView = bridge?.webView {
            capDelegate = webView.navigationDelegate
            webView.navigationDelegate = self
            log("✅ SSL Pinning 已启用，锁定域名: \(pinnedHosts.joined(separator: ", "))")
        }
    }
    
    override open func capacitorDidLoad() {
        super.capacitorDidLoad()
        log("MyViewController capacitorDidLoad 被调用, bridge=\(String(describing: bridge))")
        
        guard let bridge = bridge else {
            log("❌ capacitorDidLoad: bridge 为 nil，无法注册插件")
            return
        }
        
        bridge.registerPluginInstance(PhotoSaver())
        log("✅ PhotoSaver 已注册")
        bridge.registerPluginInstance(Notifier())
        log("✅ Notifier 已注册")
        bridge.registerPluginInstance(BackgroundAudio())
        log("✅ BackgroundAudio 已注册")
        
        // 注册 AI 对话插件（带错误捕获）
        do {
            let plugin = AIChatPlugin()
            log("🔍 AIChatPlugin 实例创建成功: \(type(of: plugin)), jsName=\(plugin.jsName), className=\(NSStringFromClass(type(of: plugin)))")
            bridge.registerPluginInstance(plugin)
            log("✅ AIChatPlugin 已注册, jsName=\(plugin.jsName)")
        } catch {
            log("❌ AIChatPlugin 注册失败: \(error.localizedDescription)")
        }
        
        log("✅ 所有自定义插件注册完成")
        
        // 在 JS 端手动注册 AIChatPlugin（需要先添加 PluginHeaders 声明原生方法，再 registerPlugin）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.bridge?.webView?.evaluateJavaScript("""
            (function() {
                try {
                    if (!window.Capacitor) return;
                    // 1. 先添加 PluginHeaders，声明原生方法列表（openChat 返回 promise）
                    if (!Capacitor.PluginHeaders) Capacitor.PluginHeaders = [];
                    if (!Capacitor.PluginHeaders.find(function(p){return p.name==='AIChatPlugin';})) {
                        Capacitor.PluginHeaders.push({
                            name: 'AIChatPlugin',
                            methods: [{ name: 'openChat', rtype: 'promise' }]
                        });
                    }
                    // 2. 再注册插件代理
                    if (Capacitor.registerPlugin && !Capacitor.Plugins.AIChatPlugin) {
                        Capacitor.registerPlugin('AIChatPlugin');
                        console.log('JS端手动注册 AIChatPlugin 成功');
                    }
                } catch(e) {
                    console.log('JS端注册 AIChatPlugin 失败: ' + e.message);
                }
            })()
            """)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.checkPluginsInJS()
        }
    }
    
    private func checkPluginsInJS() {
        guard let webView = bridge?.webView else { return }
        let js = """
        (function() {
            var plugins = Object.keys(Capacitor.Plugins).join(', ');
            var hasPhotoSaver = !!Capacitor.Plugins.PhotoSaver;
            var hasNotifier = !!Capacitor.Plugins.Notifier;
            var hasBackgroundAudio = !!Capacitor.Plugins.BackgroundAudio;
            return 'JS插件列表: ' + plugins + ' | PhotoSaver=' + hasPhotoSaver + ' Notifier=' + hasNotifier + ' BackgroundAudio=' + hasBackgroundAudio;
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, error in
            if let error = error {
                self?.log("❌ 检查JS插件失败: \(error.localizedDescription)")
            } else if let result = result as? String {
                self?.log("📋 \(result)")
            }
        }
    }
    
    // MARK: - SSL Pinning (WKNavigationDelegate)
    
    /// 处理 HTTPS 服务器信任验证挑战
    /// 只对 pinnedHosts 中的域名做证书锁定，其他域名走系统默认处理
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        
        // 只处理服务器信任验证类型的挑战
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            // 其他类型挑战（如客户端证书、HTTP Basic Auth）交给 Capacitor 或系统处理
            forwardChallengeToCapacitor(webView, challenge: challenge, completionHandler: completionHandler)
            return
        }
        
        let host = challenge.protectionSpace.host
        
        // 非锁定域名：走系统默认信任评估
        guard pinnedHosts.contains(host) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            log("❌ SSL Pinning: \(host) 无法获取 serverTrust")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        log("🔐 SSL Pinning 验证: \(host)")
        
        if verifyServerTrust(serverTrust, host: host) {
            log("✅ SSL Pinning 验证通过: \(host)")
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            log("❌ SSL Pinning 验证失败: \(host)，连接已取消（可能是抓包工具中间人攻击）")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    
    /// 将非服务器信任类型的挑战转发给 Capacitor 原始 delegate
    private func forwardChallengeToCapacitor(_ webView: WKWebView, challenge: URLAuthenticationChallenge,
                                             completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if capDelegate?.webView?(webView, didReceive: challenge, completionHandler: completionHandler) != nil {
            // Capacitor 已处理
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
    
    /// 验证服务器证书链：检查证书链中任意证书的公钥哈希是否在白名单中
    private func verifyServerTrust(_ trust: SecTrust, host: String) -> Bool {
        // 1. 先用系统默认策略验证证书链有效性（过期、域名不匹配等）
        let policy = SecPolicyCreateSSL(true, host as CFString)
        SecTrustSetPolicies(trust, policy)
        
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            log("❌ 证书链验证失败: \(error?.localizedDescription ?? "未知错误")")
            return false
        }
        
        // 2. 获取证书链（iOS 15+ 用新 API，旧版本回退）
        let certificates: [SecCertificate]
        if #available(iOS 15.0, *) {
            certificates = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        } else {
            let count = SecTrustGetCertificateCount(trust)
            certificates = (0..<count).compactMap { SecTrustGetCertificateAtIndex(trust, $0) }
        }
        
        // 3. 遍历证书链，检查公钥哈希
        for (i, cert) in certificates.enumerated() {
            if let publicKey = SecCertificateCopyKey(cert),
               let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? {
                let pubKeyHash = sha256Base64(publicKeyData)
                if pinnedPublicKeyHashes.contains(pubKeyHash) {
                    log("✅ 公钥哈希匹配 (证书链第 \(i) 级)")
                    return true
                }
            }
        }
        
        log("❌ 证书链中没有匹配的公钥哈希（共 \(certificates.count) 个证书）")
        return false
    }
    
    /// 计算数据的 SHA-256 并返回 Base64 字符串
    private func sha256Base64(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash).base64EncodedString()
    }
    
    // MARK: - 转发其他 WKNavigationDelegate 方法给 Capacitor
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        capDelegate?.webView?(webView, didFinish: navigation)
    }
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        capDelegate?.webView?(webView, didStartProvisionalNavigation: navigation)
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        capDelegate?.webView?(webView, didFail: navigation, withError: error)
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        capDelegate?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
    
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        capDelegate?.webView?(webView, didCommit: navigation)
    }
    
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        capDelegate?.webView?(webView, didReceiveServerRedirectForProvisionalNavigation: navigation)
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if capDelegate?.webView?(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler) == nil {
            decisionHandler(.allow)
        }
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if capDelegate?.webView?(webView, decidePolicyFor: navigationResponse, decisionHandler: decisionHandler) == nil {
            decisionHandler(.allow)
        }
    }
}
