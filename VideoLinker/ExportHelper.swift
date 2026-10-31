import Foundation
import Photos
import UIKit

/// 把沙盒里的文件交给系统：导出到「文件」、存进相册、或走分享面板
enum MediaExporter {
    /// 导出到「文件」App：会弹出系统的存储位置选择
    static func exportToFiles(_ urls: [URL]) {
        guard !urls.isEmpty, let top = topViewController() else { return }
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.shouldShowFileExtensions = true
        top.present(picker, animated: true)
    }

    /// 存进系统相册（只申请「添加」权限，不读相册）
    static func saveToPhotos(_ url: URL, completion: @escaping (String) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    completion("没有相册权限，去「设置 → 隐私与安全 → 照片」里允许添加")
                }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: nil)
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        completion("已存到相册")
                    } else {
                        completion(error?.localizedDescription ?? "存相册失败，换个格式试试")
                    }
                }
            }
        }
    }

    /// 当前最顶层的控制器，用来弹系统面板
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? scenes.first?.windows.first

        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
