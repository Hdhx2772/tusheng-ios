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
        // 由 JS 端从 localStorage 传入设备码，保证与图片生成模块共用同一个已授权设备码
        let deviceCode = call.getString("deviceCode") ?? ""
        NSLog("🔍 AIChatPlugin 收到设备码: \(deviceCode)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                NSLog("❌ AIChatPlugin self 为 nil")
                call.reject("插件已销毁")
                return
            }

            NSLog("🔍 AIChatPlugin 开始创建 AI 对话独立界面（会话列表）")
            // 根视图为会话历史列表（内部含 NavigationView，可 push 进入聊天详情），
            // 形成完整的应用级导航栈，而非盖在网页上的单层浮窗。
            let listView = AIChatListView(deviceCode: deviceCode)
            let hostingController = UIHostingController(rootView: listView)
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
