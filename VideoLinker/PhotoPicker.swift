import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// 系统相册选择器。只挑视频，选完把文件拷到临时目录再交给导入流程。
/// 用 PHPicker 不需要相册权限，也看不到照片以外的东西。
struct PhotoPickerSheet: UIViewControllerRepresentable {
    var selectionLimit: Int = 0
    var onPick: ([URL]) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.selectionLimit = selectionLimit
        // 用原始文件，别让系统为了「兼容性」把 HEVC 转成 H.264，白等几分钟
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: PhotoPickerSheet

        init(_ parent: PhotoPickerSheet) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                parent.onCancel()
                return
            }

            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("photo-import-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let lock = NSLock()
            var picked: [(index: Int, url: URL)] = []
            let group = DispatchGroup()

            for (index, result) in results.enumerated() {
                let provider = result.itemProvider
                guard provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else { continue }

                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                    defer { group.leave() }
                    // 这个 url 在回调返回后就会被系统删掉，必须当场拷走
                    guard let url = url else { return }
                    let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                    // 每条单独一个子目录，保留相册里的原名（IMG_1234.MOV），
                    // 同名也不会互相覆盖，导入后显示的名字才是人看得懂的
                    let slot = folder.appendingPathComponent("\(index)", isDirectory: true)
                    try? FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
                    let name = url.lastPathComponent.isEmpty ? "\(index).\(ext)" : url.lastPathComponent
                    let dest = slot.appendingPathComponent(name)
                    try? FileManager.default.removeItem(at: dest)
                    do {
                        try FileManager.default.copyItem(at: url, to: dest)
                        lock.lock()
                        picked.append((index, dest))
                        lock.unlock()
                    } catch {
                        // 拷贝失败就当这个没选，导入结果里会少一条
                    }
                }
            }

            group.notify(queue: .main) {
                // 按用户勾选的顺序排，不然并发回调回来顺序是乱的
                let urls = picked.sorted { $0.index < $1.index }.map { $0.url }
                if urls.isEmpty {
                    self.parent.onCancel()
                } else {
                    self.parent.onPick(urls)
                }
            }
        }
    }
}
