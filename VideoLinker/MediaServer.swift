import Foundation
import Network

// MARK: - 媒体服务器（手机当片源）
//
// 和 DLNA.swift 里的 DLNAReceiver 正好相反：
//   DLNAReceiver  手机当「电视」，别人投过来，手机播
//   MediaLibraryServer  手机当「NAS」，电视来拉，手机只负责供片
//
// 协议部分只走公开的 UPnP AV：
//   SSDP 应答 MediaServer:1 → 设备描述 → ContentDirectory Browse → HTTP 拉流
// 电视 / 播放器在自己的「媒体服务器 / 网络播放器」列表里选中「工具箱影库」就能浏览。

// MARK: - 媒体库条目

/// 媒体服务器对外暴露的一条视频。只读、可编码成 DIDL。
struct MediaServerItem {
    let path: String
    let title: String
    let size: Int64
    let modified: Date
}

// MARK: - 服务

final class MediaLibraryServer: ObservableObject {

    static let shared = MediaLibraryServer()

    @Published private(set) var running = false
    @Published private(set) var address = ""
    @Published private(set) var errorText = ""
    /// 当前共享出去的视频数量，界面直接显示
    @Published private(set) var sharedCount = 0

    private let queue = DispatchQueue(label: "toolbox.dlna.server")
    private let ports: [UInt16] = [8100, 8101, 8102]
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var stopped = true
    private var activePort: UInt16 = 0
    private var ssdpFD: Int32 = -1

    /// 媒体库缓存：扫描一次能用一分钟，避免电视每翻一页都全盘扫
    private var library: [MediaServerItem] = []
    private var libraryAt = Date.distantPast

    private init() {}

    // MARK: 启停

    func start() {
        guard listener == nil else { return }
        stopped = false
        errorText = ""
        queue.async { [weak self] in
            self?.listen(at: 0)
        }
    }

    func stop() {
        stopped = true
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.activePort = 0
            self.clients.values.forEach { $0.connection.cancel() }
            self.clients.removeAll()
            if self.ssdpFD >= 0 {
                close(self.ssdpFD)
                self.ssdpFD = -1
            }
            self.library = []
            self.libraryAt = .distantPast
            DispatchQueue.main.async {
                self.running = false
                self.address = ""
                self.sharedCount = 0
            }
        }
    }

    func toggle() {
        if running { stop() } else { start() }
    }

    /// 重新扫一遍媒体库（正在运行时立刻生效）
    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            self.libraryAt = .distantPast
            self.refreshLibrary()
        }
    }

    private func listen(at index: Int) {
        guard !stopped else { return }
        guard index < ports.count else {
            DispatchQueue.main.async {
                self.running = false
                self.errorText = "端口 8100–8102 都被占用了"
            }
            return
        }

        let port = ports[index]
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
                    self.activePort = port
                    let ip = LANInbox.wifiAddress() ?? "127.0.0.1"
                    self.refreshLibrary()
                    DispatchQueue.main.async {
                        self.address = "http://\(ip):\(port)/ms/device.xml"
                        self.running = true
                        self.errorText = ""
                    }
                    self.startSSDP()
                case .failed:
                    listener.cancel()
                    self.listener = nil
                    self.listen(at: index + 1)
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            listen(at: index + 1)
        }
    }

    private var baseURL: String {
        "http://\(LANInbox.wifiAddress() ?? "127.0.0.1"):\(activePort)"
    }

    private var udn: String {
        let key = "dlna.server.udn"
        if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty { return value }
        let value = "uuid:" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    // MARK: 媒体库

    /// 同步扫描（在 queue 上跑，Browse 请求直接读，不做异步等待）
    private func refreshLibrary() {
        let now = Date()
        if !library.isEmpty, now.timeIntervalSince(libraryAt) < 60 { return }

        let manager = FileManager.default
        let root = LocalMedia.root()
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey
        ]
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            library = []
            libraryAt = now
            return
        }

        var found: [MediaServerItem] = []
        for case let url as URL in enumerator {
            if found.count >= 1000 { break }
            guard LocalMedia.extensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }

            let name = url.lastPathComponent
            let title = (name as NSString).deletingPathExtension
            found.append(MediaServerItem(
                path: url.path,
                title: title.isEmpty ? name : title,
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast
            ))
        }

        found.sort { $0.modified > $1.modified }
        library = found
        libraryAt = now
        let count = found.count
        DispatchQueue.main.async {
            self.sharedCount = count
        }
    }

    /// 相对 App 文档目录的路径，根目录用 "/"
    private func relativePath(_ absolute: String) -> String {
        let root = LocalMedia.root().path
        guard absolute.hasPrefix(root) else { return "/" }
        let tail = String(absolute.dropFirst(root.count))
        return tail.isEmpty ? "/" : tail
    }

    private func dirID(_ absoluteDir: String) -> String {
        let rel = relativePath(absoluteDir)
        return rel == "/" ? "0" : "dir:" + rel
    }

    /// 某目录直接下级：子目录容器 + 视频条目
    private func children(of absoluteDir: String) -> [(id: String, parent: String, title: String, isDir: Bool, item: MediaServerItem?)] {
        let manager = FileManager.default
        let dirURL = URL(fileURLWithPath: absoluteDir)
        guard let names = try? manager.contentsOfDirectory(atPath: absoluteDir) else { return [] }

        let parentID = dirID(absoluteDir)
        var result: [(String, String, String, Bool, MediaServerItem?)] = []

        for name in names {
            if name.hasPrefix(".") { continue }
            let full = dirURL.appendingPathComponent(name).path
            var isDir: ObjCBool = false
            guard manager.fileExists(atPath: full, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                result.append((dirID(full), parentID, name, true, nil))
            } else {
                guard LocalMedia.extensions.contains((name as NSString).pathExtension.lowercased()),
                      let attrs = try? manager.attributesOfItem(atPath: full) else { continue }
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let title = (name as NSString).deletingPathExtension
                let item = MediaServerItem(path: full, title: title.isEmpty ? name : title,
                                           size: size, modified: attrs[.modificationDate] as? Date ?? .distantPast)
                result.append(("file:" + full, parentID, item.title, false, item))
            }
        }

        return result.sorted {
            if $0.3 != $1.3 { return $0.3 }
            return $0.2.localizedStandardCompare($1.2) == .orderedAscending
        }
    }

    /// 根目录：全部视频 + 一级文件夹
    private func rootChildren() -> [(id: String, parent: String, title: String, isDir: Bool, item: MediaServerItem?)] {
        var result: [(String, String, String, Bool, MediaServerItem?)] = [
            ("all", "0", "全部视频（\(library.count)）", true, nil)
        ]
        let manager = FileManager.default
        let root = LocalMedia.root().path
        guard let names = try? manager.contentsOfDirectory(atPath: root) else { return result }
        let rootURL = URL(fileURLWithPath: root)
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            if name.hasPrefix(".") { continue }
            var isDir: ObjCBool = false
            let full = rootURL.appendingPathComponent(name).path
            guard manager.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
            result.append((dirID(full), "0", name, true, nil))
        }
        return result
    }

    // MARK: HTTP 接入

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        clients[ObjectIdentifier(connection)] = client

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.drop(client)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(client)
    }

    private func drop(_ client: Client) {
        client.closeFile()
        clients.removeValue(forKey: ObjectIdentifier(client.connection))
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                client.buffer.append(data)
            }
            if self.tryProcess(client) { return }
            if error != nil || isComplete {
                self.drop(client)
                return
            }
            self.receive(client)
        }
    }

    /// 返回 true 表示请求已经接走（响应由后续流程发）
    private func tryProcess(_ client: Client) -> Bool {
        guard let end = client.buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if client.buffer.count > 256 * 1024 {
                client.connection.cancel()
                return true
            }
            return false
        }

        let head = String(data: client.buffer.subdata(in: 0..<end.lowerBound), encoding: .utf8) ?? ""
        let headers = Self.parseHeaders(head)
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound

        guard client.buffer.count >= bodyStart + length else { return false }

        let body = String(data: client.buffer.subdata(in: bodyStart..<(bodyStart + length)), encoding: .utf8) ?? ""
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")

        guard parts.count >= 2 else {
            respond(client, status: "400 Bad Request", body: Data())
            return true
        }

        route(
            method: String(parts[0]).uppercased(),
            rawPath: String(parts[1]),
            headers: headers,
            body: body,
            client: client
        )
        return true
    }

    private func route(method: String, rawPath: String, headers: [String: String], body: String, client: Client) {
        let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath

        if method == "GET" || method == "HEAD" {
            switch path {
            case "/ms/device.xml":
                respond(client, body: Data(deviceXML.utf8),
                        type: "text/xml; charset=\"utf-8\"")
                return
            case "/ms/cd.xml":
                respond(client, body: Data(Self.contentDirectorySCPD.utf8),
                        type: "text/xml; charset=\"utf-8\"")
                return
            case "/ms/cm.xml":
                respond(client, body: Data(Self.connectionManagerSCPD.utf8),
                        type: "text/xml; charset=\"utf-8\"")
                return
            case "/ms/media":
                serveMedia(rawPath: rawPath, headers: headers, head: method == "HEAD", client: client)
                return
            default:
                break
            }
        }

        if method == "POST", path.hasPrefix("/ms/control/") {
            let service = String(path.dropFirst("/ms/control/".count))
            handleSOAP(service: service, headers: headers, body: body, client: client)
            return
        }

        if method == "SUBSCRIBE" || method == "UNSUBSCRIBE" {
            respond(client, body: Data(), extra: [
                "SID: uuid:\(UUID().uuidString.lowercased())",
                "TIMEOUT: Second-1800"
            ])
            return
        }

        respond(client, status: "404 Not Found", body: Data())
    }

    // MARK: SOAP

    private func handleSOAP(service: String, headers: [String: String], body: String, client: Client) {
        var action = ""
        if let raw = headers["soapaction"] {
            action = raw.replacingOccurrences(of: "\"", with: "")
                .split(separator: "#").last.map(String.init) ?? ""
            action = action.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if action.isEmpty, let range = body.range(of: "<u:", options: .backwards),
           let close = body[range.upperBound...].firstIndex(of: " ") {
            action = String(body[range.upperBound..<close])
        }

        if service == "ContentDirectory" {
            handleContentDirectory(action: action, body: body, client: client)
        } else {
            handleConnectionManager(action: action, client: client)
        }
    }

    private func handleContentDirectory(action: String, body: String, client: Client) {
        guard action == "Browse" else {
            // 电视可能顺带问这几个，按各自约定的字段回
            let inner: String
            switch action {
            case "GetSearchCapabilities":
                inner = "<SearchCaps></SearchCaps>"
            case "GetSortCapabilities":
                inner = "<SortCaps>dc:title</SortCaps>"
            case "GetSystemUpdateID":
                inner = "<Id>1</Id>"
            default:
                inner = ""
            }
            respond(client, body: Data(envelope(service: "ContentDirectory", action: action, inner: inner).utf8))
            return
        }

        let objectID = Self.unescape(Self.tag("ObjectID", in: body) ?? "0")
        let flag = Self.unescape(Self.tag("BrowseFlag", in: body) ?? "BrowseDirectChildren")
        let start = Int(Self.tag("StartingIndex", in: body) ?? "0") ?? 0
        let requested = Int(Self.tag("RequestedCount", in: body) ?? "0") ?? 0

        refreshLibrary()

        if flag == "BrowseMetadata" {
            let didl = metadataDIDL(for: objectID)
            let inner = "<Result>\(Self.escape(didl))</Result>"
                + "<NumberReturned>1</NumberReturned>"
                + "<TotalMatches>1</TotalMatches>"
                + "<UpdateID>1</UpdateID>"
            respond(client, body: Data(envelope(service: "ContentDirectory", action: "Browse", inner: inner).utf8))
            return
        }

        let all: [(id: String, parent: String, title: String, isDir: Bool, item: MediaServerItem?)]
        if objectID == "0" {
            all = rootChildren()
        } else if objectID == "all" {
            all = library.map { ("all:" + $0.path, "all", $0.title, false, $0) }
        } else if objectID.hasPrefix("dir:") {
            let rel = String(objectID.dropFirst(4))
            let root = LocalMedia.root().path
            let absolute = root + (rel.hasPrefix("/") ? rel : "/" + rel)
            all = children(of: absolute)
        } else {
            all = []
        }

        let total = all.count
        let slice: ArraySlice<(id: String, parent: String, title: String, isDir: Bool, item: MediaServerItem?)>
        if start >= total {
            slice = []
        } else if requested > 0 {
            slice = all[start..<min(total, start + requested)]
        } else {
            slice = all[start...]
        }

        var didl = didlHeader()
        for entry in slice {
            didl += didlEntry(id: entry.id, parent: entry.parent, title: entry.title,
                              isDir: entry.isDir, item: entry.item)
        }
        didl += "</DIDL-Lite>"

        let inner = "<Result>\(Self.escape(didl))</Result>"
            + "<NumberReturned>\(slice.count)</NumberReturned>"
            + "<TotalMatches>\(total)</TotalMatches>"
            + "<UpdateID>1</UpdateID>"
        respond(client, body: Data(envelope(service: "ContentDirectory", action: "Browse", inner: inner).utf8))
    }

    private func handleConnectionManager(action: String, client: Client) {
        let inner: String
        switch action {
        case "GetProtocolInfo":
            inner = "<Source>http-get:*:video/mp4:*,http-get:*:video/x-matroska:*,"
                + "http-get:*:video/mp2t:*,http-get:*:video/quicktime:*,"
                + "http-get:*:audio/mpeg:*,http-get:*:video/webm:*</Source><Sink></Sink>"
        case "GetCurrentConnectionIDs":
            inner = "<ConnectionIDs>0</ConnectionIDs>"
        case "GetCurrentConnectionInfo":
            inner = "<RcsID>0</RcsID><AVTransportID>0</AVTransportID>"
                + "<ProtocolInfo></ProtocolInfo><PeerConnectionManager></PeerConnectionManager>"
                + "<PeerConnectionID>-1</PeerConnectionID><Direction>Output</Direction><Status>OK</Status>"
        default:
            inner = ""
        }
        respond(client, body: Data(envelope(service: "ConnectionManager", action: action, inner: inner).utf8))
    }

    // MARK: DIDL

    private func didlHeader() -> String {
        "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\""
            + " xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
            + " xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\""
            + " xmlns:dlna=\"urn:schemas-dlna-org:metadata-1-0/\">"
    }

    private func metadataDIDL(for objectID: String) -> String {
        var didl = didlHeader()
        if objectID == "0" {
            didl += "<container id=\"0\" parentID=\"-1\" restricted=\"1\" searchable=\"1\">"
                + "<dc:title>工具箱影库</dc:title>"
                + "<upnp:class>object.container.storageFolder</upnp:class>"
                + "</container>"
        } else if objectID == "all" {
            didl += "<container id=\"all\" parentID=\"0\" restricted=\"1\" searchable=\"0\">"
                + "<dc:title>全部视频</dc:title>"
                + "<upnp:class>object.container.storageFolder</upnp:class>"
                + "</container>"
        } else if objectID.hasPrefix("dir:") {
            let rel = String(objectID.dropFirst(4))
            let title = (rel as NSString).lastPathComponent
            didl += "<container id=\"\(Self.escape(objectID))\" parentID=\"0\" restricted=\"1\" searchable=\"0\">"
                + "<dc:title>\(Self.escape(title))</dc:title>"
                + "<upnp:class>object.container.storageFolder</upnp:class>"
                + "</container>"
        } else if let item = library.first(where: { "all:" + $0.path == objectID || "file:" + $0.path == objectID }) {
            didl += didlItem(id: objectID, parent: "all", item: item)
        }
        didl += "</DIDL-Lite>"
        return didl
    }

    private func didlEntry(id: String, parent: String, title: String, isDir: Bool, item: MediaServerItem?) -> String {
        if isDir {
            return "<container id=\"\(Self.escape(id))\" parentID=\"\(Self.escape(parent))\" restricted=\"1\" searchable=\"0\">"
                + "<dc:title>\(Self.escape(title))</dc:title>"
                + "<upnp:class>object.container.storageFolder</upnp:class>"
                + "</container>"
        }
        guard let item else { return "" }
        return didlItem(id: id, parent: parent, item: item)
    }

    private func didlItem(id: String, parent: String, item: MediaServerItem) -> String {
        let encoded = item.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let url = "\(baseURL)/ms/media?p=\(encoded)"
        let mime = Self.mime(for: item.path)
        return "<item id=\"\(Self.escape(id))\" parentID=\"\(Self.escape(parent))\" restricted=\"1\">"
            + "<dc:title>\(Self.escape(item.title))</dc:title>"
            + "<upnp:class>object.item.videoItem</upnp:class>"
            + "<res protocolInfo=\"http-get:*:\(mime):*\" size=\"\(item.size)\">\(Self.escape(url))</res>"
            + "</item>"
    }

    // MARK: 媒体文件

    private func serveMedia(rawPath: String, headers: [String: String], head: Bool, client: Client) {
        let query = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst().first.map(String.init) ?? ""
        var filePath = ""
        for pair in query.components(separatedBy: "&") where pair.hasPrefix("p=") {
            filePath = String(pair.dropFirst(2)).removingPercentEncoding ?? ""
            break
        }

        let root = LocalMedia.root().standardizedFileURL.path
        let target = URL(fileURLWithPath: filePath).standardizedFileURL.path
        guard !filePath.isEmpty, target.hasPrefix(root + "/") else {
            respond(client, status: "403 Forbidden", body: Data("out of library".utf8))
            return
        }

        let manager = FileManager.default
        guard manager.fileExists(atPath: target),
              let attrs = try? manager.attributesOfItem(atPath: target),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0 else {
            respond(client, status: "404 Not Found", body: Data())
            return
        }

        var start: Int64 = 0
        var end = size - 1
        var partial = false
        if let raw = headers["range"], let parsed = Self.parseRange(raw, size: size) {
            start = parsed.start
            end = parsed.end
            partial = true
        }
        let length = end - start + 1

        var response = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        if partial {
            response += "Content-Range: bytes \(start)-\(end)/\(size)\r\n"
        }
        response += "Content-Type: \(Self.mime(for: target))\r\n"
        response += "Content-Length: \(length)\r\n"
        response += "Accept-Ranges: bytes\r\n"
        response += "transferMode.dlna.org: Streaming\r\n"
        response += "Connection: close\r\n\r\n"

        client.connection.send(content: Data(response.utf8), isComplete: false,
                               completion: .contentProcessed { _ in })
        guard !head else {
            finish(client)
            return
        }

        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: target)) else {
            drop(client)
            return
        }
        do {
            try handle.seek(toOffset: UInt64(start))
        } catch {
            try? handle.close()
            drop(client)
            return
        }

        client.fileHandle = handle
        client.total = length
        client.sent = 0
        pump(client)
    }

    private func pump(_ client: Client) {
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
        client.connection.send(content: data, isComplete: false,
                               completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.drop(client)
                return
            }
            self.queue.async { self.pump(client) }
        })
    }

    private func finish(_ client: Client) {
        client.closeFile()
        if client.closed {
            drop(client)
            return
        }
        client.closed = true
        client.connection.send(content: nil, isComplete: true,
                               completion: .contentProcessed { _ in
            client.connection.cancel()
        })
    }

    // MARK: 响应

    private func respond(_ client: Client,
                         status: String = "200 OK",
                         body: Data,
                         type: String = "text/xml; charset=\"utf-8\"",
                         extra: [String] = []) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "Server: Darwin/UPnP/1.0 VideoLinker/1.0\r\n"
        for line in extra {
            head += line + "\r\n"
        }
        head += "\r\n"

        var payload = Data(head.utf8)
        payload.append(body)
        client.connection.send(content: payload, completion: .contentProcessed { _ in
            client.connection.cancel()
        })
    }

    private func envelope(service: String, action: String, inner: String = "") -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\""
            + " s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body>"
            + "<u:\(action)Response xmlns:u=\"urn:schemas-upnp-org:service:\(service):1\">"
            + inner
            + "</u:\(action)Response>"
            + "</s:Body></s:Envelope>"
    }

    // MARK: SSDP

    private func startSSDP() {
        guard ssdpFD < 0 else { return }

        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = in_port_t(1900).bigEndian
        local.sin_addr.s_addr = INADDR_ANY

        let bound = withUnsafePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(sock)
            DispatchQueue.main.async {
                self.errorText = "1900 端口被占用，电视可能搜不到手机"
            }
            return
        }

        var group = ip_mreq()
        group.imr_multiaddr.s_addr = inet_addr("239.255.255.250")
        group.imr_interface.s_addr = INADDR_ANY
        let joined = setsockopt(sock, IPPROTO_IP, IP_ADD_MEMBERSHIP, &group,
                                socklen_t(MemoryLayout<ip_mreq>.size))
        if joined != 0 {
            DispatchQueue.main.async {
                self.errorText = "系统没放行组播，电视可能搜不到；可在电视上手动输入地址"
            }
        }

        ssdpFD = sock

        let thread = Thread { [weak self] in
            self?.ssdpLoop(sock)
        }
        thread.name = "dlna.server.ssdp"
        thread.stackSize = 512 * 1024
        thread.start()

        announce()
    }

    private func ssdpLoop(_ sock: Int32) {
        var buffer = [UInt8](repeating: 0, count: 2048)

        while !stopped {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)

            let count = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    buffer.withUnsafeMutableBytes { raw in
                        recvfrom(sock, raw.baseAddress, raw.count, 0, sa, &length)
                    }
                }
            }

            guard count > 0 else { continue }
            guard let text = String(bytes: buffer[0..<count], encoding: .utf8) else { continue }
            guard text.hasPrefix("M-SEARCH") else { continue }

            let st = Self.header("ST", in: text) ?? "ssdp:all"
            guard matchesST(st) else { continue }
            reply(to: from, requestST: st, sock: sock)
        }
    }

    func matchesST(_ st: String) -> Bool {
        let lower = st.lowercased()
        if lower == "ssdp:all" || lower == "upnp:rootdevice" { return true }
        if lower == udn.lowercased() { return true }
        if lower.contains("devicetype:mediaserver") { return true }
        return false
    }

    /// 给 DLNAReceiver 的 SSDP 循环用：两个服务都想绑 1900，
    /// 内核只会把每个包分给其中一个 socket。收到不归自己的搜索时转发过来，
    /// 用同一个 socket 回，保证电视一定能看到媒体服务器。
    func handleForwardedSearch(_ text: String, from: sockaddr_in, sock: Int32) -> Bool {
        guard text.hasPrefix("M-SEARCH") else { return false }
        let st = Self.header("ST", in: text) ?? "ssdp:all"
        guard matchesST(st) else { return false }
        reply(to: from, requestST: st, sock: sock)
        return true
    }

    private func reply(to destination: sockaddr_in, requestST: String, sock: Int32) {
        let uuid = udn
        let loc = baseURL + "/ms/device.xml"

        var targets: [(String, String)] = []
        if requestST == "ssdp:all" {
            targets = [
                ("upnp:rootdevice", uuid + "::upnp:rootdevice"),
                (uuid, uuid),
                ("urn:schemas-upnp-org:device:MediaServer:1",
                 uuid + "::urn:schemas-upnp-org:device:MediaServer:1")
            ]
        } else {
            targets = [(requestST, requestST == uuid ? uuid : uuid + "::" + requestST)]
        }

        for (st, usn) in targets {
            let message = "HTTP/1.1 200 OK\r\n"
                + "CACHE-CONTROL: max-age=1800\r\n"
                + "DATE: \(Self.httpDate())\r\n"
                + "EXT:\r\n"
                + "LOCATION: \(loc)\r\n"
                + "SERVER: Darwin/UPnP/1.0 VideoLinker/1.0\r\n"
                + "ST: \(st)\r\n"
                + "USN: \(usn)\r\n"
                + "BOOTID.UPNP.ORG: 1\r\n"
                + "CONFIGID.UPNP.ORG: 1\r\n\r\n"
            Self.send(message, to: destination, sock: sock)
        }
    }

    private func announce() {
        guard ssdpFD >= 0 else { return }
        let uuid = udn
        let loc = baseURL + "/ms/device.xml"
        let entries = [
            ("upnp:rootdevice", uuid + "::upnp:rootdevice"),
            (uuid, uuid),
            ("urn:schemas-upnp-org:device:MediaServer:1",
             uuid + "::urn:schemas-upnp-org:device:MediaServer:1")
        ]

        var multicast = sockaddr_in()
        multicast.sin_family = sa_family_t(AF_INET)
        multicast.sin_port = in_port_t(1900).bigEndian
        multicast.sin_addr.s_addr = inet_addr("239.255.255.250")

        for _ in 0..<3 {
            for (nt, usn) in entries {
                let message = "NOTIFY * HTTP/1.1\r\n"
                    + "HOST: 239.255.255.250:1900\r\n"
                    + "CACHE-CONTROL: max-age=1800\r\n"
                    + "LOCATION: \(loc)\r\n"
                    + "NT: \(nt)\r\n"
                    + "NTS: ssdp:alive\r\n"
                    + "SERVER: Darwin/UPnP/1.0 VideoLinker/1.0\r\n"
                    + "USN: \(usn)\r\n\r\n"
                Self.send(message, to: multicast, sock: ssdpFD)
            }
            usleep(120_000)
        }
    }

    private static func send(_ text: String, to destination: sockaddr_in, sock: Int32) {
        var dest = destination
        let data = Array(text.utf8)
        data.withUnsafeBytes { raw in
            withUnsafePointer(to: &dest) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(sock, raw.baseAddress, data.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // MARK: 设备描述

    private var deviceXML: String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<root xmlns=\"urn:schemas-upnp-org:device-1-0\" xmlns:dlna=\"urn:schemas-dlna-org:device-1-0\">"
            + "<specVersion><major>1</major><minor>0</minor></specVersion>"
            + "<device>"
            + "<deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>"
            + "<friendlyName>工具箱影库</friendlyName>"
            + "<manufacturer>VideoLinker</manufacturer>"
            + "<manufacturerURL>https://github.com/muxin520i/Toolbox</manufacturerURL>"
            + "<modelDescription>VideoLinker DLNA Media Server</modelDescription>"
            + "<modelName>工具箱媒体服务器</modelName>"
            + "<modelNumber>1.0</modelNumber>"
            + "<serialNumber>\(udn)</serialNumber>"
            + "<UDN>\(udn)</UDN>"
            + "<dlna:X_DLNADOC>DMS-1.50</dlna:X_DLNADOC>"
            + "<serviceList>"
            + "<service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>"
            + "<serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId>"
            + "<SCPDURL>/ms/cd.xml</SCPDURL>"
            + "<controlURL>/ms/control/ContentDirectory</controlURL>"
            + "<eventSubURL>/ms/event/ContentDirectory</eventSubURL></service>"
            + "<service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>"
            + "<serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>"
            + "<SCPDURL>/ms/cm.xml</SCPDURL>"
            + "<controlURL>/ms/control/ConnectionManager</controlURL>"
            + "<eventSubURL>/ms/event/ConnectionManager</eventSubURL></service>"
            + "</serviceList>"
            + "</device></root>"
    }

    private static let contentDirectorySCPD = """
    <?xml version="1.0" encoding="utf-8"?>
    <scpd xmlns="urn:schemas-upnp-org:service-1-0">
      <specVersion><major>1</major><minor>0</minor></specVersion>
      <actionList>
        <action><name>Browse</name><argumentList>
          <argument><name>ObjectID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ObjectID</relatedStateVariable></argument>
          <argument><name>BrowseFlag</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_BrowseFlag</relatedStateVariable></argument>
          <argument><name>Filter</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Filter</relatedStateVariable></argument>
          <argument><name>StartingIndex</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Index</relatedStateVariable></argument>
          <argument><name>RequestedCount</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument>
          <argument><name>SortCriteria</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_SortCriteria</relatedStateVariable></argument>
          <argument><name>Result</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Result</relatedStateVariable></argument>
          <argument><name>NumberReturned</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument>
          <argument><name>TotalMatches</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument>
          <argument><name>UpdateID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_UpdateID</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>GetSearchCapabilities</name><argumentList>
          <argument><name>SearchCaps</name><direction>out</direction><relatedStateVariable>SearchCapabilities</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>GetSortCapabilities</name><argumentList>
          <argument><name>SortCaps</name><direction>out</direction><relatedStateVariable>SortCapabilities</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>GetSystemUpdateID</name><argumentList>
          <argument><name>Id</name><direction>out</direction><relatedStateVariable>SystemUpdateID</relatedStateVariable></argument>
        </argumentList></action>
      </actionList>
      <serviceStateTable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_ObjectID</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_Result</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_BrowseFlag</name><dataType>string</dataType>
          <allowedValueList><allowedValue>BrowseMetadata</allowedValue><allowedValue>BrowseDirectChildren</allowedValue></allowedValueList>
        </stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_Filter</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_SortCriteria</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_Index</name><dataType>ui4</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_Count</name><dataType>ui4</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_UpdateID</name><dataType>ui4</dataType></stateVariable>
        <stateVariable sendEvents="yes"><name>SystemUpdateID</name><dataType>ui4</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>SearchCapabilities</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>SortCapabilities</name><dataType>string</dataType></stateVariable>
      </serviceStateTable>
    </scpd>
    """

    private static let connectionManagerSCPD = """
    <?xml version="1.0" encoding="utf-8"?>
    <scpd xmlns="urn:schemas-upnp-org:service-1-0">
      <specVersion><major>1</major><minor>0</minor></specVersion>
      <actionList>
        <action><name>GetProtocolInfo</name><argumentList>
          <argument><name>Source</name><direction>out</direction><relatedStateVariable>SourceProtocolInfo</relatedStateVariable></argument>
          <argument><name>Sink</name><direction>out</direction><relatedStateVariable>SinkProtocolInfo</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>GetCurrentConnectionIDs</name><argumentList>
          <argument><name>ConnectionIDs</name><direction>out</direction><relatedStateVariable>CurrentConnectionIDs</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>GetCurrentConnectionInfo</name><argumentList>
          <argument><name>ConnectionID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable></argument>
          <argument><name>RcsID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_RcsID</relatedStateVariable></argument>
          <argument><name>AVTransportID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_AVTransportID</relatedStateVariable></argument>
          <argument><name>ProtocolInfo</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ProtocolInfo</relatedStateVariable></argument>
          <argument><name>PeerConnectionManager</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionManager</relatedStateVariable></argument>
          <argument><name>PeerConnectionID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable></argument>
          <argument><name>Direction</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Direction</relatedStateVariable></argument>
          <argument><name>Status</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionStatus</relatedStateVariable></argument>
        </argumentList></action>
      </actionList>
      <serviceStateTable>
        <stateVariable sendEvents="yes"><name>SourceProtocolInfo</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="yes"><name>SinkProtocolInfo</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="yes"><name>CurrentConnectionIDs</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionStatus</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionManager</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_Direction</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_ProtocolInfo</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionID</name><dataType>i4</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_AVTransportID</name><dataType>i4</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_RcsID</name><dataType>i4</dataType></stateVariable>
      </serviceStateTable>
    </scpd>
    """

    // MARK: 小工具

    private static func parseHeaders(_ head: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }

    private static func header(_ name: String, in text: String) -> String? {
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            guard key.uppercased() == name.uppercased() else { continue }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func tag(_ name: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(name)>"),
              let end = xml.range(of: "</\(name)>", range: start.upperBound..<xml.endIndex) else {
            return nil
        }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func parseRange(_ value: String, size: Int64) -> (start: Int64, end: Int64)? {
        guard size > 0 else { return nil }
        let lower = value.lowercased()
        guard lower.hasPrefix("bytes=") else { return nil }
        let spec = String(value.dropFirst(6))
            .split(separator: ",")
            .first
            .map(String.init) ?? ""
        let pieces = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }

        let startText = pieces[0].trimmingCharacters(in: .whitespaces)
        let endText = pieces[1].trimmingCharacters(in: .whitespaces)

        if startText.isEmpty {
            guard let length = Int64(endText), length > 0 else { return nil }
            let start = max(0, size - length)
            return (start, size - 1)
        }
        guard let start = Int64(startText), start < size else { return nil }
        if endText.isEmpty { return (start, size - 1) }
        guard let end = Int64(endText) else { return nil }
        return (start, min(max(start, end), size - 1))
    }

    private static func httpDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date())
    }

    static func mime(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "ts", "m2ts", "mts": return "video/mp2t"
        case "mov": return "video/quicktime"
        case "avi": return "video/x-msvideo"
        case "flv": return "video/x-flv"
        case "wmv", "asf": return "video/x-ms-wmv"
        case "webm": return "video/webm"
        case "mpg", "mpeg", "vob": return "video/mpeg"
        case "3gp": return "video/3gpp"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        default: return "application/octet-stream"
        }
    }

    private final class Client {
        let connection: NWConnection
        var buffer = Data()
        var fileHandle: FileHandle?
        var total: Int64 = 0
        var sent: Int64 = 0
        var closed = false

        init(_ connection: NWConnection) {
            self.connection = connection
        }

        func closeFile() {
            try? fileHandle?.close()
            fileHandle = nil
        }
    }
}
