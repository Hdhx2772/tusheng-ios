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
        CAPPluginMethod(name: "openChat", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "listSessions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openSession", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearAllSessions", returnType: CAPPluginReturnPromise)
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

    // MARK: - 读取会话列表（供 Web 历史页"文字对话"栏展示）
    @objc public func listSessions(_ call: CAPPluginCall) {
        let deviceCode = call.getString("deviceCode") ?? ""
        NSLog("🔍 AIChatPlugin.listSessions 被调用, deviceCode=\(deviceCode)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { call.reject("插件已销毁"); return }
            let store = ChatStore(deviceCode: deviceCode)
            let items = store.sortedSessions.map { s -> [String: Any] in
                let preview = (s.messages.last?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return [
                    "id": s.id.uuidString,
                    "title": s.title,
                    "updatedAt": Int(s.updatedAt.timeIntervalSince1970 * 1000),
                    "preview": String(preview.prefix(60)),
                    "messageCount": s.messages.count
                ]
            }
            call.resolve(["sessions": items])
        }
    }

    // MARK: - 打开指定会话的完整对话界面（Web 历史页点击某组对话进入）
    @objc public func openSession(_ call: CAPPluginCall) {
        let deviceCode = call.getString("deviceCode") ?? ""
        guard let idStr = call.getString("sessionId"),
              let sessionId = UUID(uuidString: idStr) else {
            call.reject("无效的会话 ID")
            return
        }
        NSLog("🔍 AIChatPlugin.openSession 被调用, sessionId=\(idStr)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                call.reject("插件已销毁")
                return
            }
            let store = ChatStore(deviceCode: deviceCode)
            guard store.session(sessionId) != nil else {
                call.reject("会话不存在")
                return
            }
            let chatView = AIChatView(store: store, sessionId: sessionId, showCloseButton: true)
            let nav = UINavigationController(rootViewController: UIHostingController(rootView: chatView))
            nav.modalPresentationStyle = .fullScreen
            if let rootVC = self.bridge?.viewController {
                rootVC.present(nav, animated: true)
                call.resolve(["opened": true])
            } else {
                call.reject("无法打开聊天界面")
            }
        }
    }

    // MARK: - 清空全部 AI 对话（Web 历史页"清空文字"）
    @objc public func clearAllSessions(_ call: CAPPluginCall) {
        let deviceCode = call.getString("deviceCode") ?? ""
        NSLog("🔍 AIChatPlugin.clearAllSessions 被调用")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { call.reject("插件已销毁"); return }
            let store = ChatStore(deviceCode: deviceCode)
            store.clearAllSessions()
            call.resolve(["cleared": true])
        }
    }
}
