import UIKit
import Capacitor
import CommonCrypto

class MyViewController: CAPBridgeViewController, WKNavigationDelegate {
    
    private var nativeLogs: [String] = []
    
    // SSL Pinning：允许的公钥 SHA-256 哈希（Base64）
    // wutong.xyz 公钥哈希，证书续期后公钥不变，无需更新
    private let pinnedPublicKeyHashes: Set<String> = [
        "0N5PsYbLsX3MHFyWp0KwqcgC++uJ9Brzwv3yphZzpTo=" // wutong.xyz 公钥
    ]
    
    // 备份：叶子证书 SHA-256 哈希（证书续期后需更新）
    private let pinnedCertificateHashes: Set<String> = [
        "kQexiQA74znd2a9BIRJxO3T2VQ+PQ/VpCfo2mgn9lds=" // wutong.xyz 叶子证书
    ]
    
    // 保存原始 delegate，避免覆盖 Capacitor 内部逻辑
    private weak var originalNavDelegate: WKNavigationDelegate?
    
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
        
        // 设置 SSL Pinning：接管 WKWebView 的 navigationDelegate
        if let webView = bridge?.webView {
            originalNavDelegate = webView.navigationDelegate
            webView.navigationDelegate = self
            log("✅ SSL Pinning 已启用，pinned keys: \(pinnedPublicKeyHashes.count) 个公钥 + \(pinnedCertificateHashes.count) 个证书")
        }
    }
    
    override open func capacitorDidLoad() {
        super.capacitorDidLoad()
        log("MyViewController capacitorDidLoad 被调用, bridge=\(String(describing: bridge))")
        
        guard let bridge = bridge else {
            log("❌ capacitorDidLoad: bridge 为 nil，无法注册插件")
            return
        }
        
        // 注册自定义插件（实现了 CAPBridgedPlugin 协议）
        bridge.registerPluginInstance(PhotoSaver())
        log("✅ PhotoSaver 已注册")
        bridge.registerPluginInstance(Notifier())
        log("✅ Notifier 已注册")
        bridge.registerPluginInstance(BackgroundAudio())
        log("✅ BackgroundAudio 已注册")
        
        log("✅ 所有自定义插件注册完成")
        
        // 延迟检查 JS 端是否能看到插件
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
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
    
    // MARK: - SSL Pinning
    
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        
        // 只处理服务器信任验证
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            // 其他类型的 challenge，交给原始 delegate 或默认处理
            if originalNavDelegate?.responds(to: #selector(WKNavigationDelegate.webView(_:didReceive:completionHandler:))) == true {
                originalNavDelegate?.webView?(webView, didReceive: challenge, completionHandler: completionHandler)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }
        
        let host = challenge.protectionSpace.host
        log("🔐 SSL Pinning 验证: \(host)")
        
        // 验证证书链
        if verifyServerTrust(serverTrust, host: host) {
            log("✅ SSL Pinning 验证通过: \(host)")
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            log("❌ SSL Pinning 验证失败: \(host)，连接已取消")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    
    /// 验证服务器证书：检查证书链中的公钥或证书哈希是否在白名单中
    private func verifyServerTrust(_ trust: SecTrust, host: String) -> Bool {
        // 1. 先用系统默认策略验证证书链有效性（防止过期、域名不匹配等）
        let policy = SecPolicyCreateSSL(true, host as CFString)
        SecTrustSetPolicies(trust, policy)
        
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            log("❌ 证书链验证失败: \(error?.localizedDescription ?? "未知错误")")
            return false
        }
        
        // 2. 遍历证书链，检查公钥哈希或证书哈希
        let count = SecTrustGetCertificateCount(trust)
        for i in 0..<count {
            guard let cert = SecTrustGetCertificateAtIndex(trust, i) else { continue }
            
            // 检查公钥哈希（更稳定，续期后不变）
            if let publicKey = SecCertificateCopyKey(cert),
               let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? {
                let pubKeyHash = sha256Base64(publicKeyData)
                if pinnedPublicKeyHashes.contains(pubKeyHash) {
                    log("✅ 公钥哈希匹配 (证书 \(i))")
                    return true
                }
            }
            
            // 检查证书哈希（备份方案）
            let certData = SecCertificateCopyData(cert) as Data
            let certHash = sha256Base64(certData)
            if pinnedCertificateHashes.contains(certHash) {
                log("✅ 证书哈希匹配 (证书 \(i))")
                return true
            }
        }
        
        log("❌ 证书链中没有匹配的公钥或证书哈希")
        return false
    }
    
    /// 计算 SHA-256 并返回 Base64 字符串
    private func sha256Base64(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash).base64EncodedString()
    }
    
    // MARK: - 转发 WKNavigationDelegate 其他方法给原始 delegate
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        originalNavDelegate?.webView?(webView, didFinish: navigation)
    }
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        originalNavDelegate?.webView?(webView, didStartProvisionalNavigation: navigation)
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        originalNavDelegate?.webView?(webView, didFail: navigation, withError: error)
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        originalNavDelegate?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if originalNavDelegate?.responds(to: #selector(WKNavigationDelegate.webView(_:decidePolicyFor:decisionHandler:))) == true {
            originalNavDelegate?.webView?(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
        } else {
            decisionHandler(.allow)
        }
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if originalNavDelegate?.responds(to: #selector(WKNavigationDelegate.webView(_:decidePolicyFor:decisionHandler:))) == true {
            originalNavDelegate?.webView?(webView, decidePolicyFor: navigationResponse, decisionHandler: decisionHandler)
        } else {
            decisionHandler(.allow)
        }
    }
    
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        originalNavDelegate?.webView?(webView, didReceiveServerRedirectForProvisionalNavigation: navigation)
    }
    
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        originalNavDelegate?.webView?(webView, didCommit: navigation)
    }
}
