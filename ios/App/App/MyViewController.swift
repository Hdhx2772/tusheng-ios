import UIKit
import Capacitor

class MyViewController: CAPBridgeViewController {
    
    private var nativeLogs: [String] = []
    
    private func log(_ msg: String) {
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss.SSS"
        let timestamp = time.string(from: Date())
        let entry = "[\(timestamp)][NATIVE] \(msg)"
        nativeLogs.append(entry)
        print(entry)
        // 尝试发送到 JS 端
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
    }
    
    override open func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        log("MyViewController viewDidAppear, bridge=\(String(describing: bridge))")
    }
    
    override open func capacitorDidLoad() {
        super.capacitorDidLoad()
        log("MyViewController capacitorDidLoad 被调用, bridge=\(String(describing: bridge))")
        
        guard let bridge = bridge else {
            log("❌ capacitorDidLoad: bridge 为 nil，无法注册插件")
            return
        }
        
        // 手动注册自定义插件
        bridge.registerPluginInstance(PhotoSaver())
        log("✅ PhotoSaver 已注册")
        bridge.registerPluginInstance(Notifier())
        log("✅ Notifier 已注册")
        bridge.registerPluginInstance(BackgroundAudio())
        log("✅ BackgroundAudio 已注册")
        
        log("✅ 所有自定义插件注册完成")
        sendLogsToJS()
    }
}
