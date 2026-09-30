import Foundation
import Capacitor
import SwiftUI

// MARK: - AI 对话插件
@objc(AIChatPlugin)
public class AIChatPlugin: CAPPlugin {
    
    // 强制插件 id 为 AIChatPlugin，避免 NSStringFromClass 带模块名前缀导致 JS 端找不到
    override public var id: String {
        return "AIChatPlugin"
    }
    
    @objc func openChat(_ call: CAPPluginCall) {
        NSLog("🔍 AIChatPlugin.openChat 被调用, 插件id=\(self.id)")
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
