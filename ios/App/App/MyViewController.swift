import UIKit
import Capacitor

class MyViewController: CAPBridgeViewController {
    
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        print("🔍 MyViewController init 被调用")
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        print("🔍 MyViewController init(coder) 被调用")
    }
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        print("🔍 MyViewController viewDidLoad, bridge=\(String(describing: bridge))")
    }
    
    override open func capacitorDidLoad() {
        super.capacitorDidLoad()
        print("🔍 MyViewController capacitorDidLoad 被调用, bridge=\(String(describing: bridge))")
        
        guard let bridge = bridge else {
            print("❌ capacitorDidLoad: bridge 为 nil，无法注册插件")
            return
        }
        
        // 手动注册自定义插件
        bridge.registerPluginInstance(PhotoSaver())
        bridge.registerPluginInstance(Notifier())
        bridge.registerPluginInstance(BackgroundAudio())
        print("✅ 自定义插件已注册: PhotoSaver, Notifier, BackgroundAudio")
        
        // 打印所有已注册的插件
        if let plugins = bridge.plugins as? [String: Any] {
            print("📋 已注册插件列表: \(plugins.keys.joined(separator: ", "))")
        }
    }
}
