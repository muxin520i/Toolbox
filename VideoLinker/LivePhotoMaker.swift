import Foundation
import AVFoundation
import Photos
import UIKit
import UniformTypeIdentifiers

// MARK: - 存成 Live Photo
//
// 从视频里取以当前画面为中心的 3 秒，导出成 .mov，再配一张 JPEG 关键帧，
// 一起写进相册。系统会把同一请求里的「照片 + 配对视频」识别成一张实况照片。
//
// 只支持本机文件：在线流要先完整下载才能截取，否则导出会边下边转，十几分钟都出不来。

enum LivePhotoMaker {

    static func save(from source: URL, at seconds: Double, completion: @escaping (String) -> Void) {
        guard source.isFileURL else {
            DispatchQueue.main.async {
                completion("在线视频先下载到本机，再存 Live Photo")
            }
            return
        }

        let asset = AVURLAsset(url: source)
        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 1 else {
            DispatchQueue.main.async { completion("这个视频读不出时长，换一个本地文件试试") }
            return
        }

        let clipLength = min(3.0, max(1.0, duration))
        var start = seconds - clipLength / 2
        start = max(0, min(start, max(0, duration - clipLength)))
        let keyTime = start + clipLength / 2

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("livephoto-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let videoURL = folder.appendingPathComponent("clip.mov")

        export(asset: asset, start: start, length: clipLength, to: videoURL) { failure in
            if let failure {
                try? FileManager.default.removeItem(at: folder)
                DispatchQueue.main.async { completion(failure) }
                return
            }

            guard let jpeg = keyFrame(of: asset, at: keyTime) else {
                try? FileManager.default.removeItem(at: folder)
                DispatchQueue.main.async { completion("取关键帧失败，这个视频可能不支持导出画面") }
                return
            }
            writeToLibrary(jpeg: jpeg, video: videoURL, folder: folder, completion: completion)
        }
    }

    // MARK: 导出片段

    /// completion 传 nil 表示成功，否则是给用户看的失败原因
    private static func export(asset: AVAsset,
                               start: Double,
                               length: Double,
                               to url: URL,
                               completion: @escaping (String?) -> Void) {
        try? FileManager.default.removeItem(at: url)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            completion("这个视频不支持导出")
            return
        }

        session.outputURL = url
        session.outputFileType = .mov
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: length, preferredTimescale: 600)
        )
        session.shouldOptimizeForNetworkUse = false

        session.exportAsynchronously {
            if session.status == .completed, FileManager.default.fileExists(atPath: url.path) {
                completion(nil)
                return
            }

            // 不支持直通（比如奇怪的编码）时，退回重编码再试一次
            guard let fallback = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                completion("导出失败：\(session.error?.localizedDescription ?? "未知原因")")
                return
            }
            try? FileManager.default.removeItem(at: url)
            fallback.outputURL = url
            fallback.outputFileType = .mov
            fallback.timeRange = session.timeRange
            fallback.exportAsynchronously {
                if fallback.status == .completed, FileManager.default.fileExists(atPath: url.path) {
                    completion(nil)
                } else {
                    completion("导出失败：\(fallback.error?.localizedDescription ?? "这个视频可能受保护")")
                }
            }
        }
    }

    // MARK: 关键帧

    private static func keyFrame(of asset: AVAsset, at seconds: Double) -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.92)
    }

    // MARK: 写相册

    private static func writeToLibrary(jpeg: Data,
                                       video: URL,
                                       folder: URL,
                                       completion: @escaping (String) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: folder)
                DispatchQueue.main.async { completion("没有相册写入权限，去系统设置里打开") }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = Date()
                request.addResource(with: .photo, data: jpeg, options: nil)

                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                options.uniformTypeIdentifier = UTType.quickTimeMovie.identifier
                request.addResource(with: .pairedVideo, fileURL: video, options: options)
            }) { success, error in
                try? FileManager.default.removeItem(at: folder)
                DispatchQueue.main.async {
                    if success {
                        Haptics.success()
                        completion("已存到相册，去「照片」里长按就能设为壁纸")
                    } else {
                        completion("保存失败：\(error?.localizedDescription ?? "未知原因")")
                    }
                }
            }
        }
    }
}
