import Foundation
import AVFoundation

/// 把 HLS 拼出来的裸流（.ts）重封装成 mp4。
/// 默认只换容器、不重新编码，几秒内完成、画质无损；
/// 容器实在不兼容时才退回一次转码（只对大文件做保护）。
enum MediaRemuxer {

    enum RemuxError: LocalizedError {
        case noVideoTrack
        case sessionUnavailable
        case unsupported
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                return "文件里没有视频轨道，可能没下载完整"
            case .sessionUnavailable:
                return "系统无法解析这个文件"
            case .unsupported:
                return "这个格式转不了 MP4"
            case .exportFailed(let text):
                return text
            }
        }
    }

    /// 超过这个大小就不再尝试转码，避免手机长时间高负载
    private static let transcodeLimit: Int64 = 500 * 1024 * 1024

    /// 已经是 mp4/mov 的原样返回，其余尝试重封装
    static func remuxIfNeeded(_ url: URL) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        if ["mp4", "m4v", "mov"].contains(ext) { return url }
        return try await remuxToMP4(url)
    }

    static func remuxToMP4(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw RemuxError.noVideoTrack }

        let target = url.deletingPathExtension().appendingPathExtension("mp4")

        do {
            try await export(asset: asset, to: target, preset: AVAssetExportPresetPassthrough)
        } catch {
            // 转封装失败（容器/编码组合少见），文件不大时再转一次码兜底
            let size = fileSize(url)
            guard size > 0, size <= transcodeLimit else { throw error }
            try await export(asset: asset, to: target, preset: AVAssetExportPresetHighestQuality)
        }

        // 容器转换成功，原始分片文件就没用了
        try? FileManager.default.removeItem(at: url)
        return target
    }

    private static func export(asset: AVAsset, to target: URL, preset: String) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw RemuxError.sessionUnavailable
        }

        try? FileManager.default.removeItem(at: target)

        let type: AVFileType
        if session.supportedFileTypes.contains(.mp4) {
            type = .mp4
        } else if session.supportedFileTypes.contains(.mov) {
            type = .mov
        } else {
            throw RemuxError.unsupported
        }

        session.shouldOptimizeForNetworkUse = true

        if #available(iOS 18.0, *) {
            try await session.export(to: target, as: type)
        } else {
            session.outputURL = target
            session.outputFileType = type
            try await session.export()
        }

        guard FileManager.default.fileExists(atPath: target.path) else {
            throw RemuxError.exportFailed("合并后没有生成文件")
        }
        guard fileSize(target) > 0 else {
            throw RemuxError.exportFailed("合并出来的文件是空的")
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
    }
}
