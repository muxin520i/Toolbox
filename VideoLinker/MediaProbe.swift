import Foundation
import AVFoundation
import CoreGraphics

// MARK: - 媒体信息

/// 嗅探结果里补的两项：时长、分辨率。拿不到就留空，界面直接不显示
struct MediaInfo: Equatable, Sendable {
    var duration: Double?
    var width: Int?
    var height: Int?

    var isEmpty: Bool { duration == nil && (width == nil || height == nil) }

    var durationText: String? {
        guard let duration, duration.isFinite, duration >= 1 else { return nil }
        return Fmt.time(duration)
    }

    var resolutionText: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }

    /// 「12:34 · 1920×1080」
    var summary: String {
        [durationText, resolutionText].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - 探测

/// 只做一件事：给一个视频地址，问出它多长、多大。
/// 先让 AVFoundation 自己去读（mp4/mov/m3u8 都吃），读不到再把 m3u8 当文本解一遍。
enum MediaProbe {
    static func probe(_ raw: String) async -> MediaInfo? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }

        if let info = await withDeadline(9, { await probeAsset(url) }), !info.isEmpty {
            return info
        }
        if raw.lowercased().contains(".m3u8") {
            return await probePlaylist(url)
        }
        return nil
    }

    // MARK: AVFoundation

    private static func probeAsset(_ url: URL) async -> MediaInfo? {
        let asset = AVURLAsset(url: url)
        var info = MediaInfo()

        if let duration = try? await asset.load(.duration),
           duration.isNumeric,
           duration.seconds > 0,
           duration.seconds.isFinite {
            info.duration = duration.seconds
        }

        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            // 竖屏视频的 naturalSize 是横着的，用变换矩阵摆正才是肉眼看到的宽高
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            let width = Int(abs(rect.width).rounded())
            let height = Int(abs(rect.height).rounded())
            if width > 0, height > 0 {
                info.width = width
                info.height = height
            }
        }

        return info.isEmpty ? nil : info
    }

    // MARK: m3u8 文本兜底

    private static func probePlaylist(_ url: URL) async -> MediaInfo? {
        guard let text = await fetchText(url) else { return nil }

        var resolution: (Int, Int)?
        var body = text

        if text.contains("#EXT-X-STREAM-INF") {
            let list = variants(in: text, base: url)
            let best = list.max { lhs, rhs in
                let lh = lhs.resolution?.1 ?? 0
                let rh = rhs.resolution?.1 ?? 0
                if lh != rh { return lh < rh }
                return lhs.bandwidth < rhs.bandwidth
            }
            if let best = best {
                resolution = best.resolution
                if let sub = await fetchText(best.url) {
                    body = sub
                }
            }
        }

        var info = MediaInfo()
        info.duration = totalDuration(in: body)
        if let resolution = resolution {
            info.width = resolution.0
            info.height = resolution.1
        }
        return info.isEmpty ? nil : info
    }

    private struct Variant {
        var url: URL
        var resolution: (Int, Int)?
        var bandwidth: Int
    }

    private static func variants(in text: String, base: URL) -> [Variant] {
        var result: [Variant] = []
        var pending: (resolution: (Int, Int)?, bandwidth: Int)?

        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attributes = line.replacingOccurrences(of: "#EXT-X-STREAM-INF:", with: "")
                var resolution: (Int, Int)?
                var bandwidth = 0

                for part in attributes.split(separator: ",") {
                    let pair = part.split(separator: "=", maxSplits: 1)
                    guard pair.count == 2 else { continue }
                    let key = String(pair[0]).trimmingCharacters(in: .whitespaces)
                    let value = String(pair[1]).trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

                    if key == "RESOLUTION" {
                        let wh = value.lowercased().split(separator: "x")
                        if wh.count == 2, let w = Int(wh[0]), let h = Int(wh[1]) {
                            resolution = (w, h)
                        }
                    } else if key == "BANDWIDTH" {
                        bandwidth = Int(value) ?? 0
                    }
                }
                pending = (resolution, bandwidth)
            } else if !line.isEmpty, !line.hasPrefix("#"), let variant = pending {
                if let url = URL(string: line, relativeTo: base)?.absoluteURL {
                    result.append(Variant(url: url,
                                          resolution: variant.resolution,
                                          bandwidth: variant.bandwidth))
                }
                pending = nil
            }
        }
        return result
    }

    private static func totalDuration(in text: String) -> Double? {
        var total: Double = 0
        var found = false

        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXTINF:") else { continue }
            let value = line.replacingOccurrences(of: "#EXTINF:", with: "")
            let number = value.split(separator: ",").first.map(String.init) ?? value
            if let seconds = Double(number.trimmingCharacters(in: .whitespaces)) {
                total += seconds
                found = true
            }
        }
        return found && total >= 1 ? total : nil
    }

    private static func fetchText(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue(HLSDownloader.userAgent, forHTTPHeaderField: "User-Agent")
        if let scheme = url.scheme, let host = url.host {
            request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: 超时

    /// AVFoundation 读远程地址偶尔会卡住，超过时限就当没问到。
    /// 真正的工作放在另一条任务里跑，超时了也不影响界面。
    private static func withDeadline<T: Sendable>(
        _ seconds: Double,
        _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withCheckedContinuation { continuation in
            let box = DeadlineBox(continuation)
            Task.detached(priority: .utility) {
                box.finish(await work())
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                box.finish(nil)
            }
        }
    }

    /// 保证 continuation 只 resume 一次
    private final class DeadlineBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let continuation: CheckedContinuation<T?, Never>

        init(_ continuation: CheckedContinuation<T?, Never>) {
            self.continuation = continuation
        }

        func finish(_ value: T?) {
            lock.lock()
            if done {
                lock.unlock()
                return
            }
            done = true
            lock.unlock()
            continuation.resume(returning: value)
        }
    }
}

// MARK: - 结果缓存

/// 嗅探列表每一行都问一次，同一个地址只探一次；同时最多探 3 条，别把整页请求打满
final class MediaProbeStore: ObservableObject {
    static let shared = MediaProbeStore()

    @Published private(set) var infos: [String: MediaInfo] = [:]
    @Published private(set) var pending: Set<String> = []

    private var queue: [String] = []
    private var running: Set<String> = []
    private let limit = 3

    func info(for url: String) -> MediaInfo? {
        infos[url]
    }

    func isPending(_ url: String) -> Bool {
        pending.contains(url)
    }

    /// 只在主线程调用（列表行出现时）
    func request(_ url: String) {
        guard !url.isEmpty, infos[url] == nil, !pending.contains(url) else { return }
        pending.insert(url)
        queue.append(url)
        pump()
    }

    private func pump() {
        while running.count < limit, !queue.isEmpty {
            let url = queue.removeFirst()
            running.insert(url)
            Task { [weak self] in
                let info = await MediaProbe.probe(url)
                await MainActor.run {
                    self?.finish(url, info: info)
                }
            }
        }
    }

    private func finish(_ url: String, info: MediaInfo?) {
        running.remove(url)
        pending.remove(url)
        // 没问到也记一条空的，避免滚动时反复重试
        infos[url] = info ?? MediaInfo()
        pump()
    }
}
