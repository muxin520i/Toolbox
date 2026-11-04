import Foundation
import CommonCrypto

/// HLS（m3u8）下载失败原因，直接拿来给用户看
struct HLSFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 主清单里的一个清晰度。下载前让用户挑，别一律拉最高码率
struct HLSVariant: Identifiable, Hashable {
    let url: URL
    let bandwidth: Int
    let width: Int
    let height: Int

    var id: String { url.absoluteString }

    /// 「1080p」「720p」这种一眼能认的短标签
    var shortTitle: String {
        if height > 0 { return "\(height)p" }
        if width > 0 { return "\(width)p" }
        if bandwidth > 0 { return String(format: "%.0f kbps", Double(bandwidth) / 1000) }
        return "未知"
    }

    var detail: String {
        var parts: [String] = []
        if width > 0, height > 0 { parts.append("\(width)×\(height)") }
        if bandwidth > 0 { parts.append(String(format: "%.1f Mbps", Double(bandwidth) / 1_000_000)) }
        return parts.isEmpty ? url.lastPathComponent : parts.joined(separator: " · ")
    }

    /// 估算体积：码率 × 时长
    func estimatedBytes(duration: Double) -> Int64 {
        guard bandwidth > 0, duration > 0 else { return 0 }
        return Int64(Double(bandwidth) / 8 * duration)
    }
}

/// 一条待下载的分片
struct HLSSegment {
    let url: URL
    /// EXT-X-BYTERANGE 的 (长度, 起点)
    var range: (length: Int, offset: Int)? = nil
    /// EXTINF 时长，生成边下边播的清单时要用
    var duration: Double? = nil

    func request(referer: String?, ua: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let referer = referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        if !ua.isEmpty { request.setValue(ua, forHTTPHeaderField: "User-Agent") }
        if let range = range {
            request.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)",
                             forHTTPHeaderField: "Range")
        }
        // 用户配的站点规则优先级最高：防盗链站点就靠这里的 Referer / Cookie
        HTTPHeaderStore.apply(to: &request, url: url)
        return request
    }
}

/// 可落盘的分片记录：重启后按它继续下缺的那几片
struct HLSSegmentRecord: Codable {
    var url: String
    var length: Int?
    var offset: Int?
    /// 旧版 meta.json 里没有这一项，留可选保证还能续传
    var duration: Double?

    var segment: HLSSegment? {
        guard let url = URL(string: url) else { return nil }
        var item: HLSSegment
        if let length = length, let offset = offset {
            item = HLSSegment(url: url, range: (length, offset))
        } else {
            item = HLSSegment(url: url, range: nil)
        }
        item.duration = duration
        return item
    }

    init(url: String, length: Int? = nil, offset: Int? = nil, duration: Double? = nil) {
        self.url = url
        self.length = length
        self.offset = offset
        self.duration = duration
    }

    init(segment: HLSSegment) {
        self.url = segment.url.absoluteString
        self.length = segment.range?.length
        self.offset = segment.range?.offset
        self.duration = segment.duration
    }
}

/// 一条 HLS 下载任务的全部信息，存成 meta.json 就能跨启动续传
struct HLSJob: Codable {
    var segments: [HLSSegmentRecord]
    var initSegment: HLSSegmentRecord?
    var keyBase64: String?
    var ivBase64: String?
    var mediaSequence: Int
    var fileExtension: String
    /// 每个分片的时长；旧任务没有，按 6 秒估
    var durations: [Double]?

    var total: Int { segments.count }
    var key: Data? { keyBase64.flatMap { Data(base64Encoded: $0) } }
    var explicitIV: Data? { ivBase64.flatMap { Data(base64Encoded: $0) } }
}

/// 解析好的播放清单
struct HLSPlaylist {
    var segments: [HLSSegment]
    var initSegment: HLSSegment?
    var keyURI: URL?
    var explicitIV: Data?
    var mediaSequence: Int
    var fileExtension: String
    var durations: [Double]
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
    static func parse(playlistURL: URL,
                      referer: String?,
                      preferredVariant: URL? = nil) async throws -> HLSPlaylist {
        var current = playlistURL
        var text = try await fetchText(current, referer: referer)

        // 主清单：用户指定了就用指定的，没指定挑码率最高的一路
        if text.contains("#EXT-X-STREAM-INF") {
            let variants = parseVariants(text, base: current)
            guard let fallback = variants.max(by: { $0.bandwidth < $1.bandwidth }) else {
                throw HLSFailure(message: "清单里没有可用的清晰度")
            }
            if hasSeparateAudio(text) {
                throw HLSFailure(message: "这个流把音频单独拆开了，合并需要一个完整转码器，暂时下不了")
            }
            let chosen = preferredVariant.flatMap { target in
                variants.first(where: { $0.url == target })
            } ?? fallback
            current = chosen.url
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
        var pendingDuration: Double = 0
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

            if line.hasPrefix("#EXTINF:") {
                let body = line.dropFirst("#EXTINF:".count)
                let value = body.split(separator: ",").first.map(String.init) ?? ""
                pendingDuration = Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
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
            segments.append(HLSSegment(url: url,
                                       range: pendingRange,
                                       duration: pendingDuration > 0 ? pendingDuration : nil))
            pendingRange = nil
            pendingDuration = 0
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
            fileExtension: ext,
            durations: segments.map { $0.duration ?? 6 }
        )
    }

    private struct Variant {
        let url: URL
        let bandwidth: Int
        let width: Int
        let height: Int
    }

    private static func parseVariants(_ text: String, base: URL) -> [Variant] {
        var result: [Variant] = []
        var pendingBandwidth = 0
        var pendingSize = (width: 0, height: 0)
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = attributes(of: line)
                pendingBandwidth = Int(attrs["BANDWIDTH"] ?? "") ?? 0
                // RESOLUTION=1920x1080
                if let res = attrs["RESOLUTION"], res.contains("x") {
                    let bits = res.lowercased().split(separator: "x")
                    if bits.count == 2 {
                        pendingSize = (Int(bits[0]) ?? 0, Int(bits[1]) ?? 0)
                    }
                } else {
                    pendingSize = (0, 0)
                }
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let url = resolve(line, base: base) {
                result.append(Variant(url: url,
                                      bandwidth: pendingBandwidth,
                                      width: pendingSize.width,
                                      height: pendingSize.height))
            }
            pendingBandwidth = 0
            pendingSize = (0, 0)
        }
        return result
    }

    /// 主清单里的可选清晰度。不是主清单（没有 #EXT-X-STREAM-INF）返回空数组
    static func variants(playlistURL: URL, referer: String?) async throws -> [HLSVariant] {
        let text = try await fetchText(playlistURL, referer: referer)
        guard text.contains("#EXT-X-STREAM-INF") else { return [] }
        // 音频单独拆开的流下不了，别把用户引到一个必然会失败的选项上
        guard !hasSeparateAudio(text) else { return [] }

        let list = parseVariants(text, base: playlistURL)
        // 同一分辨率的重复项去掉，按码率从高到低排
        var seen = Set<String>()
        var result: [HLSVariant] = []
        for item in list.sorted(by: { $0.bandwidth > $1.bandwidth }) {
            let key = "\(item.height)x\(item.width)-\(item.bandwidth)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(HLSVariant(url: item.url,
                                     bandwidth: item.bandwidth,
                                     width: item.width,
                                     height: item.height))
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
            var initRequest = initSegment.request(referer: referer, ua: userAgent)
            initRequest.timeoutInterval = 30
            let data = try await fetchData(initRequest, retry: 2)
            try? handle.write(contentsOf: data)
        }

        // 取一次密钥，整条流复用
        var keyData: Data?
        if let keyURI = playlist.keyURI {
            var request = URLRequest(url: keyURI)
            request.timeoutInterval = 20
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if let referer = referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
            HTTPHeaderStore.apply(to: &request, url: keyURI)
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

    /// 单独取一次 AES-128 密钥（分片交给后台任务下载时，密钥提前拿好存进 meta）
    static func fetchKey(for playlist: HLSPlaylist, referer: String?) async throws -> Data? {
        guard let keyURI = playlist.keyURI else { return nil }
        var request = URLRequest(url: keyURI)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referer = referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        HTTPHeaderStore.apply(to: &request, url: keyURI)
        let data = try await fetchData(request, retry: 2)
        guard data.count == 16 else { throw HLSFailure(message: "取解密密钥失败") }
        return data
    }

    static func makeJob(from playlist: HLSPlaylist, key: Data?) -> HLSJob {
        HLSJob(
            segments: playlist.segments.map { HLSSegmentRecord(segment: $0) },
            initSegment: playlist.initSegment.map { HLSSegmentRecord(segment: $0) },
            keyBase64: key?.base64EncodedString(),
            ivBase64: playlist.explicitIV?.base64EncodedString(),
            mediaSequence: playlist.mediaSequence,
            fileExtension: playlist.fileExtension,
            durations: playlist.segments.map { $0.duration ?? 6 }
        )
    }

    /// 拼装时用：按序号解密分片
    static func decrypt(_ data: Data, job: HLSJob, index: Int) -> Data? {
        guard let key = job.key else { return data }
        let iv = job.explicitIV ?? sequenceIV(job.mediaSequence + index)
        return aes128Decrypt(data, key: key, iv: iv)
    }

    private static func segmentData(_ segment: HLSSegment, referer: String?) async throws -> Data {
        try await fetchData(segment.request(referer: referer, ua: userAgent), retry: 3)
    }

    /// 没有显式 IV 时，IV 就是分片序号（大端 16 字节）
    static func sequenceIV(_ sequence: Int) -> Data {
        var value = UInt64(sequence).bigEndian
        var data = Data(repeating: 0, count: 8)
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        return data
    }

    static func aes128Decrypt(_ data: Data, key: Data, iv: Data) -> Data? {
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
        HTTPHeaderStore.apply(to: &request, url: url)
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
