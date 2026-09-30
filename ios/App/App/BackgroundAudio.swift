import Foundation
import Capacitor
import AVFoundation
import UserNotifications
import CryptoKit

@objc(BackgroundAudio)
public class BackgroundAudio: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "BackgroundAudio"
    public let jsName = "BackgroundAudio"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startPolling", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopPolling", returnType: CAPPluginReturnPromise)
    ]
    
    private let API_SECRET = "tsw_2024_secure_a1b2c3d4e5f6g7h8"
    
    private var audioPlayer: AVAudioPlayer?
    private var pollingTask: URLSessionDataTask?
    private var isPolling = false
    private var pollCount = 0
    
    @objc func start(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            do {
                // 配置音频会话为播放模式，允许后台播放
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                
                // 查找静音音频文件
                guard let url = Bundle.main.url(forResource: "silence", withExtension: "wav") else {
                    call.reject("silence.wav not found")
                    return
                }
                
                // 播放并循环
                self.audioPlayer = try AVAudioPlayer(contentsOf: url)
                self.audioPlayer?.numberOfLoops = -1 // 无限循环
                self.audioPlayer?.volume = 0.01 // 几乎静音
                self.audioPlayer?.play()
                
                print("✅ 后台音频保活已启动")
                call.resolve(["ok": true])
            } catch {
                print("❌ 后台音频启动失败: \(error)")
                call.reject("Failed to start audio: \(error.localizedDescription)")
            }
        }
    }
    
    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.audioPlayer?.stop()
            self.audioPlayer = nil
            self.stopPollingInternal()
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                print("⚠️ 停止音频会话失败: \(error)")
            }
            print("✅ 后台音频保活已停止")
            call.resolve(["ok": true])
        }
    }
    
    // 开始原生后台轮询
    @objc func startPolling(_ call: CAPPluginCall) {
        guard let pollUrl = call.getString("pollUrl") else {
            call.reject("pollUrl is required")
            return
        }
        
        isPolling = true
        pollCount = 0
        print("🔄 开始原生后台轮询: \(pollUrl)")
        
        // 立即开始第一次轮询
        pollOnce(url: pollUrl)
        
        call.resolve(["ok": true])
    }
    
    // 停止原生后台轮询
    @objc func stopPolling(_ call: CAPPluginCall) {
        stopPollingInternal()
        call.resolve(["ok": true])
    }
    
    private func stopPollingInternal() {
        isPolling = false
        pollingTask?.cancel()
        pollingTask = nil
        print("⏹️ 原生后台轮询已停止")
    }
    
    // 单次轮询
    private func pollOnce(url: String) {
        guard isPolling else { return }
        guard let urlObj = URL(string: url) else { return }
        
        pollCount += 1
        print("🔄 原生轮询第\(pollCount)次")
        
        // 生成签名
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).description
        
        // 从 URL 解析查询参数
        var params: [String: String] = [:]
        if let components = URLComponents(url: urlObj, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems {
            for item in queryItems {
                if let value = item.value {
                    params[item.name] = value
                }
            }
        }
        params["timestamp"] = timestamp
        params["nonce"] = nonce
        
        // 按字典序排序并拼接
        let sortedKeys = params.keys.sorted()
        let queryString = sortedKeys.map { "\($0)=\(params[$0]!)" }.joined(separator: "&")
        
        // 与客户端一致的签名格式：timestamp + "\n" + nonce + "\n" + queryString
        let stringToSign = timestamp + "\n" + nonce + "\n" + queryString
        
        // 计算 HMAC-SHA256 签名
        let key = SymmetricKey(data: API_SECRET.data(using: .utf8)!)
        let signature = HMAC<SHA256>.authenticationCode(for: stringToSign.data(using: .utf8)!, using: key)
        let signatureHex = signature.map { String(format: "%02x", $0) }.joined()
        
        // 创建请求并添加签名头
        var request = URLRequest(url: urlObj)
        request.setValue(timestamp, forHTTPHeaderField: "X-Auth-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-Auth-Nonce")
        request.setValue(signatureHex, forHTTPHeaderField: "X-Auth-Signature")
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            guard self.isPolling else { return }
            
            if let error = error {
                print("❌ 原生轮询失败: \(error.localizedDescription)")
                // 失败后继续轮询
                self.scheduleNextPoll(url: url)
                return
            }
            
            guard let data = data, let raw = String(data: data, encoding: .utf8) else {
                self.scheduleNextPoll(url: url)
                return
            }
            
            print("📥 原生轮询返回: \(raw.prefix(100))")
            
            // 解析 JSON
            if let jsonData = raw.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let status = json["status"] as? String {
                
                if status == "completed" {
                    // 生成完成，发送通知
                    print("✅ 原生轮询检测到生成完成！")
                    self.sendNotification(title: "图生万物", body: "图片生成已完成，点击查看")
                    self.stopPollingInternal()
                    return
                } else if status == "failed" {
                    // 生成失败
                    print("❌ 原生轮询检测到生成失败")
                    self.sendNotification(title: "图生万物", body: "图片生成失败，请重试")
                    self.stopPollingInternal()
                    return
                }
            }
            
            // 继续轮询
            if self.pollCount >= 120 {
                print("⚠️ 原生轮询超时（120次）")
                self.stopPollingInternal()
                return
            }
            
            self.scheduleNextPoll(url: url)
        }
        
        pollingTask = task
        task.resume()
    }
    
    // 安排下一次轮询（2秒后）
    private func scheduleNextPoll(url: String) {
        guard isPolling else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.pollOnce(url: url)
        }
    }
    
    // 发送本地通知
    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ 通知发送失败: \(error.localizedDescription)")
            } else {
                print("✅ 通知发送成功: \(title) - \(body)")
            }
        }
    }
}
