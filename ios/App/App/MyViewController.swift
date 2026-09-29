import UIKit
import Capacitor

class MyViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        super.capacitorDidLoad()
        // 手动注册自定义插件
        bridge?.registerPluginInstance(PhotoSaver())
        bridge?.registerPluginInstance(Notifier())
        print("✅ 自定义插件已注册: PhotoSaver, Notifier")
    }
}
