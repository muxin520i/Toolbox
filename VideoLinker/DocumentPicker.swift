import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 用 UIKit 直接弹系统文件选择器。
///
/// 不用 SwiftUI 的 `.fileImporter`：它挂在「sheet 里再开 picker」的场景下偶尔收不到回调，
/// 表现就是选完文件点「打开」什么都没发生。自己拿 top view controller present，
/// 回调稳定，取消事件也能拿到，选完还能立刻知道自己被点过了
final class DocumentPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    static let shared = DocumentPickerCoordinator()

    private var onPick: (([URL]) -> Void)?
    private var onCancel: (() -> Void)?

    func present(
        contentTypes: [UTType],
        allowsMultiple: Bool = true,
        onPick: @escaping ([URL]) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        guard let root = Self.topViewController() else { return }
        self.onPick = onPick
        self.onCancel = onCancel

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: false)
        picker.allowsMultipleSelection = allowsMultiple
        picker.shouldShowFileExtensions = true
        picker.delegate = self

        root.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let handler = onPick
        onPick = nil
        onCancel = nil
        handler?(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let handler = onCancel
        onPick = nil
        onCancel = nil
        handler?()
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
