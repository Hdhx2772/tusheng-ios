import Foundation
import Capacitor
import SwiftUI

// MARK: - AI 对话插件
// 必须遵循 CAPBridgedPlugin 协议，并显式声明 identifier / jsName / pluginMethods，
// 否则 Capacitor 的 JSExport 不会生成 JS 代理，handleJSCall 也找不到方法。
@objc(AIChatPlugin)
public class AIChatPlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "AIChatPlugin"
    public let jsName = "AIChatPlugin"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "openChat", returnType: CAPPluginReturnPromise)
    ]

    @objc public func openChat(_ call: CAPPluginCall) {
        NSLog("🔍 AIChatPlugin.openChat 被调用")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                NSLog("❌ AIChatPlugin self 为 nil")
                call.reject("插件已销毁")
                return
            }

            NSLog("🔍 AIChatPlugin 开始创建聊天界面")
            let chatView = AIChatView()
            let hostingController = UIHostingController(rootView: chatView)
            hostingController.modalPresentationStyle = .fullScreen

            if let rootVC = self.bridge?.viewController {
                NSLog("🔍 AIChatPlugin present 聊天界面")
                rootVC.present(hostingController, animated: true)
                call.resolve(["opened": true])
                NSLog("✅ AIChatPlugin.openChat 成功")
            } else {
                NSLog("❌ AIChatPlugin 无法获取 rootViewController")
                call.reject("无法打开聊天界面")
            }
        }
    }
}
