import Foundation
import Network

// MARK: - SMB 流播放代理
//
// 播放器不认识 smb://，这里在 127.0.0.1 起一个只服务本机的 HTTP：
//
//   GET /stream?p=<路径>          回前 8 MB（供播放器探测头部）
//   GET /stream?p=<路径>+Range    按字节范围从共享读，一次最多回 8 MB
//
// 播放器要哪段读哪段，不会把整个文件拖进内存。文件只在点播期间存在，
// 播放器关掉后代理可以继续留着（连接是懒建立的，不占共享带宽）。

final class SMBStreamServer {
    static let shared = SMBStreamServer()

    /// 单次响应最多回多少字节，超出就截断，播放器会再发小请求
    private let maxChunk = 8 * 1024 * 1024

    private let queue = DispatchQueue(label: "toolbox.smb.stream")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private(set) var port: UInt16 = 0
    /// 取共享连接：播放期间可能被换掉，每次请求都重新要
    private var provider: (() -> SMBShareClient?)?

    private var candidates: [UInt16] = [8074, 8075, 8076, 8077, 8078]

    private init() {}

    // MARK: 对外

    /// 给一个共享起代理，成功后拿到 base URL（http://127.0.0.1:port）
    func start(provider: @escaping () -> SMBShareClient?) async -> URL? {
        self.provider = provider
        if let url = baseURL() { return url }
        return await withCheckedContinuation { continuation in
            listen(at: 0, continuation: continuation)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            for c in self.connections.values {
                c.connection.cancel()
            }
            self.connections.removeAll()
            self.port = 0
            self.provider = nil
        }
    }

    func baseURL() -> URL? {
        port > 0 ? URL(string: "http://127.0.0.1:\(port)") : nil
    }

    /// 某个共享文件对应的流地址
    func streamURL(for path: String) -> URL? {
        guard let base = baseURL() else { return nil }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "\(base.absoluteString)stream?p=\(encoded)")
    }

    // MARK: 监听

    private func listen(at position: Int, continuation: CheckedContinuation<URL?, Never>) {
        guard position < candidates.count else {
            continuation.resume(returning: nil)
            return
        }
        let port = candidates[position]
        guard let endpoint = NWEndpoint.Port(rawValue: port) else {
            listen(at: position + 1, continuation: continuation)
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 只收本机连接
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: endpoint)

        do {
            let listener = try NWListener(using: params, on: endpoint)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = port
                    continuation.resume(returning: self.baseURL())
                case .failed:
                    listener.cancel()
                    if self.listener === listener { self.listener = nil }
                    self.listen(at: position + 1, continuation: continuation)
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            listen(at: position + 1, continuation: continuation)
        }
    }

    // MARK: 连接

    private final class Connection {
        let connection: NWConnection
        var buffer = Data()

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = Connection(connection: connection)
        connections[ObjectIdentifier(connection)] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close(client)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(client)
    }

    private func close(_ client: Connection) {
        connections.removeValue(forKey: ObjectIdentifier(client.connection))
        client.connection.cancel()
    }

    private func receive(_ client: Connection) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                client.buffer.append(data)
                if self.tryRespond(client) == false {
                    self.close(client)
                    return
                }
            }
            if error != nil || isComplete {
                self.close(client)
                return
            }
            if self.connections[ObjectIdentifier(client.connection)] != nil {
                self.receive(client)
            }
        }
    }

    /// 头部收齐后处理请求。返回 false 表示该连接要关掉。
    private func tryRespond(_ client: Connection) -> Bool {
        guard let headEnd = client.buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return client.buffer.count < 32 * 1024
        }
        let headData = client.buffer[client.buffer.startIndex..<headEnd.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else { return false }

        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return false }
        let parts = first.components(separatedBy: " ")
        guard parts.count >= 2 else { return false }
        let path = parts[1]

        var range: Range<UInt64>?
        for line in lines {
            if line.lowercased().hasPrefix("range:") {
                let value = line.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
                if let eq = value.range(of: "=") {
                    let spec = String(value[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if spec.hasPrefix("-") {
                        // bytes=-N 取末尾 N 字节：播放器一般不这么要，回开头
                        range = nil
                    } else {
                        let pair = spec.components(separatedBy: "-")
                        if let start = UInt64(pair[0].trimmingCharacters(in: .whitespaces)) {
                            let end: UInt64
                            if pair.count > 1, !pair[1].trimmingCharacters(in: .whitespaces).isEmpty,
                               let e = UInt64(pair[1].trimmingCharacters(in: .whitespaces)) {
                                end = e
                            } else {
                                end = UInt64.max
                            }
                            range = start..<(end + 1)
                        }
                    }
                }
                break
            }
        }

        let qIndex = path.firstIndex(of: "?")
        let query = qIndex.map { String(path[path.index(after: $0)...]) } ?? ""
        var filePath = ""
        for item in query.components(separatedBy: "&") {
            if item.hasPrefix("p=") {
                filePath = String(item.dropFirst(2)).removingPercentEncoding ?? ""
                break
            }
        }
        guard !filePath.isEmpty else {
            respond(client, status: "400 Bad Request", body: Data(), extra: [])
            return false
        }

        serve(client, path: filePath, range: range)
        return false // 单个请求处理完就关，保持简单
    }

    private func serve(_ client: Connection, path: String, range: Range<UInt64>?) {
        guard let provider = provider, let shareClient = provider() else {
            respond(client, status: "503 Service Unavailable", body: Data("共享连接已断开".utf8), extra: [])
            return
        }

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let total = try await shareClient.fileSize(path: path)
                var start: UInt64 = 0
                var end: UInt64 = total
                if let range {
                    start = range.lowerBound
                    if range.upperBound != UInt64.max {
                        end = min(range.upperBound, total)
                    }
                }
                if start >= total {
                    self.respond(client, status: "416 Range Not Satisfiable", body: Data(), extra: [])
                    return
                }
                // 单次最多回 maxChunk
                if end - start > UInt64(self.maxChunk) {
                    end = start + UInt64(self.maxChunk)
                }
                let data = try await shareClient.contents(path: path, range: start..<end)

                var extra: [String] = []
                var status = "200 OK"
                if range != nil {
                    status = "206 Partial Content"
                    extra.append("Content-Range: bytes \(start)-\(end - 1)/\(total)")
                }
                extra.append("Accept-Ranges: bytes")
                extra.append("Content-Length: \(data.count)")
                if let mime = Self.mime(for: path) {
                    extra.append("Content-Type: \(mime)")
                }
                self.respond(client, status: status, body: data, extra: extra)
            } catch {
                self.respond(client, status: "500 Internal Server Error",
                             body: Data(error.localizedDescription.utf8), extra: [])
            }
        }
    }

    private func respond(_ client: Connection, status: String, body: Data, extra: [String]) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Connection: close\r\n"
        for line in extra {
            head += line + "\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        client.connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.close(client)
            }
        })
    }

    static func mime(for path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "m4v": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "ts": return "video/mp2t"
        case "mov": return "video/quicktime"
        case "avi": return "video/x-msvideo"
        case "flv": return "video/x-flv"
        case "wmv": return "video/x-ms-wmv"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        case "m3u8": return "application/vnd.apple.mpegurl"
        default: return nil
        }
    }
}
