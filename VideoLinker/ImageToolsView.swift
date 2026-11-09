import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers
import ImageIO

// MARK: - 图片压缩

/// 从相册多选图片，按设定质量与格式重新编码，再存回相册。
/// 视频那套 PhotoPicker 只挑视频，这里单独做一个图片版。
struct ImageToolsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var showPicker = false
    @State private var items: [CompressedImage] = []
    @State private var format: OutputFormat = .jpeg
    @State private var quality: Double = 0.7
    @State private var longEdge: LongEdge = .original
    @State private var working = false
    @State private var message: String?

    enum OutputFormat: String, CaseIterable, Identifiable {
        case jpeg, png, heic
        var id: String { rawValue }
        var title: String {
            switch self {
            case .jpeg: return "JPG"
            case .png: return "PNG"
            case .heic: return "HEIC"
            }
        }
        var ext: String {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            case .heic: return "heic"
            }
        }
    }

    enum LongEdge: Int, CaseIterable, Identifiable {
        case original = 0
        case px4096 = 4096
        case px2560 = 2560
        case px1920 = 1920

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .original: return "原尺寸"
            case .px4096: return "最长边 4096"
            case .px2560: return "最长边 2560"
            case .px1920: return "最长边 1920"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                ScrollView {
                    VStack(spacing: 14) {
                        settingsCard

                        if items.isEmpty {
                            emptyBox
                        } else {
                            resultCard
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }

                if working {
                    ZStack {
                        Color.black.opacity(0.28).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView()
                                .tint(.white)
                            Text("正在处理…")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .padding(22)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
            .navigationTitle("图片压缩")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.navBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("选图片") { showPicker = true }
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            ImagePickerSheet { images in
                showPicker = false
                compress(images)
            } onCancel: {
                showPicker = false
            }
        }
        .overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.8), in: Capsule())
                    .padding(.bottom, 30)
                    .transition(.opacity)
            }
        }
    }

    // MARK: 设置

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "photo.badge.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text("输出设置")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("格式")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
                Picker("格式", selection: $format) {
                    ForEach(OutputFormat.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("质量")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                    Text(format == .png ? "PNG 无损" : "\(Int(quality * 100))%")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(format == .png ? theme.textTertiary : theme.accent)
                }
                Slider(value: $quality, in: 0.3...1.0, step: 0.05)
                    .tint(theme.accent)
                    .disabled(format == .png)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("尺寸")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
                Picker("尺寸", selection: $longEdge) {
                    ForEach(LongEdge.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .tint(theme.accent)
            }

            Button {
                showPicker = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text("从相册选图片")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private var emptyBox: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.stack")
                .font(.system(size: 32))
                .foregroundStyle(theme.textTertiary)
            Text("选几张图片，看看能压到多小")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.text)
            Text("HEIC 转 JPG、截图压体积、批量改尺寸都在这里")
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: 结果

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("处理结果")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Text("\(items.count) 张")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }

            ForEach(items) { item in
                HStack(spacing: 10) {
                    Image(systemName: "photo")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.accent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        Text("\(item.pixelText) · \(item.originalText) → \(item.outputText)")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textTertiary)
                    }

                    Spacer(minLength: 6)

                    Text(item.savedText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(item.savedPercent > 0 ? theme.accent : .orange)
                }
                .padding(.vertical, 2)
            }

            Divider().overlay(theme.cardStroke)

            Button {
                saveAll()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.arrow.down")
                    Text("全部保存到相册")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                items.removeAll()
            } label: {
                Text("清空结果")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    // MARK: 处理

    private func compress(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        working = true

        let targetFormat = format
        let targetQuality = quality
        let targetEdge = CGFloat(longEdge.rawValue)

        Task.detached(priority: .userInitiated) {
            var results: [CompressedImage] = []

            for (index, image) in images.enumerated() {
                let scaled = Self.resized(image, longEdge: targetEdge)
                guard let encoded = Self.encode(scaled,
                                                format: targetFormat,
                                                quality: targetQuality) else { continue }

                let original = image.jpegData(compressionQuality: 1.0)?.count ?? 0
                let pixel = scaled.size
                results.append(CompressedImage(
                    name: "图片 \(index + 1)",
                    originalBytes: original,
                    outputBytes: encoded.data.count,
                    pixelText: "\(Int(pixel.width.rounded()))×\(Int(pixel.height.rounded()))",
                    data: encoded.data,
                    ext: encoded.ext
                ))
            }

            let output = results
            await MainActor.run {
                working = false
                items = output
                if output.isEmpty {
                    show("这些图片都没能处理，换 JPG 再试一次")
                } else {
                    show("处理完成，点下面保存到相册")
                }
            }
        }
    }

    private func saveAll() {
        guard !items.isEmpty else { return }
        let list = items

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { show("没有相册写入权限，去系统设置里打开") }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                for item in list {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.uniformTypeIdentifier = Self.utType(for: item.ext)
                    request.addResource(with: .photo, data: item.data, options: options)
                }
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        show("已保存 \(list.count) 张到相册")
                    } else {
                        show(error?.localizedDescription ?? "保存失败，稍后再试")
                    }
                }
            }
        }
    }

    // MARK: 编码

    private static func resized(_ image: UIImage, longEdge: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longEdge > 0, longest > longEdge, longest > 0 else { return image }

        let scale = longEdge / longest
        let target = CGSize(width: max(1, size.width * scale),
                            height: max(1, size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private static func encode(_ image: UIImage,
                               format: OutputFormat,
                               quality: Double) -> (data: Data, ext: String)? {
        switch format {
        case .jpeg:
            guard let data = image.jpegData(compressionQuality: quality) else { return nil }
            return (data, "jpg")

        case .png:
            guard let data = image.pngData() else { return nil }
            return (data, "png")

        case .heic:
            guard let cgImage = image.cgImage else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data as CFMutableData,
                UTType.heic.identifier as CFString,
                1,
                nil
            ) else { return nil }

            let options = [kCGImageDestinationLossyCompressionQuality as String: quality] as CFDictionary
            CGImageDestinationAddImage(destination, cgImage, options)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return ((data as NSData) as Data, "heic")
        }
    }

    private static func utType(for ext: String) -> String {
        switch ext {
        case "png": return UTType.png.identifier
        case "heic": return UTType.heic.identifier
        default: return UTType.jpeg.identifier
        }
    }

    private func show(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { message = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if message == text {
                withAnimation(.easeIn(duration: 0.2)) { message = nil }
            }
        }
    }
}

// MARK: - 结果条目

struct CompressedImage: Identifiable {
    let id = UUID()
    let name: String
    let originalBytes: Int
    let outputBytes: Int
    let pixelText: String
    let data: Data
    let ext: String

    var originalText: String {
        ByteCountFormatter.string(fromByteCount: Int64(originalBytes), countStyle: .file)
    }

    var outputText: String {
        ByteCountFormatter.string(fromByteCount: Int64(outputBytes), countStyle: .file)
    }

    var savedPercent: Int {
        guard originalBytes > 0 else { return 0 }
        return Int(((1.0 - Double(outputBytes) / Double(originalBytes)) * 100).rounded())
    }

    var savedText: String {
        if savedPercent >= 0 { return "省 \(savedPercent)%" }
        return "大 \(-savedPercent)%"
    }
}

// MARK: - 相册图片选择器

struct ImagePickerSheet: UIViewControllerRepresentable {
    var selectionLimit: Int = 30
    var onPick: ([UIImage]) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = selectionLimit
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: ImagePickerSheet

        init(_ parent: ImagePickerSheet) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                parent.onCancel()
                return
            }

            let lock = NSLock()
            var picked: [(index: Int, image: UIImage)] = []
            let group = DispatchGroup()

            for (index, result) in results.enumerated() {
                let provider = result.itemProvider
                guard provider.canLoadObject(ofClass: UIImage.self) else { continue }

                group.enter()
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    defer { group.leave() }
                    guard let image = object as? UIImage else { return }
                    lock.lock()
                    picked.append((index, image))
                    lock.unlock()
                }
            }

            group.notify(queue: .main) {
                let images = picked.sorted { $0.index < $1.index }.map { $0.image }
                if images.isEmpty {
                    self.parent.onCancel()
                } else {
                    self.parent.onPick(images)
                }
            }
        }
    }
}
