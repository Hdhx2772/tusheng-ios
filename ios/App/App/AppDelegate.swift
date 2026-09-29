import UIKit
import Capacitor

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    private var pluginsRegistered = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // 确保只注册一次
        guard !pluginsRegistered else { return }
        
        // 获取 CAPBridgeViewController 并注册自定义插件
        if let bridgeVC = window?.rootViewController as? CAPBridgeViewController {
            bridgeVC.bridge?.registerPluginInstance(PhotoSaver())
            bridgeVC.bridge?.registerPluginInstance(Notifier())
            pluginsRegistered = true
            print("✅ AppDelegate 注册插件成功: PhotoSaver, Notifier")
        } else {
            // 延迟一点再试
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, !self.pluginsRegistered else { return }
                if let bridgeVC = self.window?.rootViewController as? CAPBridgeViewController {
                    bridgeVC.bridge?.registerPluginInstance(PhotoSaver())
                    bridgeVC.bridge?.registerPluginInstance(Notifier())
                    self.pluginsRegistered = true
                    print("✅ AppDelegate 延迟注册插件成功")
                }
            }
        }
    }

    func applicationWillResignActive(_ application: UIApplication) {}
    func applicationDidEnterBackground(_ application: UIApplication) {}
    func applicationWillEnterForeground(_ application: UIApplication) {}
    func applicationWillTerminate(_ application: UIApplication) {}

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration",
                                          sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}
