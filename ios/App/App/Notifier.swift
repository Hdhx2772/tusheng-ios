import UIKit
import Capacitor
import UserNotifications

@objc(Notifier)
public class Notifier: CAPPlugin, UNUserNotificationCenterDelegate {
    private var notificationCall: CAPPluginCall?

    override public func load() {
        super.load()
        // 设置通知中心 delegate，让 App 在前台时也能显示通知
        UNUserNotificationCenter.current().delegate = self
    }

    // 请求通知权限
    @objc func requestPermission(_ call: CAPPluginCall) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                call.resolve(["granted": true])
            } else {
                call.reject(error?.localizedDescription ?? "权限被拒绝")
            }
        }
    }

    // 发送本地通知
    @objc func sendNotification(_ call: CAPPluginCall) {
        let title = call.getString("title") ?? "图生万物"
        let body = call.getString("body") ?? "图片生成已完成"

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // 立即发送（0.1秒后触发）
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                call.reject("通知发送失败: \(error.localizedDescription)")
            } else {
                call.resolve(["success": true])
            }
        }
    }

    // App 在前台时也显示通知
    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.alert, .sound, .badge])
    }

    // 点击通知时打开 App
    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
