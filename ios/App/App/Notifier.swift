import UIKit
import Capacitor
import UserNotifications

@objc(Notifier)
public class Notifier: CAPPlugin {
    private var notificationCall: CAPPluginCall?

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

        // 立即发送（0秒后触发）
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
}
