import Foundation

struct SubtitleCue: Identifiable {
    let id = UUID()
    let start: Double
    let end: Double
    let text: String
}

enum SubtitleError: LocalizedError {
    case unreadable
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable: return "字幕文件读不出来，换 UTF-8 编码试试"
        case .empty: return "这个字幕文件里没有可用的时间轴"
        }
    }
}

/// 外挂字幕：支持 srt / vtt，ass / ssa 取纯文本（不带样式）
enum SubtitleLoader {
    static let extensions = ["srt", "vtt", "ass", "ssa"]

    /// 本地视频旁边同名的字幕文件
    static func findSidecar(for video: URL) -> URL? {
        guard video.isFileURL else { return nil }
        let folder = video.deletingLastPathComponent()
        let base = video.deletingPathExtension().lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return nil
        }
        for name in names {
            let url = folder.appendingPathComponent(name)
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            if url.deletingPathExtension().lastPathComponent == base { return url }
        }
        return nil
    }

    static func load(url: URL) throws -> [SubtitleCue] {
        let raw = try Data(contentsOf: url)
        guard let text = String(data: raw, encoding: .utf8)
                ?? String(data: raw, encoding: .utf16)
                ?? String(data: raw, encoding: .isoLatin1) else {
            throw SubtitleError.unreadable
        }

        let ext = url.pathExtension.lowercased()
        let cues: [SubtitleCue]
        if ext == "ass" || ext == "ssa" {
            cues = parseASS(text)
        } else {
            cues = parseBlock(text)
        }

        guard !cues.isEmpty else { throw SubtitleError.empty }
        return cues.sorted { $0.start < $1.start }
    }

    static func cue(at time: Double, in cues: [SubtitleCue]) -> SubtitleCue? {
        guard !cues.isEmpty else { return nil }
        // 台词语句不多，顺序扫一遍就够快；找到就返回
        for cue in cues {
            if time < cue.start - 0.05 { return nil }
            if time >= cue.start && time <= cue.end + 0.05 { return cue }
        }
        return nil
    }

    // MARK: SRT / VTT

    private static func parseBlock(_ text: String) -> [SubtitleCue] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var cues: [SubtitleCue] = []
        let blocks = normalized.components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }

            guard let arrowIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timeLine = lines[arrowIndex]
            let parts = timeLine.components(separatedBy: "-->")
            guard parts.count >= 2 else { continue }

            let startPart = parts[0].trimmingCharacters(in: .whitespaces)
            var endPart = parts[1].trimmingCharacters(in: .whitespaces)
            // VTT 的时间后面可能跟 "align:start position:0%"
            endPart = endPart.components(separatedBy: " ").first ?? endPart

            guard let start = parseTime(startPart), let end = parseTime(endPart), end >= start else { continue }

            let body = lines.dropFirst(arrowIndex + 1).joined(separator: "\n")
            let cleaned = clean(body)
            guard !cleaned.isEmpty else { continue }

            cues.append(SubtitleCue(start: start, end: end, text: cleaned))
        }
        return cues
    }

    // MARK: ASS / SSA

    private static func parseASS(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Dialogue:") else { continue }

            let body = line.dropFirst("Dialogue:".count)
            let fields = body.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
            guard fields.count >= 10 else { continue }

            let startText = String(fields[1]).trimmingCharacters(in: .whitespaces)
            let endText = String(fields[2]).trimmingCharacters(in: .whitespaces)
            guard let start = parseTime(startText),
                  let end = parseTime(endText),
                  end >= start else { continue }

            var content = String(fields[9])
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
            content = clean(content)
            guard !content.isEmpty else { continue }

            cues.append(SubtitleCue(start: start, end: end, text: content))
        }
        return cues
    }

    // MARK: 工具

    /// "00:01:02,500" / "01:02.500" / "0:00:03.2"
    private static func parseTime(_ raw: String) -> Double? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }

        let parts = cleaned.components(separatedBy: ":")
        guard parts.count >= 2, parts.count <= 3 else { return nil }

        var seconds: Double = 0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part) else { return nil }
            if index == parts.count - 1 {
                seconds += value
            } else {
                seconds = (seconds + value) * 60
            }
        }
        return seconds
    }

    /// 去掉 <i>、{\an8}、&nbsp; 这类标记，只留纯文本
    private static func clean(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")

        text = remove(pattern: "\\{[^}]*\\}", in: text)
        text = remove(pattern: "<[^>]{1,20}>", in: text)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func remove(pattern: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}
