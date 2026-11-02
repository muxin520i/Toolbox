import Foundation
import Network

// MARK: - 边下边播中转
//
// HLS 下载是「分片先落盘，全部到齐再拼成一个文件」，所以下载到一半的条目
// 没有可以播的完整文件。这里在 127.0.0.1 起一个极小的 HTTP 服务：
//
//   GET /playlist.m3u8  动态生成清单，只列到「已连续下好的分片 + 2 片预取」
//   GET /seg/N          已落盘 → 读本地并解密；没落盘 → 现场回源，带用户配的请求头
//   GET /init           fMP4 的初始化段
//
// 清单里不写 #EXT-X-ENDLIST，播放器会把它当直播流，隔几秒回来取一次；
// 下载器每补完一片，清单就长一片，播放器接着往下播。

final class HLSRelay {

    static let shared = HLSRelay()

    private let queue = DispatchQueue(label: "toolbox.hls.relay")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var job: HLSJob?
    private var itemID: UUID?
    private var sourceURL: URL?
    private var generation = 0
    private var waiting: [(URL?) -> Void] = []

    private init() {}

    // MARK: 对外

    /// 给一个 HLS 下载任务起中转。失败回调 nil（没有清单、端口起不来等）
    func prepare(item: DownloadItem, completion: @escaping (URL?) -> Void) {
        guard let job = DownloadManager.shared.hlsJob(for: item.id), !job.segments.isEmpty else {
            completion(nil)
            return
        }

        self.itemID = item.id
        self.job = job
        self.sourceURL = URL(string: item.source)

        // 换一条任务就换一个端口重开：旧监听先作废，避免播放器拿到上一条的清单
        generation += 1
        listener?.cancel()
        listener = nil
        port = 0
        waiting = [completion]
        startListener(generation: generation)
    }

    func stop() {
        generation += 1
        listener?.cancel()
        listener = nil
        port = 0
        job = nil
        itemID = nil
        waiting.removeAll()
    }

    // MARK: 监听

    private func startListener(generation gen: Int) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: .any)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.generation == gen else { return }
                switch state {
                case .ready:
                    self.port = self.listener?.port?.rawValue ?? 0
                    self.flushWaiting()
                case .failed, .cancelled:
                    self.port = 0
                    self.flushWaiting(failed: true)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            listener.start(queue: queue)
        } catch {
            flushWaiting(failed: true)
        }
    }

    private func flushWaiting(failed: Bool = false) {
        let url: URL? = failed || port == 0
            ? nil
            : URL(string: "http://127.0.0.1:\(port)/playlist.m3u8")
        let callbacks = waiting
        waiting = []
        guard !callbacks.isEmpty else { return }
        DispatchQueue.main.async {
            for callback in callbacks { callback(url) }
        }
    }

    private func accept(_ connection: NWConnection) {
        // 只服务本机播放器，同网段的请求一律不接
        if case let .hostPort(host, _) = connection.endpoint {
            let name = String(describing: host)
            if name != "127.0.0.1" && name != "::1" && name != "localhost" {
                connection.cancel()
                return
            }
        }
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }

            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let range = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: accumulated[..<range.lowerBound], as: UTF8.self)
                self.route(head, connection: connection)
                return
            }
            if isComplete || error != nil || accumulated.count > 64_000 {
                connection.cancel()
                return
            }
            self.read(connection, buffer: accumulated)
        }
    }

    // MARK: 路由

    private func route(_ head: String, connection: NWConnection) {
        guard let firstLine = head.components(separatedBy: "\r\n").first else {
            respond(connection, status: "400 Bad Request", type: "text/plain", body: Data())
            return
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            respond(connection, status: "400 Bad Request", type: "text/plain", body: Data())
            return
        }

        var path = String(parts[1])
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }

        if path == "/playlist.m3u8" || path == "/playlist" {
            servePlaylist(connection)
        } else if path == "/init" {
            serveSegment(index: -1, connection: connection)
        } else if path.hasPrefix("/seg/") {
            let raw = path.dropFirst("/seg/".count)
            guard let index = Int(raw) else {
                respond(connection, status: "404 Not Found", type: "text/plain", body: Data())
                return
            }
            serveSegment(index: index, connection: connection)
        } else if path == "/ping" {
            respond(connection, type: "text/plain", body: Data("ok".utf8))
        } else {
            respond(connection, status: "404 Not Found", type: "text/plain", body: Data())
        }
    }

    // MARK: 清单

    private func servePlaylist(_ connection: NWConnection) {
        guard let job, let id = itemID else {
            respond(connection, status: "404 Not Found", type: "text/plain", body: Data())
            return
        }

        let ready = readyCount(id: id, total: job.segments.count)
        // 至少给一片：第一片还没下完时让播放器去请求，由 /seg 现场回源
        let last = max(1, min(job.segments.count, ready + 2))
        let durations = job.durations ?? []

        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:3")
        lines.append("#EXT-X-TARGETDURATION:\(targetDuration(job))")
        lines.append("#EXT-X-MEDIA-SEQUENCE:0")
        if job.initSegment != nil {
            lines.append("#EXT-X-MAP:URI=\"http://127.0.0.1:\(port)/init\"")
        }

        for index in 0..<last {
            let value = index < durations.count ? durations[index] : 6
            lines.append("#EXTINF:\(String(format: "%.3f", value)),")
            lines.append("http://127.0.0.1:\(port)/seg/\(index)")
        }

        // 不写 #EXT-X-ENDLIST：后面还在下，播放器要回来取新清单
        let body = Data((lines.joined(separator: "\n") + "\n").utf8)
        respond(connection, type: "application/vnd.apple.mpegurl", body: body)
    }

    private func targetDuration(_ job: HLSJob) -> Int {
        let longest = (job.durations ?? []).max() ?? 6
        return max(1, Int(ceil(longest)))
    }

    /// 从 0 开始连续存在的分片数：中间断一片，后面就不往前播，等下载器补上
    private func readyCount(id: UUID, total: Int) -> Int {
        let dir = DownloadManager.partsDirectory(id)
        var count = 0
        while count < total,
              FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("seg-\(count)").path
              ) {
            count += 1
        }
        return count
    }

    // MARK: 分片

    private func serveSegment(index: Int, connection: NWConnection) {
        guard let job, let id = itemID else {
            respond(connection, status: "404 Not Found", type: "text/plain", body: Data())
            return
        }

        let dir = DownloadManager.partsDirectory(id)

        if index < 0 {
            let local = dir.appendingPathComponent("init")
            if let data = try? Data(contentsOf: local), !data.isEmpty {
                respond(connection, type: "video/mp4", body: data)
                return
            }
            guard let segment = job.initSegment?.segment else {
                respond(connection, status: "404 Not Found", type: "text/plain", body: Data())
                return
            }
            fetch(segment, index: -1, connection: connection)
            return
        }

        guard index < job.segments.count else {
            respond(connection, status: "404 Not Found", type: "text/plain", body: Data())
            return
        }

        let local = dir.appendingPathComponent("seg-\(index)")
        if let data = try? Data(contentsOf: local), !data.isEmpty {
            respond(connection, type: "video/mp2t", body: decryptIfNeeded(data, index: index))
            return
        }

        guard let segment = job.segments[index].segment else {
            respond(connection, status: "404 Not Found", type: "text/plain", body: Data())
            return
        }
        fetch(segment, index: index, connection: connection)
    }

    /// 没下到的分片现场回源。不写 parts，避免和下载器的分片任务抢同一个文件
    private func fetch(_ segment: HLSSegment, index: Int, connection: NWConnection) {
        var request = segment.request(referer: refererString(), ua: HLSDownloader.userAgent)
        request.timeoutInterval = 60

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { connection.cancel(); return }
            guard error == nil, let data, !data.isEmpty else {
                self.respond(connection, status: "404 Not Found", type: "text/plain", body: Data())
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                self.respond(connection, status: "502 Bad Gateway", type: "text/plain", body: Data())
                return
            }
            let body = index >= 0 ? self.decryptIfNeeded(data, index: index) : data
            self.respond(connection, type: index < 0 ? "video/mp4" : "video/mp2t", body: body)
        }.resume()
    }

    private func refererString() -> String? {
        guard let url = sourceURL, let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)/"
    }

    private func decryptIfNeeded(_ data: Data, index: Int) -> Data {
        guard let job, job.key != nil else { return data }
        return HLSDownloader.decrypt(data, job: job, index: max(0, index)) ?? data
    }

    // MARK: 响应

    private func respond(_ connection: NWConnection,
                         status: String = "200 OK",
                         type: String,
                         body: Data) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(type)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"

        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
