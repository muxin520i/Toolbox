import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

// MARK: - 技术信息

/// 播放页「技术信息」用的深度探测结果。
/// 和 MediaProbe 里那个轻量 MediaInfo 分开：那个只问时长和分辨率，这个要逐轨拆编码参数
struct MediaSpec {
    struct VideoTrack: Identifiable {
        let id = UUID()
        var index: Int
        var codec: String
        var width: Int
        var height: Int
        var fps: Double?
        var bitrate: Double?
        var profile: String?
        var color: String?
        var hdr: String?
        var rotation: Int

        var sizeText: String { "\(width)×\(height)" }

        var fpsText: String? {
            guard let fps, fps > 0 else { return nil }
            return String(format: "%.3g fps", fps)
        }

        var bitrateText: String? {
            guard let bitrate, bitrate > 0 else { return nil }
            return String(format: "%.1f Mbps", bitrate / 1_000_000)
        }
    }

    struct AudioTrack: Identifiable {
        let id = UUID()
        var index: Int
        var codec: String
        var channels: Int?
        var sampleRate: Double?
        var bitrate: Double?
        var language: String?

        var channelText: String? {
            guard let channels, channels > 0 else { return nil }
            switch channels {
            case 1: return "单声道"
            case 2: return "立体声"
            case 6: return "5.1 声道"
            case 8: return "7.1 声道"
            default: return "\(channels) 声道"
            }
        }

        var sampleText: String? {
            guard let sampleRate, sampleRate > 0 else { return nil }
            return String(format: "%.1f kHz", sampleRate / 1000)
        }

        var bitrateText: String? {
            guard let bitrate, bitrate > 0 else { return nil }
            return String(format: "%.0f kbps", bitrate / 1000)
        }
    }

    var urlText: String = ""
    var fileName: String = ""
    var isLocal = false
    var fileSize: Int64?
    var duration: Double?
    var container: String = "未知"
    var engine: String = "AVPlayer"
    var video: [VideoTrack] = []
    var audio: [AudioTrack] = []
    var otherTrackCount = 0
    /// 读不出详细信息时的说明
    var note: String?

    var durationText: String? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return Fmt.time(duration)
    }

    var sizeText: String? {
        guard let fileSize, fileSize > 0 else { return nil }
        return Fmt.bytes(fileSize)
    }

    /// 复制到剪贴板用的纯文本，方便贴给别人看
    var plainText: String {
        var lines: [String] = ["工具箱 技术信息"]
        lines.append("文件：\(fileName)")
        lines.append("容器：\(container)")
        lines.append("引擎：\(engine)")
        if let sizeText { lines.append("大小：\(sizeText)") }
        if let durationText { lines.append("时长：\(durationText)") }

        for track in video {
            var parts = ["视频 \(track.index)", track.codec, track.sizeText]
            if let fps = track.fpsText { parts.append(fps) }
            if let bitrate = track.bitrateText { parts.append(bitrate) }
            if let hdr = track.hdr { parts.append(hdr) }
            if let color = track.color { parts.append(color) }
            if let profile = track.profile { parts.append(profile) }
            if track.rotation != 0 { parts.append("旋转 \(track.rotation)°") }
            lines.append(parts.joined(separator: " · "))
        }

        for track in audio {
            var parts = ["音频 \(track.index)", track.codec]
            if let channel = track.channelText { parts.append(channel) }
            if let sample = track.sampleText { parts.append(sample) }
            if let bitrate = track.bitrateText { parts.append(bitrate) }
            if let language = track.language, !language.isEmpty { parts.append(language) }
            lines.append(parts.joined(separator: " · "))
        }

        if otherTrackCount > 0 {
            lines.append("其他轨道：\(otherTrackCount) 条（字幕 / 数据）")
        }
        lines.append("地址：\(urlText)")
        return lines.joined(separator: "\n")
    }
}

// MARK: - 探测

enum MediaSpecReader {
    /// `engine` 是播放页实际用的引擎，VLC 兜底时容器信息会更靠谱
    static func read(url: URL, engine: String, durationHint: Double? = nil) async -> MediaSpec {
        var spec = MediaSpec()
        spec.urlText = url.absoluteString
        spec.fileName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if spec.fileName.isEmpty { spec.fileName = url.host ?? "未知" }
        spec.isLocal = url.isFileURL
        spec.engine = engine
        spec.container = containerName(url)
        spec.duration = durationHint

        if url.isFileURL {
            let attr = try? FileManager.default.attributesOfItem(atPath: url.path)
            spec.fileSize = (attr?[.size] as? NSNumber)?.int64Value
        }

        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.load(.tracks)) ?? []

        if let seconds = try? await asset.load(.duration), seconds.isNumeric {
            let value = seconds.seconds
            if value.isFinite, value > 0 { spec.duration = value }
        }

        var videoIndex = 0
        var audioIndex = 0
        for track in tracks {
            switch track.mediaType {
            case .video:
                videoIndex += 1
                if let info = await videoTrack(track, index: videoIndex) {
                    spec.video.append(info)
                }
            case .audio:
                audioIndex += 1
                if let info = await audioTrack(track, index: audioIndex) {
                    spec.audio.append(info)
                }
            default:
                spec.otherTrackCount += 1
            }
        }

        if spec.video.isEmpty {
            // AVFoundation 读不了（MKV / FLV / RMVB 这类），说清楚原因，别让空白面板像是坏了
            if spec.engine.uppercased().contains("VLC") {
                spec.note = "这个容器系统解码器不认，播放走的是 VLC 内核，编码参数拿不到"
            } else if !tracks.isEmpty {
                spec.note = "没有解析到视频轨"
            } else if url.isFileURL {
                spec.note = "容器为 \(spec.container)，系统解码器读不出轨道信息"
            } else {
                spec.note = "网络地址可能需要在播放器里才能读取轨道信息"
            }
        }

        // 分辨率兜底：AVFoundation 读不出来时，用文件头 / m3u8 里的线索补一次
        if spec.video.isEmpty,
           let probed = await MediaProbe.probe(url.absoluteString),
           let width = probed.width, let height = probed.height {
            spec.video.append(
                MediaSpec.VideoTrack(
                    index: 1,
                    codec: "未知",
                    width: width,
                    height: height,
                    fps: nil,
                    bitrate: nil,
                    profile: nil,
                    color: nil,
                    hdr: nil,
                    rotation: 0
                )
            )
            if spec.duration == nil, let duration = probed.duration {
                spec.duration = duration
            }
        }

        return spec
    }

    // MARK: 轨道

    private static func videoTrack(_ track: AVAssetTrack, index: Int) async -> MediaSpec.VideoTrack? {
        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        let description = descriptions.first
        let subType = description.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0

        let natural = (try? await track.load(.naturalSize)) ?? .zero
        let transform = (try? await track.load(.preferredTransform)) ?? .identity

        // 竖屏视频的编码尺寸是横的，要按 transform 摆正才是看到的宽高
        let oriented = natural.applying(transform)
        var width = Int(abs(oriented.width).rounded())
        var height = Int(abs(oriented.height).rounded())
        if width == 0 || height == 0 {
            width = Int(abs(natural.width).rounded())
            height = Int(abs(natural.height).rounded())
        }

        let radians = atan2(transform.b, transform.a)
        let degrees = Int((radians * 180 / Double.pi).rounded())
        let rotation = ((degrees % 360) + 360) % 360

        let frameRate = (try? await track.load(.nominalFrameRate)).map(Double.init) ?? 0
        let dataRate = (try? await track.load(.estimatedDataRate)).map(Double.init) ?? 0

        var profile: String?
        var color: String?
        var hdr: String?

        if let description,
           let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] {
            if let raw = extensions["ProfileLevel"] as? String {
                profile = profileText(raw)
            }
            let pair = colorText(
                primaries: extensions["ColorPrimaries"] as? String,
                transfer: extensions["TransferFunction"] as? String
            )
            color = pair.color
            hdr = pair.hdr
        }

        return MediaSpec.VideoTrack(
            index: index,
            codec: codecName(subType),
            width: width,
            height: height,
            fps: frameRate > 0 ? frameRate : nil,
            bitrate: dataRate > 0 ? dataRate : nil,
            profile: profile,
            color: color,
            hdr: hdr,
            rotation: rotation
        )
    }

    private static func audioTrack(_ track: AVAssetTrack, index: Int) async -> MediaSpec.AudioTrack? {
        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        let description = descriptions.first
        let subType = description.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0

        var channels: Int?
        var sampleRate: Double?
        if let description,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            if basic.mChannelsPerFrame > 0 { channels = Int(basic.mChannelsPerFrame) }
            if basic.mSampleRate > 0 { sampleRate = basic.mSampleRate }
        }

        let dataRate = (try? await track.load(.estimatedDataRate)).map(Double.init) ?? 0
        var language: String?
        if let code = try? await track.load(.languageCode) {
            language = code
        }

        return MediaSpec.AudioTrack(
            index: index,
            codec: codecName(subType),
            channels: channels,
            sampleRate: sampleRate,
            bitrate: dataRate > 0 ? dataRate : nil,
            language: language
        )
    }

    // MARK: 格式名

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        let text = String(bytes: bytes, encoding: .ascii) ?? "????"
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func codecName(_ subType: FourCharCode) -> String {
        switch fourCC(subType) {
        case "avc1", "avc3": return "H.264 / AVC"
        case "hvc1", "hev1": return "H.265 / HEVC"
        case "vp08": return "VP8"
        case "vp09": return "VP9"
        case "av01": return "AV1"
        case "mp4v": return "MPEG-4 Visual"
        case "ap4h", "ap4x": return "ProRes"
        case "jpeg": return "Motion JPEG"
        case "mp4a": return "AAC"
        case "ac-3": return "AC-3"
        case "ec-3": return "E-AC-3"
        case "alac": return "ALAC"
        case "fLaC": return "FLAC"
        case "Opus": return "Opus"
        case "sowt", "twos", "lpcm", "fl32", "fl64": return "PCM"
        case "dtsc", "dtsh", "dtsl": return "DTS"
        case "tx3g": return "字幕（tx3g）"
        case "wvtt": return "字幕（WebVTT）"
        case "????": return "未知"
        default: return fourCC(subType)
        }
    }

    private static func profileText(_ raw: String) -> String {
        var text = raw
        for prefix in ["H264_", "HEVC_", "MPEG4_", "VP9_", "AV1_"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        text = text.replacingOccurrences(of: "_AutoLevel", with: "")
        text = text.replacingOccurrences(of: "_", with: " ")
        return text
    }

    private static func colorText(primaries: String?, transfer: String?) -> (color: String?, hdr: String?) {
        var color: String?
        var hdr: String?

        switch primaries {
        case "ITU_R_709_2": color = "BT.709"
        case "ITU_R_2020": color = "BT.2020"
        case "P3_D65": color = "Display P3"
        case "SMPTE_C": color = "SMPTE-C"
        case "EBU_3213": color = "EBU 3213"
        default: break
        }

        switch transfer {
        case "ITU_R_709_2":
            hdr = "SDR"
            if color == nil { color = "BT.709" }
        case "SMPTE_240M_1995":
            hdr = "SDR"
        case "SMPTE_ST_2084_PQ":
            hdr = "HDR10（PQ）"
            if color == nil { color = "BT.2020" }
        case "ITU_R_2100_HLG":
            hdr = "HLG"
            if color == nil { color = "BT.2020" }
        default:
            break
        }

        return (color, hdr)
    }

    // MARK: 容器

    /// 先看文件头魔数，再看远程地址后缀
    static func containerName(_ url: URL) -> String {
        if !url.isFileURL {
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "m3u8": return "HLS（m3u8）"
            case "mpd": return "MPEG-DASH"
            case "mp4", "m4v": return "MP4（远程）"
            case "": return "网络流"
            default: return "\(ext.uppercased())（远程）"
            }
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return "未知" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16), data.count >= 8 else { return "未知" }
        let bytes = [UInt8](data)

        func tag(_ range: Range<Int>) -> String {
            guard range.upperBound <= bytes.count else { return "" }
            return String(bytes: bytes[range], encoding: .ascii) ?? ""
        }

        if tag(4..<8) == "ftyp" {
            let brand = tag(8..<12).trimmingCharacters(in: .whitespaces)
            if brand == "qt" { return "QuickTime（MOV）" }
            if brand.hasPrefix("M4A") { return "M4A 音频" }
            if brand.hasPrefix("3gp") { return "3GPP" }
            if brand.hasPrefix("M4V") { return "MP4（M4V）" }
            return brand.isEmpty ? "MP4" : "MP4（\(brand)）"
        }
        if bytes[0] == 0x1A, bytes[1] == 0x45, bytes[2] == 0xDF, bytes[3] == 0xA3 {
            return "Matroska（MKV / WebM）"
        }
        if tag(0..<3) == "FLV" { return "FLV" }
        if tag(0..<4) == "RIFF", tag(8..<12) == "AVI " { return "AVI" }
        if bytes[0] == 0x47 { return "MPEG-TS" }
        if tag(0..<4) == "OggS" { return "Ogg" }
        if bytes[0] == 0x00, bytes[1] == 0x00, bytes[2] == 0x01, bytes[3] == 0xBA {
            return "MPEG-PS"
        }
        if bytes[0] == 0x00, bytes[1] == 0x00, bytes[2] == 0x01, bytes[3] == 0xB3 {
            return "MPEG-1/2 视频"
        }

        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "未知" : ext.uppercased()
    }
}
