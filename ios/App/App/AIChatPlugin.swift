import Foundation
import Capacitor
import SwiftUI

// MARK: - AI 对话插件
@objc(AIChatPlugin)
public class AIChatPlugin: CAPPlugin {
    
    @objc func openChat(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let chatView = AIChatView()
            let hostingController = UIHostingController(rootView: chatView)
            hostingController.modalPresentationStyle = .fullScreen
            
            if let rootVC = self.bridge?.viewController {
                rootVC.present(hostingController, animated: true)
                call.resolve(["opened": true])
            } else {
                call.reject("无法打开聊天界面")
            }
        }
    }
}
