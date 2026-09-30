import Foundation
import Capacitor
import AVFoundation

@objc(BackgroundAudio)
public class BackgroundAudio: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "BackgroundAudio"
    public let jsName = "BackgroundAudio"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise)
    ]
    
    private var audioPlayer: AVAudioPlayer?
    
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
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                print("⚠️ 停止音频会话失败: \(error)")
            }
            print("✅ 后台音频保活已停止")
            call.resolve(["ok": true])
        }
    }
}
