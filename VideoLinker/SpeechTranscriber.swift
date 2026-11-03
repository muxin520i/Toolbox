import Foundation
import AVFoundation
import Speech
import SwiftUI
import UIKit

// MARK: - 本地语音转字幕
//
// 思路：把视频音轨按 50 秒切段导出成 m4a，逐段交给系统 Speech 框架离线识别，
// 拿回带时间戳的词片段后合成一条条字幕，最后写成 srt 放到「字幕」目录。
// 全程不联网（设备支持离线识别时），音频和识别结果都不出本机。

/// 转写失败时带一句话原因，交给界面显示
struct SpeechFailure: Error {
    let message: String
}

enum SpeechError: LocalizedError {
    case denied
    case unavailable
    case noAudio
    case exportFailed(String)
    case recognizeFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .denied:
            return "没有语音识别权限，去「设置 → 工具箱 → 语音识别」打开"
        case .unavailable:
            return "这台设备的识别服务暂时不可用，稍后再试"
        case .noAudio:
            return "这个视频没有音轨，转不出字幕"
        case .exportFailed(let detail):
            return "读取音轨失败\(detail.isEmpty ? "" : "：\(detail)")"
        case .recognizeFailed(let detail):
            return "识别失败\(detail.isEmpty ? "" : "：\(detail)")"
        case .cancelled:
            return "已取消"
        }
    }
}

final class SpeechTranscriber: ObservableObject {
    static let shared = SpeechTranscriber()

    enum Language: String, CaseIterable, Identifiable {
        case auto
        case chinese = "zh-CN"
        case english = "en-US"
        case japanese = "ja-JP"
        case korean = "ko-KR"
        case cantonese = "yue-CN"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .auto: return "自动（跟随系统语言）"
            case .chinese: return "中文（普通话）"
            case .english: return "English"
            case .japanese: return "日本語"
            case .korean: return "한국어"
            case .cantonese: return "中文（粤语）"
            }
        }

        var localeID: String {
            if self == .auto {
                return Locale.preferredLanguages.first ?? "zh-CN"
            }
            return rawValue
        }
    }

    @Published private(set) var running = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText = ""
    @Published private(set) var errorText = ""

    /// 每段多长。系统的文件识别大约 1 分钟一道坎，留点余量
    private let chunkSeconds: Double = 50

    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var cancelFlag = false
    private var workItem: Task<Void, Never>?

    private init() {}

    // MARK: 对外

    func transcribe(
        video: URL,
        language: Language,
        completion: @escaping (Result<URL, SpeechFailure>) -> Void
    ) {
        guard !running else { return }

        running = true
        progress = 0
        statusText = "准备中…"
        errorText = ""
        setCancelled(false)

        workItem = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                let url = try await self.run(video: video, language: language)
                await MainActor.run {
                    self.running = false
                    self.statusText = ""
                    self.progress = 1
                    completion(.success(url))
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    self.running = false
                    self.statusText = ""
                    if !self.isCancelled() { self.errorText = message }
                    completion(.failure(SpeechFailure(message: message)))
                }
            }
        }
    }

    func cancel() {
        setCancelled(true)
        task?.cancel()
        task = nil
        workItem?.cancel()
        workItem = nil
        DispatchQueue.main.async {
            self.running = false
            self.statusText = "已取消"
        }
    }

    // MARK: 主流程

    private func run(video: URL, language: Language) async throws -> URL {
        guard await Self.requestPermission() else { throw SpeechError.denied }

        let locale = Locale(identifier: language.localeID)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw SpeechError.recognizeFailed("系统不支持 \(language.title)")
        }
        guard recognizer.isAvailable else { throw SpeechError.unavailable }

        let onDevice = recognizer.supportsOnDeviceRecognition

        let asset = AVURLAsset(url: video)
        let duration: Double
        do {
            duration = try await asset.load(.duration).seconds
        } catch {
            throw SpeechError.exportFailed("视频读不出来")
        }
        guard duration.isFinite, duration > 0.6 else { throw SpeechError.noAudio }

        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !audioTracks.isEmpty else { throw SpeechError.noAudio }

        await update(status: onDevice ? "正在本地识别…" : "正在识别（需要联网）…", progress: 0)

        var cues: [SpeechCue] = []
        var start: Double = 0

        while start < duration - 0.05 {
            try checkCancelled()

            let length = min(chunkSeconds, duration - start)
            let range = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: length, preferredTimescale: 600)
            )

            let partURL = try await exportAudio(asset: asset, range: range)

            let segments: [SpeechSegment]
            do {
                segments = try await recognize(url: partURL, recognizer: recognizer, onDevice: onDevice)
            } catch {
                try? FileManager.default.removeItem(at: partURL)
                if isCancelled() { throw SpeechError.cancelled }
                throw error
            }
            try? FileManager.default.removeItem(at: partURL)

            cues.append(contentsOf: Self.makeCues(from: segments, offset: start))

            start += length
            let ratio = min(1, start / duration)
            await update(
                status: "已识别 \(Int(ratio * 100))%（\(Self.timeText(start)) / \(Self.timeText(duration))）",
                progress: ratio
            )
        }

        try checkCancelled()
        guard !cues.isEmpty else {
            throw SpeechError.recognizeFailed("整段都没听出内容，换个语言再试")
        }

        return try Self.write(cues: cues, for: video)
    }

    // MARK: 导出音轨

    private func exportAudio(asset: AVAsset, range: CMTimeRange) async throws -> URL {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-\(UUID().uuidString).m4a")

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw SpeechError.exportFailed("设备不支持导出这种音轨")
        }

        session.outputURL = out
        session.outputFileType = .m4a
        session.timeRange = range
        session.shouldOptimizeForNetworkUse = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: SpeechError.cancelled)
                default:
                    continuation.resume(
                        throwing: SpeechError.exportFailed(session.error?.localizedDescription ?? "")
                    )
                }
            }
        }

        return out
    }

    // MARK: 识别一段

    private func recognize(
        url: URL,
        recognizer: SFSpeechRecognizer,
        onDevice: Bool
    ) async throws -> [SpeechSegment] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SpeechSegment], Error>) in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = onDevice
            request.shouldReportPartialResults = false
            if #available(iOS 16.0, *) {
                request.addsPunctuation = true
            }

            var finished = false
            let once = NSLock()

            self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                once.lock()
                defer { once.unlock() }
                guard !finished else { return }

                if let result = result, result.isFinal {
                    finished = true
                    let segments = result.bestTranscription.segments.map {
                        SpeechSegment(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                    }
                    self?.task = nil
                    continuation.resume(returning: segments)
                    return
                }

                if let error = error {
                    finished = true
                    self?.task = nil

                    // 203 / 216 / 1110：这一段没听清或没检测到语音，跳过继续，
                    // 不要因为一句空白把整部片子废掉
                    let code = (error as NSError).code
                    if [203, 216, 1110].contains(code) {
                        continuation.resume(returning: [])
                    } else {
                        continuation.resume(throwing: SpeechError.recognizeFailed(error.localizedDescription))
                    }
                }
            }
        }
    }

    // MARK: 片段合成字幕

    private struct SpeechSegment {
        let text: String
        let start: Double
        let duration: Double
    }

    private struct SpeechCue {
        let start: Double
        let end: Double
        let text: String
    }

    /// 系统返回的是词，直接一条一个词会闪得没法看。
    /// 这里按「不超过 24 个字 / 不超过 6 秒 / 停顿超过 0.8 秒」合成整句。
    private static func makeCues(from segments: [SpeechSegment], offset: Double) -> [SpeechCue] {
        var cues: [SpeechCue] = []
        var buffer = ""
        var start: Double?
        var end: Double = 0
        var lastEnd: Double = 0

        func flush() {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if let begin = start, !text.isEmpty {
                cues.append(SpeechCue(start: begin + offset, end: max(end, begin + 0.4) + offset, text: text))
            }
            buffer = ""
            start = nil
        }

        for segment in segments {
            let piece = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }

            let gap = start == nil ? 0 : segment.start - lastEnd
            let tooLong = buffer.count + piece.count > 24
            let tooSlow = start.map { segment.start + segment.duration - $0 > 6 } ?? false

            if start != nil, gap > 0.8 || tooLong || tooSlow {
                flush()
            }

            if start == nil { start = segment.start }
            buffer += needsSpace(buffer: buffer, piece: piece) ? " " + piece : piece
            end = segment.start + segment.duration
            lastEnd = end
        }
        flush()

        // 相邻且间隔很小的两条并起来，读起来更连贯
        var merged: [SpeechCue] = []
        for cue in cues {
            if let last = merged.last,
               cue.start - last.end < 0.25,
               last.text.count + cue.text.count <= 30 {
                merged[merged.count - 1] = SpeechCue(
                    start: last.start,
                    end: max(last.end, cue.end),
                    text: last.text + cue.text
                )
            } else {
                merged.append(cue)
            }
        }
        return merged
    }

    /// 英文单词之间要空格，中文不用
    private static func needsSpace(buffer: String, piece: String) -> Bool {
        guard let last = buffer.unicodeScalars.last, let first = piece.unicodeScalars.first else {
            return false
        }
        if isCJK(last) || isCJK(first) { return false }
        return true
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,     // 日文假名
             0x3400...0x4DBF,     // 扩展 A
             0x4E00...0x9FFF,     // 基本汉字
             0xAC00...0xD7AF,     // 韩文
             0xF900...0xFAFF:     // 兼容汉字
            return true
        default:
            return false
        }
    }

    // MARK: 写文件

    private static func write(cues: [SpeechCue], for video: URL) throws -> URL {
        let dir = subtitleDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let base = video.deletingPathExtension().lastPathComponent
        var target = dir.appendingPathComponent(base + ".srt")
        if FileManager.default.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent(base + "-语音.srt")
        }
        if FileManager.default.fileExists(atPath: target.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            target = dir.appendingPathComponent(base + "-语音-\(stamp).srt")
        }

        var text = ""
        for (index, cue) in cues.enumerated() {
            text += "\(index + 1)\n"
            text += "\(srtTime(cue.start)) --> \(srtTime(cue.end))\n"
            text += cue.text + "\n\n"
        }

        try text.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    static func subtitleDirectory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("字幕", isDirectory: true)
    }

    private static func srtTime(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let secs = Int(total) % 60
        let millis = Int((total - Double(Int(total))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }

    private static func timeText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    // MARK: 权限

    private static func requestPermission() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        if status == .denied || status == .restricted { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { result in
                continuation.resume(returning: result == .authorized)
            }
        }
    }

    // MARK: 状态

    private func update(status: String, progress: Double) async {
        await MainActor.run {
            guard !self.isCancelled() else { return }
            self.statusText = status
            self.progress = progress
        }
    }

    private func checkCancelled() throws {
        if isCancelled() { throw SpeechError.cancelled }
        if Task.isCancelled { throw SpeechError.cancelled }
    }

    private func setCancelled(_ value: Bool) {
        lock.lock()
        cancelFlag = value
        lock.unlock()
    }

    private func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelFlag
    }
}

// MARK: - 生成字幕的界面

struct SpeechSubtitleSheet: View {
    let videoURL: URL
    var onFinish: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var transcriber = SpeechTranscriber.shared
    @State private var language: SpeechTranscriber.Language = .auto

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    headerCard
                    if transcriber.running {
                        runningCard
                    } else {
                        setupCard
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("语音生成字幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(transcriber.running ? "停止" : "关闭") {
                        if transcriber.running { transcriber.cancel() }
                        dismiss()
                    }
                }
            }
            .interactiveDismissDisabled(transcriber.running)
        }
        .onDisappear {
            if transcriber.running { transcriber.cancel() }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("把这部片子的音轨转成字幕")
                .font(.system(size: 16, weight: .semibold))

            Text("用系统语音识别，在本机完成，音频不上传。生成的 srt 会存到「文件 → 工具箱 → 字幕」，下次打开自动加载。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(videoURL.lastPathComponent)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var setupCard: some View {
        VStack(spacing: 14) {
            HStack {
                Text("识别语言")
                    .font(.system(size: 14))
                Spacer()
                Picker("", selection: $language) {
                    ForEach(SpeechTranscriber.Language.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.menu)
            }

            if !transcriber.errorText.isEmpty {
                Text(transcriber.errorText)
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                transcriber.transcribe(video: videoURL, language: language) { result in
                    if case .success(let url) = result {
                        onFinish(url)
                        dismiss()
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 14, weight: .semibold))
                    Text("开始生成")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.accentColor)
                )
            }
            .buttonStyle(.plain)

            Text("一小时的片子大概要几分钟。识别过程中可以退出这个页面，回来还能接着等。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var runningCard: some View {
        VStack(spacing: 14) {
            ProgressView(value: min(max(transcriber.progress, 0), 1))
                .progressViewStyle(.linear)

            Text(transcriber.statusText.isEmpty ? "正在识别…" : transcriber.statusText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Button {
                transcriber.cancel()
            } label: {
                Text("停止")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
