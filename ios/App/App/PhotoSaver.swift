import UIKit
import Capacitor
import Photos

@objc(PhotoSaver)
public class PhotoSaver: CAPPlugin {
    private var saveCall: CAPPluginCall?

    @objc func saveImage(_ call: CAPPluginCall) {
        saveCall = call
        guard let base64 = call.getString("base64") else {
            call.reject("缺少图片数据")
            return
        }

        // 解析 base64（可能带 data:image/...;base64, 前缀）
        var imageData = base64
        if let commaRange = base64.range(of: ",") {
            imageData = String(base64[commaRange.upperBound...])
        }

        guard let data = Data(base64Encoded: imageData),
              let image = UIImage(data: data) else {
            call.reject("图片解析失败")
            return
        }

        // 请求相册权限并保存
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
