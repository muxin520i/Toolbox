import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 系统文件选择器，挂在 SwiftUI 的 sheet 上。
///
/// 之前两版都栽在「谁去 present」这件事上：
/// 第一版用 `.fileImporter`，视图本身就在 sheet 里，回调会丢；
/// 第二版自己找 top view controller 去 present，仍然不稳。
/// 这一版把呈现权交给 SwiftUI：sheet 里放一个空的宿主控制器，由它在 `viewDidAppear`
/// 里弹出 picker，生命周期由 SwiftUI 管，delegate 也由宿主强持有。
///
/// 另外 `asCopy` 一律传 true：系统会先把文件（包括 iCloud 里还没落盘的）复制到
/// App 的临时目录，拿到的 URL 立刻可读，不用再折腾安全作用域，也不会因为
/// iCloud 占位符而复制失败。
struct DocumentPickerSheet: UIViewControllerRepresentable {
    var contentTypes: [UTType]
    var allowsMultiple: Bool = true
    var onPick: ([URL]) -> Void
    /// failed 为 true 表示选择器压根没能弹出来，不是用户主动取消
    var onCancel: (_ failed: Bool) -> Void

    func makeUIViewController(context: Context) -> DocumentPickerHost {
        let host = DocumentPickerHost()
        host.contentTypes = contentTypes
        host.allowsMultiple = allowsMultiple
        host.onPick = onPick
        host.onCancel = onCancel
        return host
    }

    func updateUIViewController(_ uiViewController: DocumentPickerHost, context: Context) {}
}

final class DocumentPickerHost: UIViewController, UIDocumentPickerDelegate {
    var contentTypes: [UTType] = [.data]
    var allowsMultiple = true
    var onPick: (([URL]) -> Void)?
    var onCancel: ((Bool) -> Void)?

    private var didOpen = false
    private var picked = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didOpen else { return }
        didOpen = true
        open()
    }

    private func open() {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: true
        )
        picker.allowsMultipleSelection = allowsMultiple
        picker.shouldShowFileExtensions = true
        picker.delegate = self
        present(picker, animated: true)

        // 兜底：如果 1 秒后 picker 没起来（系统拒绝、宿主已在转场），
        // 主动结束这次选择，让外层给个明确提示，而不是静默卡住
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.picked else { return }
            guard self.presentedViewController == nil
                || !(self.presentedViewController is UIDocumentPickerViewController) else { return }
            let handler = self.onCancel
            self.onPick = nil
            self.onCancel = nil
            handler?(true)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        picked = true
        let handler = onPick
        onPick = nil
        onCancel = nil
        handler?(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        picked = true
        let handler = onCancel
        onPick = nil
        onCancel = nil
        handler?(false)
    }
}
