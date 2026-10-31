import Foundation
import AVFoundation
import SwiftUI
import UIKit

/// 本地视频的缩略图和时长。生成一次就落盘缓存，列表滑动不会反复解码
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let dir: URL
    private var memory: [String: UIImage] = [:]
    private var durations: [String: Double] = [:]
    private var running: Set<String> = []

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("VideoThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// 已缓存的直接给，没有就返回 nil（不阻塞）
    func cachedImage(for path: String) -> UIImage? {
        if let image = memory[path] { return image }
        let file = dir.appendingPathComponent(Self.key(path) + ".jpg")
        guard let data = try? Data(contentsOf: file), let image = UIImage(data: data) else { return nil }
        memory[path] = image
        return image
    }

    func cachedDuration(for path: String) -> Double? {
        durations[path]
    }

    func durationText(for path: String) -> String? {
        guard let value = durations[path], value > 0 else { return nil }
        return Self.timeText(value)
    }

    /// 异步生成缩略图；回调统一回主线程
    func request(_ path: String, completion: @escaping (UIImage?, Double?) -> Void) {
        if let image = cachedImage(for: path) {
            completion(image, durations[path])
            return
        }
        guard !running.contains(path) else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            completion(nil, nil)
            return
        }

        running.insert(path)
        let file = dir.appendingPathComponent(Self.key(path) + ".jpg")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let seconds = CMTimeGetSeconds(asset.duration)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 320)

            var image: UIImage?
            if seconds.isFinite, seconds > 0 {
                let time = CMTime(seconds: min(3, seconds / 3), preferredTimescale: 600)
                if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                    image = UIImage(cgImage: cgImage)
                }
            }
            if image == nil, let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                image = UIImage(cgImage: cgImage)
            }

            if let image = image, let data = image.jpegData(compressionQuality: 0.7) {
                try? data.write(to: file)
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.running.remove(path)
                if let image = image { self.memory[path] = image }
                if seconds.isFinite, seconds > 0 { self.durations[path] = seconds }
                completion(image, seconds.isFinite ? seconds : nil)
            }
        }
    }

    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// 稳定的短文件名：FNV-1a，重启后还能命中同一张图
    private static func key(_ path: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

/// 列表里的小缩略图，右下角带时长
struct VideoThumbnail: View {
    let path: String
    var width: CGFloat = 64
    var height: CGFloat = 38
    var corner: CGFloat = 6

    @State private var image: UIImage?
    @State private var duration: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.gray.opacity(0.18))

            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film")
                    .font(.system(size: min(width, height) * 0.34))
                    .foregroundStyle(.secondary)
            }

            if let duration = duration {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(duration)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                    }
                }
                .padding(3)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .onAppear(perform: load)
    }

    private func load() {
        if let cached = ThumbnailCache.shared.cachedImage(for: path) {
            image = cached
            duration = ThumbnailCache.shared.durationText(for: path)
            return
        }
        ThumbnailCache.shared.request(path) { loaded, seconds in
            image = loaded
            if let seconds = seconds, seconds > 0 {
                duration = ThumbnailCache.timeText(seconds)
            }
        }
    }
}
