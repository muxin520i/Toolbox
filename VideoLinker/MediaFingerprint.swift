import Foundation
import AVFoundation
import CoreGraphics
import UIKit

// MARK: - 画面指纹
//
// 只按文件大小判重会把同尺寸的不同片子误杀，也漏掉同一部剧的不同清晰度。
// 这里抽一帧画面算 dHash（64 位），汉明距离足够近就当成同一个视频。
// 指纹按「路径 + 大小 + 修改时间」缓存，第二次扫描不用重新解码。

enum MediaFingerprint {

    /// 9 × 8 灰度，横向比较相邻像素，得到 64 位指纹
    static func dHash(image: CGImage) -> UInt64 {
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)

        let space = CGColorSpaceCreateDeviceGray()
        var hash: UInt64 = 0

        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: space,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }

            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

            // 读的时候必须走这块 buffer，回头再下标访问 pixels 会撞上独占访问检查
            let gray = buffer.bindMemory(to: UInt8.self)
            for row in 0..<height {
                for column in 0..<(width - 1) {
                    let left = gray[row * width + column]
                    let right = gray[row * width + column + 1]
                    if left > right {
                        hash |= (UInt64(1) << UInt64(row * (width - 1) + column))
                    }
                }
            }
        }

        return hash
    }

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// 抽一帧算指纹。时间点避开片头黑帧，短片段取中间
    static func frameHash(url: URL, duration: Double?) async -> UInt64? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 80, height: 80)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.5, preferredTimescale: 600)

        let seconds: Double
        if let duration = duration, duration > 1 {
            seconds = min(max(duration * 0.15, 2), duration * 0.5)
        } else {
            seconds = 3
        }

        do {
            let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            let hash = dHash(image: image)
            return hash == 0 ? nil : hash
        } catch {
            return nil
        }
    }

    static func duration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let value = try? await asset.load(.duration).seconds,
              value.isFinite, value > 0 else { return nil }
        return value
    }
}

// MARK: - 指纹缓存

struct FingerprintEntry: Codable {
    let hash: String
    let size: Int64
    let modified: Double
    let duration: Double?
}

enum FingerprintStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("fingerprints.json")
    }

    static func load() -> [String: FingerprintEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let map = try? JSONDecoder().decode([String: FingerprintEntry].self, from: data) else {
            return [:]
        }
        return map
    }

    static func save(_ map: [String: FingerprintEntry]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - 查重扫描

enum DuplicateScanner {

    struct Group: Identifiable {
        let id = UUID()
        let hash: UInt64
        var files: [LocalMediaFile]
        var durations: [String: Double]

        var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
        var waste: Int64 {
            guard let biggest = files.max(by: { $0.size < $1.size }) else { return 0 }
            return totalSize - biggest.size
        }
    }

    struct Result {
        var groups: [Group]
        var scanned: Int
        var failed: Int
        var cached: Int
    }

    /// 小于这个尺寸的文件不参与，预览图、音轨之类没必要算
    private static let minSize: Int64 = 2 * 1024 * 1024

    static func scan(
        files: [LocalMediaFile],
        progress: @escaping (Int, Int) -> Void
    ) async -> Result {
        var cache = FingerprintStore.load()
        var next: [String: FingerprintEntry] = [:]

        let candidates = files.filter { $0.size >= minSize }
        var measured: [(file: LocalMediaFile, hash: UInt64, duration: Double?)] = []
        var failed = 0
        var hit = 0

        // 抽帧是重活，3 路并发已经能把 I/O 吃满，再多反而互相拖慢
        let cacheSnapshot = cache
        await withTaskGroup(of: (Int, UInt64?, Double?).self) { group in
            var iterator = candidates.enumerated().makeIterator()

            for _ in 0..<3 {
                guard let (index, file) = iterator.next() else { break }
                group.addTask {
                    await measure(file: file, index: index, cache: cacheSnapshot)
                }
            }

            var done = 0
            for await (index, hash, duration) in group {
                let file = candidates[index]
                done += 1
                progress(done, candidates.count)

                let modified = file.modified.timeIntervalSince1970
                if let cached = cacheSnapshot[file.path],
                   cached.size == file.size,
                   abs(cached.modified - modified) < 0.5 {
                    hit += 1
                }

                if let hash = hash {
                    measured.append((file, hash, duration))
                    next[file.path] = FingerprintEntry(
                        hash: String(hash),
                        size: file.size,
                        modified: modified,
                        duration: duration
                    )
                } else {
                    failed += 1
                }

                if let (nextIndex, nextFile) = iterator.next() {
                    group.addTask {
                        await measure(file: nextFile, index: nextIndex, cache: cacheSnapshot)
                    }
                }
            }
        }

        // 清掉已经不在盘上的记录，缓存别无限长
        let alive = Set(candidates.map { $0.path })
        cache = cache.filter { alive.contains($0.key) }
        cache.merge(next) { _, new in new }
        FingerprintStore.save(cache)

        return Result(
            groups: cluster(measured),
            scanned: candidates.count,
            failed: failed,
            cached: hit
        )
    }

    private static func measure(
        file: LocalMediaFile,
        index: Int,
        cache: [String: FingerprintEntry]
    ) async -> (Int, UInt64?, Double?) {
        let modified = file.modified.timeIntervalSince1970
        if let entry = cache[file.path],
           entry.size == file.size,
           abs(entry.modified - modified) < 0.5,
           let hash = UInt64(entry.hash) {
            return (index, hash, entry.duration)
        }

        let duration: Double?
        if let known = file.duration {
            duration = known
        } else {
            duration = await MediaFingerprint.duration(of: file.url)
        }

        let hash = await MediaFingerprint.frameHash(url: file.url, duration: duration)
        return (index, hash, duration)
    }

    /// 距离 ≤ 6（64 位里差 6 位以内）且时长接近才归为一组
    private static func cluster(        _ items: [(file: LocalMediaFile, hash: UInt64, duration: Double?)]
    ) -> [Group] {
        var groups: [Group] = []

        for item in items {
            var bestIndex: Int?
            var bestDistance = Int.max

            for (index, group) in groups.enumerated() {
                let distance = MediaFingerprint.hamming(item.hash, group.hash)
                guard distance <= 6 else { continue }
                guard durationCompatible(item.duration, group.durations[group.files[0].path]) else { continue }
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }

            if let index = bestIndex {
                groups[index].files.append(item.file)
                if let duration = item.duration {
                    groups[index].durations[item.file.path] = duration
                }
            } else {
                var durations: [String: Double] = [:]
                if let duration = item.duration { durations[item.file.path] = duration }
                groups.append(Group(hash: item.hash, files: [item.file], durations: durations))
            }
        }

        // 只留真有重复的，同组内按大小从大到小，方便默认保留最大的
        return groups
            .filter { $0.files.count > 1 }
            .map { group in
                var copy = group
                copy.files.sort { $0.size > $1.size }
                return copy
            }
            .sorted { $0.waste > $1.waste }
    }

    private static func durationCompatible(_ a: Double?, _ b: Double?) -> Bool {
        guard let a = a, let b = b, a > 0, b > 0 else { return true }
        let diff = abs(a - b)
        return diff <= max(4, max(a, b) * 0.12)
    }
}
