import Foundation
import CommonCrypto

/// HLS（m3u8）下载失败原因，直接拿来给用户看
struct HLSFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 一条待下载的分片
struct HLSSegment {
    let url: URL
    /// EXT-X-BYTERANGE 的 (长度, 起点)
    var range: (length: Int, offset: Int)? = nil

    func request(referer: String?, ua: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        if let referer = referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        if let range = range {
            request.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)",
                             forHTTPHeaderField: "Range")
        }
        return request
    }
}

/// 解析好的播放清单
struct HLSPlaylist {
    var segments: [HLSSegment]
    var initSegment: HLSSegment?
    var keyURI: URL?
    var explicitIV: Data?
    var mediaSequence: Int
    var fileExtension: String
}

/// 纯 Swift 的 HLS 下载：解析清单 → 取密钥 → 并下载分片 → 解密 → 按顺序拼成一个文件
enum HLSDownloader {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 判断一个地址看起来像不像 m3u8
    static func looksLikeHLS(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" || ext == "m3u" { return true }
        return false
    }

    /// 判断一段内容是不是 m3u8（有些地址没有后缀）
    static func isPlaylistContent(_ data: Data) -> Bool {
        guard data.count < 2_000_000 else { return false }
        let head = String(decoding: data.prefix(64), as: UTF8.self)
        return head.hasPrefix("#EXTM3U")
    }

    // MARK: - 解析

    /// 解析清单（主清单会自动选中码率最高的那一路）
    static func parse(playlistURL: URL, referer: String?) async throws -> HLSPlaylist {
        var current = playlistURL
        var text = try await fetchText(current, referer: referer)

        // 主清单：挑码率最高的一路
        if text.contains("#EXT-X-STREAM-INF") {
            let variants = parseVariants(text, base: current)
            guard let best = variants.max(by: { $0.bandwidth < $1.bandwidth }) else {
                throw HLSFailure(message: "清单里没有可用的清晰度")
            }
            if hasSeparateAudio(text) {
                throw HLSFailure(message: "这个流把音频单独拆开了，合并需要一个完整转码器，暂时下不了")
            }
            current = best.url
            text = try await fetchText(current, referer: referer)
        }

        guard text.contains("#EXTINF") || text.contains("#EXT-X-TARGETDURATION") else {
            throw HLSFailure(message: "这不是可下载的 m3u8 清单")
        }

        var segments: [HLSSegment] = []
        var initSegment: HLSSegment?
        var keyURI: URL?
        var explicitIV: Data?
        var mediaSequence = 0
        var pendingRange: (length: Int, offset: Int)?
        var nextOffset = 0
        var usesFMP4 = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
                continue
            }

            if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = attributes(of: line)
                let method = (attrs["METHOD"] ?? "NONE").uppercased()
                if method == "NONE" {
                    keyURI = nil
                    explicitIV = nil
                } else if method == "AES-128" {
                    if let uri = attrs["URI"], let resolved = resolve(uri, base: current) {
                        keyURI = resolved
                    }
                    if let iv = attrs["IV"] {
                        explicitIV = dataFromHex(iv)
                    }
                } else {
                    throw HLSFailure(message: "这个流用了 \(method) 加密（DRM），解不开")
                }
                continue
            }

            if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = attributes(of: line)
                if let uri = attrs["URI"], let resolved = resolve(uri, base: current) {
                    initSegment = HLSSegment(url: resolved)
                    usesFMP4 = true
                }
                continue
            }

            if line.hasPrefix("#EXT-X-BYTERANGE:") {
                let body = line.dropFirst("#EXT-X-BYTERANGE:".count)
                let parts = body.split(separator: "@")
                if let length = Int(parts.first ?? "") {
                    let offset = parts.count > 1 ? (Int(parts[1]) ?? 0) : nextOffset
                    pendingRange = (length, offset)
                    nextOffset = offset + length
                }
                continue
            }

            if line.hasPrefix("#") { continue }

            guard let url = resolve(line, base: current) else { continue }
            segments.append(HLSSegment(url: url, range: pendingRange))
            pendingRange = nil
        }

        guard !segments.isEmpty else {
            throw HLSFailure(message: "清单里没有分片")
        }

        let ext = usesFMP4 ? "mp4" : "ts"
        return HLSPlaylist(
            segments: segments,
            initSegment: initSegment,
            keyURI: keyURI,
            explicitIV: explicitIV,
            mediaSequence: mediaSequence,
            fileExtension: ext
        )
    }

    private struct Variant {
        let url: URL
        let bandwidth: Int
    }

    private static func parseVariants(_ text: String, base: URL) -> [Variant] {
        var result: [Variant] = []
        var pendingBandwidth = 0
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = attributes(of: line)
                pendingBandwidth = Int(attrs["BANDWIDTH"] ?? "") ?? 0
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let url = resolve(line, base: base) {
                result.append(Variant(url: url, bandwidth: pendingBandwidth))
            }
            pendingBandwidth = 0
        }
        return result
    }

    /// 主清单里如果声明了独立的音频轨，合并要靠转码器，先提示
    private static func hasSeparateAudio(_ text: String) -> Bool {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-MEDIA:") else { continue }
            let attrs = attributes(of: line)
            if (attrs["TYPE"] ?? "").uppercased() == "AUDIO", attrs["URI"] != nil {
                return true
            }
        }
        return false
    }

    /// 解析 KEY/VALUE 形式的属性列表，引号里的逗号不算分隔
    private static func attributes(of line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        let body = String(line[line.index(after: colon)...])
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var inQuotes = false
        var readingKey = true

        for ch in body {
            if ch == "\"" {
                inQuotes.toggle()
                if readingKey { continue }
                continue
            }
            if ch == "=" && !inQuotes && readingKey {
                readingKey = false
                continue
            }
            if ch == "," && !inQuotes {
                if !key.isEmpty { result[key.uppercased()] = value }
                key = ""
                value = ""
                readingKey = true
                continue
            }
            if readingKey { key.append(ch) } else { value.append(ch) }
        }
        if !key.isEmpty { result[key.uppercased()] = value }
        return result
    }

    private static func resolve(_ uri: String, base: URL) -> URL? {
        let trimmed = uri.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }

    private static func dataFromHex(_ text: String) -> Data? {
        var hex = text.lowercased()
        if hex.hasPrefix("0x") { hex = String(hex.dropFirst(2)) }
        guard hex.count % 2 == 0 else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    // MARK: - 下载

    /// 真正把分片拉下来并合并写入 dest
    static func download(_ playlist: HLSPlaylist,
                         referer: String?,
                         to dest: URL,
                         progress: @escaping (Double) -> Void) async throws {
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: dest) else {
            throw HLSFailure(message: "写文件失败，存储空间可能不够")
        }
        defer { try? handle.close() }

        let segments = playlist.segments
        let total = segments.count
        var written = 0

        // 先下初始化段（fMP4 需要）
        if let initSegment = playlist.initSegment {
            let data = try await fetchData(initSegment.request(referer: referer, ua: userAgent), retry: 2)
            try? handle.write(contentsOf: data)
        }

        // 取一次密钥，整条流复用
        var keyData: Data?
        if let keyURI = playlist.keyURI {
            var request = URLRequest(url: keyURI)
            request.timeoutInterval = 20
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if let referer = referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
            keyData = try await fetchData(request, retry: 2)
            guard keyData?.count == 16 else {
                throw HLSFailure(message: "取解密密钥失败")
            }
        }

        let window = 5
        var buffer: [Int: Data] = [:]
        var nextToWrite = 0
        var scheduled = 0

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            while scheduled < min(window, total) {
                let index = scheduled
                scheduled += 1
                group.addTask {
                    try Task.checkCancellation()
                    return (index, try await segmentData(segments[index], referer: referer))
                }
            }

            while let (index, data) = try await group.next() {
                buffer[index] = data

                while let ready = buffer.removeValue(forKey: nextToWrite) {
                    var output = ready
                    if let key = keyData {
                        let iv = playlist.explicitIV ?? sequenceIV(playlist.mediaSequence + nextToWrite)
                        guard let plain = aes128Decrypt(output, key: key, iv: iv) else {
                            throw HLSFailure(message: "分片解密失败")
                        }
                        output = plain
                    }
                    try? handle.write(contentsOf: output)
                    written += 1
                    nextToWrite += 1
                }

                progress(min(1, Double(written) / Double(total)))

                if scheduled < total {
                    try Task.checkCancellation()
                    let index = scheduled
                    scheduled += 1
                    group.addTask {
                        try Task.checkCancellation()
                        return (index, try await segmentData(segments[index], referer: referer))
                    }
                }
            }
        }

        progress(1)
    }

    private static func segmentData(_ segment: HLSSegment, referer: String?) async throws -> Data {
        try await fetchData(segment.request(referer: referer, ua: userAgent), retry: 3)
    }

    /// 没有显式 IV 时，IV 就是分片序号（大端 16 字节）
    private static func sequenceIV(_ sequence: Int) -> Data {
        var value = UInt64(sequence).bigEndian
        var data = Data(repeating: 0, count: 8)
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        return data
    }

    private static func aes128Decrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == 16, iv.count == 16, !data.isEmpty else { return nil }

        let inputCount = data.count
        let keyCount = key.count
        let capacity = inputCount + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var moved: size_t = 0

        let status = output.withUnsafeMutableBytes { outPtr -> Int32 in
            data.withUnsafeBytes { dataPtr -> Int32 in
                key.withUnsafeBytes { keyPtr -> Int32 in
                    iv.withUnsafeBytes { ivPtr -> Int32 in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, keyCount,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, inputCount,
                            outPtr.baseAddress, capacity,
                            &moved
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        output.removeSubrange(moved..<output.count)
        return output
    }

    // MARK: - 网络

    private static func fetchText(_ url: URL, referer: String?) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referer = referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        let data = try await fetchData(request, retry: 2)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw HLSFailure(message: "清单读不出来")
        }
        return text
    }

    private static func fetchData(_ request: URLRequest, retry: Int) async throws -> Data {
        var lastError: Error?
        for attempt in 0...max(0, retry) {
            try Task.checkCancellation()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    throw HLSFailure(message: "服务器返回 \(http.statusCode)")
                }
                return data
            } catch {
                lastError = error
                if attempt < retry {
                    try? await Task.sleep(nanoseconds: UInt64(300_000_000 * (attempt + 1)))
                }
            }
        }
        throw lastError ?? HLSFailure(message: "网络请求失败")
    }
}
