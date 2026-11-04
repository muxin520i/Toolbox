import Foundation
import AVFoundation

// MARK: - 按段解音轨
//
// 之前用 AVAssetExportSession 一段段导出 m4a，两个坑：
//   · .ts 裸流、部分 mkv 的时长是「不确定」，导出会话拿不到 timeRange 直接报错
//   · 导出预设对音轨编码挑剔，AC-3、E-AC3 之类会整段失败
// 改成 AVAssetReader 直接读 PCM：只要轨道能解开，就能一路读到文件尾，
// 不需要总时长，也不挑编码。每攒够 50 秒写一个 16 kHz 单声道 WAV 交给识别。

final class AudioChunkReader {

    struct Chunk {
        let url: URL
        /// 这一段在整片里的起点（秒）
        let start: Double
        let seconds: Double
    }

    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let format: AVAudioFormat
    private let sampleRate: Double
    private let chunkFrames: AVAudioFramePosition

    /// 已经交出去的帧数，用来算下一段的起点
    private var written: AVAudioFramePosition = 0
    private var finished = false

    init(asset: AVAsset, chunkSeconds: Double = 50, sampleRate: Double = 16000) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw SpeechError.noAudio }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw SpeechError.exportFailed("音轨格式不支持")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw SpeechError.exportFailed("这个文件系统解不开（常见于 .ts 裸流）")
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw SpeechError.exportFailed("音轨格式设备不支持")
        }
        reader.add(output)

        guard reader.startReading() else {
            throw SpeechError.exportFailed(reader.error?.localizedDescription ?? "音轨读不出来")
        }

        self.reader = reader
        self.output = output
        self.format = format
        self.sampleRate = sampleRate
        self.chunkFrames = AVAudioFramePosition(sampleRate * max(10, chunkSeconds))
    }

    deinit {
        if reader.status == .reading { reader.cancelReading() }
    }

    /// 读下一段。返回 nil 表示整条音轨读完了
    func nextChunk() throws -> Chunk? {
        guard !finished else { return nil }

        let start = Double(written) / sampleRate
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-\(UUID().uuidString).wav")

        var frames: AVAudioFramePosition = 0
        var opened = false
        var file: AVAudioFile?

        while frames < chunkFrames {
            guard let sample = output.copyNextSampleBuffer() else {
                finished = true
                break
            }

            guard let buffer = Self.makeBuffer(from: sample, format: format) else { continue }

            if file == nil {
                do {
                    file = try AVAudioFile(forWriting: url, settings: format.settings)
                } catch {
                    throw SpeechError.exportFailed("临时音频写不出来")
                }
                opened = true
            }

            do {
                try file?.write(from: buffer)
            } catch {
                throw SpeechError.exportFailed("临时音频写不出来")
            }

            frames += AVAudioFramePosition(buffer.frameLength)
            written += AVAudioFramePosition(buffer.frameLength)
        }

        // 这里放开引用，AVAudioFile 析构时才会把 WAV 头补完
        file = nil

        if reader.status == .failed, frames == 0 {
            throw SpeechError.exportFailed(reader.error?.localizedDescription ?? "音轨读取中断")
        }

        guard opened, frames > 0 else { return nil }
        return Chunk(url: url, start: start, seconds: Double(frames) / sampleRate)
    }

    func cancel() {
        if reader.status == .reading { reader.cancelReading() }
    }

    /// CMSampleBuffer → AVAudioPCMBuffer。拷一份，别让 buffer 指到已释放的 block 上
    private static func makeBuffer(from sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        var needed = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: &needed,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard status == noErr, needed > 0 else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)

        var block: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: needed,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &block
        )
        guard status == noErr else { return nil }

        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames

        let source = UnsafeMutableAudioBufferListPointer(list)
        let target = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for index in 0..<min(source.count, target.count) {
            guard let from = source[index].mData, let to = target[index].mData else { continue }
            let bytes = Int(min(source[index].mDataByteSize, target[index].mDataByteSize))
            if bytes > 0 { memcpy(to, from, bytes) }
        }

        // block 在作用域结束前一直有效，上面已经拷完
        _ = block
        return buffer
    }
}
