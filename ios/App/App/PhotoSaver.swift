import UIKit
import Capacitor
import Photos

@objc(PhotoSaver)
public class PhotoSaver: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "PhotoSaver"
    public let jsName = "PhotoSaver"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "saveImage", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "saveImageFromUrl", returnType: CAPPluginReturnPromise)
    ]
    
    private var saveCall: CAPPluginCall?

    // 从 base64 保存
    @objc func saveImage(_ call: CAPPluginCall) {
        saveCall = call
        guard let base64 = call.getString("base64") else {
            call.reject("缺少图片数据")
            return
        }

        var imageData = base64
        if let commaRange = base64.range(of: ",") {
            imageData = String(base64[commaRange.upperBound...])
        }

        guard let data = Data(base64Encoded: imageData),
              let image = UIImage(data: data) else {
            call.reject("图片解析失败")
            return
        }

        saveImageToAlbum(image: image, call: call)
    }

    // 从 URL 下载并保存（推荐，不受 CORS 限制）
    @objc func saveImageFromUrl(_ call: CAPPluginCall) {
        saveCall = call
        guard let urlString = call.getString("url"),
              let url = URL(string: urlString) else {
            call.reject("缺少图片URL")
            return
        }

        // 原生下载，不受 CORS 限制
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            if let error = error {
                call.reject("下载失败: \(error.localizedDescription)")
                return
            }
            guard let data = data, let image = UIImage(data: data) else {
                call.reject("图片解析失败")
                return
            }
            self?.saveImageToAlbum(image: image, call: call)
        }.resume()
    }

    private func saveImageToAlbum(image: UIImage, call: CAPPluginCall) {
        PHPhotoLibrary.requestAuthorization { [weak self] status in
            if status == .authorized {
                UIImageWriteToSavedPhotosAlbum(image, self, #selector(self?.imageSaved(_:didFinishSavingWithError:contextInfo:)), nil)
            } else {
                call.reject("没有相册权限，请在设置中开启")
            }
        }
    }

    @objc func imageSaved(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        if let error = error {
            saveCall?.reject("保存失败: \(error.localizedDescription)")
        } else {
            saveCall?.resolve(["success": true])
        }
        saveCall = nil
    }
}
