import UIKit
import Capacitor

class MyViewController: CAPBridgeViewController {
    
    private var nativeLogs: [String] = []
    private var pluginsRegistered = false
    
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
    }
    
    override open func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        log("MyViewController viewDidAppear, bridge=\(String(describing: bridge))")
        // 在 viewDidAppear 里注册插件，此时 bridge 和 webView 都已初始化
        registerPluginsIfNeeded()
    }
    
    private func registerPluginsIfNeeded() {
        guard !pluginsRegistered else { return }
        guard let bridge = bridge else {
            log("❌ registerPlugins: bridge 为 nil")
            return
        }
        pluginsRegistered = true
        
        log("开始注册自定义插件...")
        
        // 方式1: 注册插件类
        bridge.registerPlugin(PhotoSaver.self)
        log("✅ registerPlugin(PhotoSaver.self) 完成")
        
        bridge.registerPlugin(Notifier.self)
        log("✅ registerPlugin(Notifier.self) 完成")
        
        bridge.registerPlugin(BackgroundAudio.self)
        log("✅ registerPlugin(BackgroundAudio.self) 完成")
        
        // 方式2: 同时注册实例（双保险）
        bridge.registerPluginInstance(PhotoSaver())
        log("✅ registerPluginInstance(PhotoSaver()) 完成")
        
        bridge.registerPluginInstance(Notifier())
        log("✅ registerPluginInstance(Notifier()) 完成")
        
        bridge.registerPluginInstance(BackgroundAudio())
        log("✅ registerPluginInstance(BackgroundAudio()) 完成")
        
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
    
    override open func capacitorDidLoad() {
        super.capacitorDidLoad()
        log("MyViewController capacitorDidLoad 被调用, bridge=\(String(describing: bridge))")
    }
}
