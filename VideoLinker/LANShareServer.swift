import Foundation
import Network
import UIKit

// MARK: - 局域网投屏
//
// 手机在同一个 Wi-Fi 下开一个只读的 HTTP 服务，电脑浏览器打开 http://手机IP:端口
// 就能看手机里的视频。和 LANInbox 正好相反：那边是电脑 → 手机，这边是手机 → 电脑。
//
// 只做三个路由：
//   GET /                → 视频列表页
//   GET /play/<token>    → 播放页（<video> 标签）
//   GET /file/<token>    → 视频本体，支持 Range，浏览器能拖进度条
//
// 不做鉴权，因为只在局域网、只在 App 前台运行。端口占用时依次往后试。

final class LANShareServer: ObservableObject {
    static let shared = LANShareServer()

    @Published private(set) var running = false
    @Published private(set) var address = ""
    @Published private(set) var errorText = ""
    @Published private(set) var clientCount = 0
    @Published private(set) var fileCount = 0
    /// 本地网络授权状态：iOS 只对 Bonjour / 主动连接局域网地址弹窗，纯监听端口不弹
    @Published private(set) var permission: LocalNetworkPermission.Status = .unknown
    /// 服务起来后 App 自己访问一次，验证「能真的读到页面」，同时触发一次出站授权
    @Published private(set) var selfCheck: SelfCheck = .idle

    /// 端口和收件箱错开，两个服务可以同时开
    private let candidatePorts: [UInt16] = [8088, 8089, 8091, 8092, 8093]

    private let queue = DispatchQueue(label: "com.example.VideoLinker.lanshare")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var entries: [Entry] = []
    private var index: [String: Entry] = [:]

    private init() {}

    // MARK: 数据

    struct Entry {
        let token: String
        let url: URL
        let title: String
        let size: Int64

        var sizeText: String { Fmt.bytes(size) }
        var extText: String {
            let ext = url.pathExtension.uppercased()
            return ext.isEmpty ? "视频" : ext
        }
    }

    enum SelfCheck: Equatable {
        case idle
        case running
        case ok
        case failed

        var text: String {
            switch self {
            case .idle: return "未自检"
            case .running: return "自检中…"
            case .ok: return "自检通过"
            case .failed: return "自检失败"
            }
        }
    }

    /// 播放列表里的本地条目 + 下载记录里还没进列表的文件，按标题排序、按路径去重
    private func collect() -> [Entry] {
        var seen = Set<String>()
        var result: [Entry] = []

        func add(_ url: URL, _ title: String) {
            let path = url.path
            guard !seen.contains(path), FileManager.default.fileExists(atPath: path) else { return }
            let attr = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attr?[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { return }
            seen.insert(path)
            result.append(Entry(token: token(), url: url, title: title, size: size))
        }

        for list in PlaylistStore.load() {
            for item in list.items where item.isLocal && item.localFileExists {
                let path = item.localPath ?? (URL(string: item.url)?.path ?? "")
                guard !path.isEmpty else { continue }
                add(URL(fileURLWithPath: path), item.displayTitle)
            }
        }

        for item in DownloadManager.shared.items {
            let path = item.localPath
            guard !path.isEmpty else { continue }
            add(
                URL(fileURLWithPath: path),
                (item.fileName as NSString).deletingPathExtension
            )
        }

        return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func token() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
    }

    // MARK: 开关

    func start() {
        guard listener == nil else { return }
        errorText = ""

        guard LANInbox.wifiAddress() != nil else {
            errorText = "先连上 Wi-Fi，要和电脑在同一个网络里"
            running = false
            return
        }

        let list = collect()
        guard !list.isEmpty else {
            errorText = "还没有本地视频，先下载或导入几个再开"
            running = false
            return
        }

        fileCount = list.count

        // 只监听端口系统不会弹授权窗，必须额外用 Bonjour 浏览问一次，
        // 否则电脑那边永远是「已拒绝连接」，设置里也找不到开关
        if permission != .granted {
            probePermission()
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.entries = list
            self.index = Dictionary(list.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
            self.listen(at: 0)
        }
    }

    /// 触发 / 重新检测本地网络授权。第一次调用会弹系统弹窗。
    func probePermission() {
        permission = .checking
        LocalNetworkPermission.probe { [weak self] status in
            guard let self else { return }
            self.permission = status
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values {
                connection.closed = true
                connection.connection.cancel()
                connection.closeFile()
            }
            self.connections.removeAll()

            DispatchQueue.main.async {
                self.running = false
                self.address = ""
                self.clientCount = 0
                self.fileCount = 0
                self.errorText = ""
                self.selfCheck = .idle
            }
        }
    }

    func toggle() {
        running ? stop() : start()
    }

    func refresh() {
        guard running else { return }
        let list = collect()
        fileCount = list.count
        queue.async { [weak self] in
            guard let self else { return }
            self.entries = list
            self.index = Dictionary(list.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    // MARK: 监听

    private func listen(at position: Int) {
        guard position < candidatePorts.count else {
            DispatchQueue.main.async {
                self.running = false
                self.errorText = "端口都被占用了，把「局域网收件箱」关掉再试一次"
            }
            return
        }

        let port = candidatePorts[position]
        guard let endpoint = NWEndpoint.Port(rawValue: port) else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: params, on: endpoint)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let ip = LANInbox.wifiAddress() ?? "127.0.0.1"
                    DispatchQueue.main.async {
                        self.address = "http://\(ip):\(port)"
                        self.running = true
                        self.errorText = ""
                        self.selfCheck = .running
                    }
                    self.runSelfCheck(ip: ip, port: port)
                case .failed(let error):
                    listener.cancel()
                    self.listener = nil
                    // 权限被拦时不是端口问题，别再往后换端口了
                    if LocalNetworkPermission.isPolicyDenied(error) {
                        DispatchQueue.main.async {
                            self.running = false
                            self.permission = .denied
                        }
                        return
                    }
                    self.listen(at: position + 1)
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            listen(at: position + 1)
        }
    }

    /// 服务起来后，App 自己去请求一次自己的局域网地址：
    /// 一来验证端口真的通（不只是 listener ready），
    /// 二来这是一次出站局域网访问，能把授权弹窗顶出来
    private func runSelfCheck(ip: String, port: UInt16) {
        guard let url = URL(string: "http://\(ip):\(port)/ping") else {
            DispatchQueue.main.async { self.selfCheck = .failed }
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                self.selfCheck = code == 200 ? .ok : .failed
            }
        }.resume()
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
        let count = connections.count
        DispatchQueue.main.async {
            self.clientCount = count
        }
        receive(client)
    }

    private func receive(_ client: Connection) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.consume(client, data)
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

    private func consume(_ client: Connection, _ data: Data) {
        client.buffer.append(data)
        guard let end = client.buffer.range(of: Data("\r\n\r\n".utf8)) else {
            // 请求头都超过 16KB 了，不伺候
            if client.buffer.count > 16 * 1024 { close(client) }
            return
        }

        let headData = client.buffer.subdata(in: 0..<end.lowerBound)
        client.buffer.removeAll(keepingCapacity: false)
        let head = String(data: headData, encoding: .utf8) ?? ""
        handle(head, client: client)
    }

    // MARK: 路由

    private func handle(_ head: String, client: Connection) {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            respond(client, status: "400 Bad Request", body: Data("bad request".utf8), type: "text/plain")
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            respond(client, status: "400 Bad Request", body: Data("bad request".utf8), type: "text/plain")
            return
        }

        let method = String(parts[0]).uppercased()
        var target = String(parts[1])
        if let question = target.firstIndex(of: "?") {
            target = String(target[target.startIndex..<question])
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        guard method == "GET" || method == "HEAD" else {
            respond(client, status: "405 Method Not Allowed", body: Data("only GET".utf8), type: "text/plain")
            return
        }

        if target == "/ping" {
            respond(client, status: "200 OK", body: Data("ok".utf8), type: "text/plain; charset=utf-8")
            return
        }

        if target == "/" || target.isEmpty {
            respond(client, status: "200 OK", body: Data(indexHTML().utf8), type: "text/html; charset=utf-8")
            return
        }

        if target == "/favicon.ico" {
            respond(client, status: "204 No Content", body: Data(), type: "image/x-icon")
            return
        }

        if target.hasPrefix("/play/") {
            let token = String(target.dropFirst("/play/".count))
            guard index[token] != nil else {
                respond(client, status: "404 Not Found", body: Data("not found".utf8), type: "text/plain; charset=utf-8")
                return
            }
            respond(client, status: "200 OK", body: Data(playerHTML(token).utf8), type: "text/html; charset=utf-8")
            return
        }

        if target.hasPrefix("/file/") {
            let token = String(target.dropFirst("/file/".count))
            sendFile(token, client: client, head: method == "HEAD", headers: headers)
            return
        }

        respond(client, status: "404 Not Found", body: Data("not found".utf8), type: "text/plain; charset=utf-8")
    }

    // MARK: 视频流

    private func sendFile(_ token: String, client: Connection, head: Bool, headers: [String: String]) {
        guard let entry = index[token] else {
            respond(client, status: "404 Not Found", body: Data("not found".utf8), type: "text/plain")
            return
        }

        let size = entry.size
        var start: Int64 = 0
        var end: Int64 = size - 1
        var partial = false

        if let raw = headers["range"], let range = parseRange(raw, size: size) {
            start = range.start
            end = range.end
            partial = true
        }

        let length = end - start + 1
        var response = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        if partial {
            response += "Content-Range: bytes \(start)-\(end)/\(size)\r\n"
        }
        response += "Content-Type: \(mimeType(entry.url))\r\n"
        response += "Content-Length: \(length)\r\n"
        response += "Accept-Ranges: bytes\r\n"
        response += "Cache-Control: no-store\r\n"
        response += "Access-Control-Allow-Origin: *\r\n"
        response += "Connection: close\r\n\r\n"

        client.connection.send(
            content: Data(response.utf8),
            isComplete: false,
            completion: .contentProcessed { error in
                if error != nil { client.closed = true }
            }
        )

        guard !head else {
            finish(client)
            return
        }

        guard let handle = try? FileHandle(forReadingFrom: entry.url) else {
            close(client)
            return
        }
        do {
            try handle.seek(toOffset: UInt64(start))
        } catch {
            try? handle.close()
            close(client)
            return
        }

        client.fileHandle = handle
        client.total = length
        client.sent = 0
        pump(client)
    }

    private func pump(_ client: Connection) {
        guard !client.closed, let handle = client.fileHandle else {
            finish(client)
            return
        }
        guard client.sent < client.total else {
            finish(client)
            return
        }

        let remaining = client.total - client.sent
        let chunk = Int(min(Int64(256 * 1024), remaining))
        guard let data = try? handle.read(upToCount: chunk), !data.isEmpty else {
            finish(client)
            return
        }

        client.sent += Int64(data.count)
        client.connection.send(
            content: data,
            isComplete: false,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil {
                    self.close(client)
                    return
                }
                // 放到队尾再读下一块，避免同步回调把栈压深
                self.queue.async { self.pump(client) }
            }
        )
    }

    private func finish(_ client: Connection) {
        client.closeFile()
        if client.closed {
            close(client)
            return
        }
        client.closed = true
        client.connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
            client.connection.cancel()
        })
    }

    private func parseRange(_ value: String, size: Int64) -> (start: Int64, end: Int64)? {
        guard size > 0, value.hasPrefix("bytes=") else { return nil }
        let spec = String(value.dropFirst(6))
            .split(separator: ",")
            .first
            .map(String.init) ?? ""
        let pieces = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }

        let startText = pieces[0].trimmingCharacters(in: .whitespaces)
        let endText = pieces[1].trimmingCharacters(in: .whitespaces)

        if startText.isEmpty {
            // bytes=-500 → 最后 500 字节
            guard let length = Int64(endText), length > 0 else { return nil }
            let from = max(0, size - length)
            return (from, size - 1)
        }

        guard let start = Int64(startText), start >= 0, start < size else { return nil }
        if endText.isEmpty { return (start, size - 1) }
        guard let end = Int64(endText), end >= start else { return nil }
        return (start, min(end, size - 1))
    }

    private func mimeType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "ts", "m2ts", "mts": return "video/mp2t"
        case "flv": return "video/x-flv"
        case "avi": return "video/x-msvideo"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        default: return "application/octet-stream"
        }
    }

    // MARK: 响应

    private func respond(_ client: Connection, status: String, body: Data, type: String) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(body)

        client.closed = true
        client.connection.send(content: payload, isComplete: true, completion: .contentProcessed { _ in
            client.connection.cancel()
        })
    }

    private func close(_ client: Connection) {
        guard !client.closed || connections[ObjectIdentifier(client.connection)] != nil else { return }
        client.closed = true
        client.closeFile()
        connections.removeValue(forKey: ObjectIdentifier(client.connection))
        client.connection.cancel()
        let count = connections.count
        DispatchQueue.main.async {
            self.clientCount = count
        }
    }

    // MARK: 页面

    private func escape(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&#39;")
        return result
    }

    private var style: String {
        """
        :root { color-scheme: dark; }
        * { box-sizing: border-box; }
        body {
          margin: 0; padding: 0 20px 60px;
          background: #0b0d12;
          color: #e8eaf0;
          font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Microsoft YaHei", sans-serif;
        }
        header { padding: 44px 4px 22px; }
        h1 { margin: 0 0 6px; font-size: 26px; letter-spacing: -0.5px; }
        header p { margin: 0; font-size: 13px; color: #7b8296; }
        .card {
          display: flex; align-items: center; gap: 16px;
          padding: 14px 18px; margin-bottom: 10px;
          background: #151922; border: 1px solid #222838;
          border-radius: 16px; text-decoration: none; color: inherit;
          transition: border-color .15s ease, transform .15s ease;
        }
        .card:hover { border-color: #3b6cff; transform: translateY(-1px); }
        .thumb {
          width: 54px; height: 54px; flex: none; border-radius: 12px;
          background: linear-gradient(135deg, #2b3d7a, #1b2340);
          display: flex; align-items: center; justify-content: center;
          font-size: 18px; color: #7fa0ff;
        }
        .meta { flex: 1; min-width: 0; }
        .title {
          display: block; font-size: 15px; font-weight: 600; margin-bottom: 4px;
          white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
        }
        .sub { font-size: 12px; color: #7b8296; }
        .go { font-size: 12px; color: #7fa0ff; flex: none; }
        .empty { padding: 60px 0; text-align: center; color: #7b8296; font-size: 14px; }
        .player { max-width: 1080px; margin: 0 auto; }
        .player video { width: 100%; border-radius: 14px; background: #000; display: block; }
        .back { display: inline-block; margin-bottom: 16px; color: #7fa0ff; text-decoration: none; font-size: 13px; }
        .hint { margin-top: 14px; font-size: 12.5px; color: #7b8296; line-height: 1.7; }
        """
    }

    private func indexHTML() -> String {
        let cards = entries.map { entry in
            """
            <a class="card" href="/play/\(entry.token)">
              <div class="thumb">▶</div>
              <div class="meta">
                <span class="title">\(escape(entry.title))</span>
                <span class="sub">\(entry.extText) · \(entry.sizeText)</span>
              </div>
              <span class="go">播放 →</span>
            </a>
            """
        }.joined(separator: "\n")

        let body = entries.isEmpty
            ? "<div class=\"empty\">还没有可播放的视频</div>"
            : cards

        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>VideoLinker · 局域网播放</title>
        <style>\(style)</style>
        </head>
        <body>
        <header>
          <h1>VideoLinker</h1>
          <p>共 \(entries.count) 个视频 · 手机请保持 App 在前台</p>
        </header>
        <main>\(body)</main>
        </body>
        </html>
        """
    }

    private func playerHTML(_ token: String) -> String {
        let title = index[token]?.title ?? "播放"
        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title)) · VideoLinker</title>
        <style>\(style)</style>
        </head>
        <body>
        <div class="player">
          <header><a class="back" href="/">← 返回列表</a><h1>\(escape(title))</h1></header>
          <video src="/file/\(token)" controls autoplay playsinline></video>
          <p class="hint">
            进度条可以直接拖，走的是 HTTP Range 请求。<br>
            Safari 对 MP4 / MOV 支持最好；MKV、FLV 这类容器浏览器可能只给下载。
          </p>
        </div>
        </body>
        </html>
        """
    }

    // MARK: 连接

    private final class Connection {
        let connection: NWConnection
        var buffer = Data()
        var closed = false
        var fileHandle: FileHandle?
        var total: Int64 = 0
        var sent: Int64 = 0

        init(connection: NWConnection) {
            self.connection = connection
        }

        func closeFile() {
            try? fileHandle?.close()
            fileHandle = nil
        }
    }
}
