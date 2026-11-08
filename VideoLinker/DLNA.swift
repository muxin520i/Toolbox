import Foundation
import SwiftUI
import Network

// MARK: - 设备

struct DLNADevice: Identifiable, Equatable {
    let id: String
    let name: String
    let controlURL: URL
}

// MARK: - SSDP 发现

/// 在局域网里找支持 DLNA 的电视 / 盒子。
/// 只做最基础的 MediaRenderer 发现，够把当前视频推过去就行。
final class DLNADiscovery: ObservableObject {
    @Published private(set) var devices: [DLNADevice] = []
    @Published private(set) var scanning = false
    @Published private(set) var hint = ""

    private var socketFD: Int32 = -1
    private var stopped = false

    func start() {
        guard !scanning else { return }
        devices = []
        hint = ""
        scanning = true
        stopped = false

        let thread = Thread { [weak self] in
            self?.runSSDP()
        }
        thread.name = "dlna.discovery"
        thread.stackSize = 512 * 1024
        thread.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.scanning = false
            self.stopped = true
            if self.socketFD >= 0 {
                close(self.socketFD)
                self.socketFD = -1
            }
            if self.devices.isEmpty {
                self.hint = "没找到设备。确认电视和手机连同一个 Wi-Fi，电视已打开「投屏 / 多屏互动」"
            }
        }
    }

    private func runSSDP() {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else {
            DispatchQueue.main.async {
                self.scanning = false
                self.hint = "创建网络套接字失败"
            }
            return
        }
        socketFD = sock

        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr.s_addr = INADDR_ANY

        let bound = withUnsafePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(sock)
            socketFD = -1
            DispatchQueue.main.async {
                self.scanning = false
                self.hint = "绑定本地端口失败"
            }
            return
        }

        sendSearch(sock)

        var seen = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(4)

        while !stopped, Date() < deadline {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)

            let count = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    buffer.withUnsafeMutableBytes { raw in
                        recvfrom(sock, raw.baseAddress, raw.count, 0, sa, &len)
                    }
                }
            }

            guard count > 0 else { continue }
            guard let text = String(bytes: buffer[0..<count], encoding: .utf8) else { continue }
            guard let location = Self.header("LOCATION", in: text), !seen.contains(location) else { continue }

            seen.insert(location)
            fetchDescription(location)
        }

        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    private func sendSearch(_ sock: Int32) {
        let message = "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: 239.255.255.250:1900\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: 3\r\n"
            + "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
        let data = Array(message.utf8)

        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = in_port_t(1900).bigEndian
        dest.sin_addr.s_addr = inet_addr("239.255.255.250")

        for _ in 0..<3 {
            data.withUnsafeBytes { buf in
                withUnsafePointer(to: &dest) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        _ = sendto(sock, buf.baseAddress, data.count, 0, sa,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            usleep(250_000)
        }
    }

    private func fetchDescription(_ location: String) {
        guard let url = URL(string: location) else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 4

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data,
                  let xml = String(data: data, encoding: .utf8),
                  xml.contains("MediaRenderer"),
                  let name = Self.tag("friendlyName", in: xml),
                  let control = Self.avTransportControl(in: xml),
                  let controlURL = URL(string: control, relativeTo: url)?.absoluteURL else { return }

            let device = DLNADevice(id: location, name: name, controlURL: controlURL)
            DispatchQueue.main.async {
                guard let self, !self.devices.contains(where: { $0.id == device.id }) else { return }
                self.devices.append(device)
            }
        }.resume()
    }

    // MARK: 小工具

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
        let value = String(xml[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func avTransportControl(in xml: String) -> String? {
        let pattern = "<service>(.*?)</service>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        for match in regex.matches(in: xml, options: [], range: range) {
            guard let blockRange = Range(match.range(at: 1), in: xml) else { continue }
            let block = String(xml[blockRange])
            guard block.contains("AVTransport") else { continue }
            return tag("controlURL", in: block)
        }
        return nil
    }
}

// MARK: - 控制

final class DLNAController: ObservableObject {
    @Published private(set) var device: DLNADevice?
    @Published private(set) var status = "还没选设备"
    @Published private(set) var busy = false

    func connect(_ device: DLNADevice) {
        self.device = device
        status = "已选择 \(device.name)"
    }

    func disconnect() {
        device = nil
        status = "还没选设备"
    }

    /// 返回错误文案，成功返回 nil
    func play(urlString: String, title: String) async -> String? {
        guard let device else { return "先选一台电视" }
        busy = true
        defer { busy = false }

        let metadata = Self.metadata(url: urlString, title: title)
        let inner = "<InstanceID>0</InstanceID>"
            + "<CurrentURI>\(Self.escape(urlString))</CurrentURI>"
            + "<CurrentURIMetaData>\(Self.escape(metadata))</CurrentURIMetaData>"

        do {
            try await soap(device: device, action: "SetAVTransportURI", inner: inner)
            try await soap(device: device, action: "Play",
                           inner: "<InstanceID>0</InstanceID><Speed>1</Speed>")
            status = "正在投屏到 \(device.name)"
            return nil
        } catch {
            status = "投放失败"
            return error.localizedDescription
        }
    }

    func pause() async {
        guard let device else { return }
        busy = true
        defer { busy = false }
        try? await soap(device: device, action: "Pause", inner: "<InstanceID>0</InstanceID>")
        status = "已暂停"
    }

    func stop() async {
        guard let device else { return }
        busy = true
        defer { busy = false }
        try? await soap(device: device, action: "Stop", inner: "<InstanceID>0</InstanceID>")
        status = "已停止"
    }

    private func soap(device: DLNADevice, action: String, inner: String) async throws {
        var request = URLRequest(url: device.controlURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"",
                         forHTTPHeaderField: "SOAPACTION")

        let body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>"
            + "<u:\(action) xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"
            + inner
            + "</u:\(action)></s:Body></s:Envelope>"

        request.httpBody = body.data(using: .utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "DLNA", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "电视拒绝了这次操作"])
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func metadata(url: String, title: String) -> String {
        "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" "
            + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
            + "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
            + "<item id=\"0\" parentID=\"-1\" restricted=\"1\">"
            + "<dc:title>\(escape(title))</dc:title>"
            + "<upnp:class>object.item.videoItem</upnp:class>"
            + "<res protocolInfo=\"http-get:*:video/mp4:*\">\(escape(url))</res>"
            + "</item></DIDL-Lite>"
    }
}

// MARK: - 投屏面板

struct DLNASheet: View {
    let sourceURL: String
    let title: String
    let isLocal: Bool

    @StateObject private var discovery = DLNADiscovery()
    @StateObject private var controller = DLNAController()
    @Environment(\.dismiss) private var dismiss

    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if discovery.scanning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在找同一 Wi-Fi 下的电视…")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    } else if discovery.devices.isEmpty {
                        Text(discovery.hint.isEmpty ? "没找到设备" : discovery.hint)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(discovery.devices) { device in
                            Button {
                                cast(to: device)
                            } label: {
                                HStack {
                                    Image(systemName: "tv")
                                        .foregroundStyle(.tint)
                                    Text(device.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if controller.device?.id == device.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("电视")
                } footer: {
                    Text("电视需要支持 DLNA / 多屏互动，并且和手机连同一个 Wi-Fi。")
                }

                if controller.device != nil {
                    Section("遥控") {
                        HStack(spacing: 12) {
                            Button {
                                Task { await controller.pause() }
                            } label: {
                                Label("暂停", systemImage: "pause.fill")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                Task { await controller.stop() }
                            } label: {
                                Label("停止", systemImage: "stop.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                        .disabled(controller.busy)
                    }
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("投屏到电视")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        discovery.start()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(discovery.scanning)
                }
            }
        }
        .onAppear { discovery.start() }
    }

    private func cast(to device: DLNADevice) {
        controller.connect(device)

        Task { @MainActor in
            var url = sourceURL

            if isLocal {
                let path = URL(string: sourceURL)?.path ?? sourceURL
                let server = LANShareServer.shared
                if !server.running { server.start() }

                // 端口绑定是异步的，给它一点时间
                var http: URL?
                for _ in 0..<10 {
                    http = server.httpURL(forFile: path)
                    if http != nil { break }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }

                guard let http else {
                    message = "局域网服务还没准备好，确认视频在播放列表里，稍后再试"
                    return
                }
                url = http.absoluteString
            }

            if let error = await controller.play(urlString: url, title: title) {
                message = error
            } else {
                message = "已投到 \(device.name)，用电视遥控器控制播放"
            }
        }
    }
}

// MARK: - 接收投屏（手机当电视）
//
// 和上面的 DLNAController 正好相反：手机自己当一个 MediaRenderer，
// 在局域网里用 SSDP 应答「我在这里」，电视 / 电脑的投屏列表里就会出现「工具箱」。
// 控制器发来 SetAVTransportURI + Play，App 直接用自己的播放器放这条地址。
//
// 只用公开的 UPnP 协议，不碰私有接口。端口和局域网投屏（8088）错开。

final class DLNAReceiver: ObservableObject {

    static let shared = DLNAReceiver()

    @Published private(set) var running = false
    @Published private(set) var address = ""
    @Published private(set) var errorText = ""
    @Published private(set) var currentTitle = ""
    @Published private(set) var currentURI = ""
    @Published private(set) var transportState = "STOPPED"

    /// 控制器点播放时回调，交给界面拉起播放页
    var onPlay: ((URL) -> Void)?

    private let queue = DispatchQueue(label: "com.example.VideoLinker.dlna.receiver")
    private let ports: [UInt16] = [8095, 8096, 8097]
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var stopped = true
    private var activePort: UInt16 = 0
    private var ssdpFD: Int32 = -1

    /// 只在 queue 上读写
    private var stateURI = ""
    private var stateTitle = ""
    private var stateTransport = "STOPPED"
    private var positionBase: Double = 0
    private var playStartedAt: Date?
    private var lastPlayedURI = ""

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
            self.stateURI = ""
            self.stateTitle = ""
            self.stateTransport = "STOPPED"
            self.positionBase = 0
            self.playStartedAt = nil
            self.lastPlayedURI = ""
            self.publish()
            DispatchQueue.main.async {
                self.running = false
                self.address = ""
            }
        }
    }

    private func listen(at index: Int) {
        guard !stopped else { return }
        guard index < ports.count else {
            DispatchQueue.main.async {
                self.running = false
                self.errorText = "端口 8095–8097 都被占用了"
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
                    DispatchQueue.main.async {
                        self.address = "http://\(ip):\(port)"
                        self.running = true
                        self.errorText = ""
                    }
                    self.startSSDP()
                    self.announce()
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
        let key = "dlna.receiver.udn"
        if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty { return value }
        let value = "uuid:" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        clients[ObjectIdentifier(connection)] = client

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.clients.removeValue(forKey: ObjectIdentifier(connection))
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(client)
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
                client.connection.cancel()
                return
            }
            self.receive(client)
        }
    }

    /// 返回 true 表示已经回复并准备断开
    private func tryProcess(_ client: Client) -> Bool {
        guard let end = client.buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if client.buffer.count > 128 * 1024 {
                client.connection.cancel()
                return true
            }
            return false
        }

        let head = String(data: client.buffer.subdata(in: 0..<end.lowerBound), encoding: .utf8) ?? ""
        let headers = parseHeaders(head)
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound

        guard client.buffer.count >= bodyStart + length else { return false }

        let body = String(data: client.buffer.subdata(in: bodyStart..<(bodyStart + length)), encoding: .utf8) ?? ""
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")

        guard parts.count >= 2 else {
            respond(client, status: "400 Bad Request", body: "")
            return true
        }

        route(
            method: String(parts[0]).uppercased(),
            path: String(parts[1]),
            headers: headers,
            body: body,
            client: client
        )
        return true
    }

    private func parseHeaders(_ head: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }

    private func route(method: String, path rawPath: String, headers: [String: String], body: String, client: Client) {
        let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath

        if method == "GET" {
            switch path {
            case "/dlna/device.xml":
                respond(client, body: deviceXML)
                return
            case "/dlna/AVTransport.xml":
                respond(client, body: Self.avTransportSCPD)
                return
            case "/dlna/RenderingControl.xml":
                respond(client, body: Self.renderingControlSCPD)
                return
            case "/dlna/ConnectionManager.xml":
                respond(client, body: Self.connectionManagerSCPD)
                return
            default:
                break
            }
        }

        if method == "POST", path.hasPrefix("/dlna/control/") {
            let service = String(path.dropFirst("/dlna/control/".count))
            handleSOAP(service: service, headers: headers, body: body, client: client)
            return
        }

        if method == "SUBSCRIBE" || method == "UNSUBSCRIBE" {
            respond(client, body: "", extra: [
                "SID": "uuid:\(UUID().uuidString.lowercased())",
                "TIMEOUT": "Second-1800"
            ])
            return
        }

        respond(client, status: "404 Not Found", body: "")
    }

    private func respond(_ client: Client,
                         status: String = "200 OK",
                         body: String,
                         type: String = "text/xml; charset=\"utf-8\"",
                         extra: [String: String] = [:]) {
        let data = Data(body.utf8)
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(data.count)\r\n"
        head += "Connection: close\r\n"
        head += "Server: Darwin/UPnP/1.0 VideoLinker/1.0\r\n"
        for (key, value) in extra {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var payload = Data(head.utf8)
        payload.append(data)
        client.connection.send(content: payload, completion: .contentProcessed { _ in
            client.connection.cancel()
        })
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

        switch service {
        case "AVTransport":
            handleAVTransport(action: action, body: body, client: client)
        case "RenderingControl":
            handleRenderingControl(action: action, client: client)
        default:
            handleConnectionManager(action: action, client: client)
        }
    }

    private func handleAVTransport(action: String, body: String, client: Client) {
        switch action {
        case "SetAVTransportURI", "SetNextAVTransportURI":
            let uri = unescape(tag("CurrentURI", in: body) ?? "")
            let title = unescape(tag("dc:title", in: body) ?? "")

            if action == "SetAVTransportURI" {
                stateURI = uri
                stateTitle = title.isEmpty ? Self.name(from: uri) : title
                stateTransport = "STOPPED"
                positionBase = 0
                playStartedAt = nil
                lastPlayedURI = ""
                publish()
            }
            respond(client, body: envelope(service: "AVTransport", action: action))

        case "Play":
            let uri = stateURI
            if !uri.isEmpty, let url = URL(string: uri) {
                if stateTransport != "PLAYING" {
                    stateTransport = "PLAYING"
                    playStartedAt = Date()
                    publish()
                }
                if lastPlayedURI != uri {
                    lastPlayedURI = uri
                    DispatchQueue.main.async { self.onPlay?(url) }
                }
            }
            respond(client, body: envelope(service: "AVTransport", action: action))

        case "Pause":
            if stateTransport == "PLAYING" {
                positionBase = position()
                playStartedAt = nil
            }
            stateTransport = "PAUSED_PLAYBACK"
            publish()
            respond(client, body: envelope(service: "AVTransport", action: action))

        case "Stop":
            stateTransport = "STOPPED"
            playStartedAt = nil
            positionBase = 0
            lastPlayedURI = ""
            publish()
            respond(client, body: envelope(service: "AVTransport", action: action))

        case "Seek":
            let target = unescape(tag("Target", in: body) ?? "")
            if let seconds = Self.seconds(from: target) {
                positionBase = seconds
                playStartedAt = stateTransport == "PLAYING" ? Date() : nil
            }
            respond(client, body: envelope(service: "AVTransport", action: action))

        case "GetTransportInfo":
            let state = stateURI.isEmpty ? "NO_MEDIA_PRESENT" : stateTransport
            let inner = "<CurrentTransportState>\(state)</CurrentTransportState>"
                + "<CurrentTransportStatus>OK</CurrentTransportStatus>"
                + "<CurrentSpeed>1</CurrentSpeed>"
            respond(client, body: envelope(service: "AVTransport", action: action, inner: inner))

        case "GetPositionInfo":
            let uri = stateURI
            let time = Self.timeText(position())
            let inner = "<Track>1</Track>"
                + "<TrackDuration>00:00:00</TrackDuration>"
                + "<TrackMetaData></TrackMetaData>"
                + "<TrackURI>\(escape(uri))</TrackURI>"
                + "<RelTime>\(time)</RelTime>"
                + "<AbsTime>\(time)</AbsTime>"
                + "<RelCount>2147483647</RelCount>"
                + "<AbsCount>2147483647</AbsCount>"
            respond(client, body: envelope(service: "AVTransport", action: action, inner: inner))

        case "GetMediaInfo":
            let uri = stateURI
            let inner = "<NrTracks>1</NrTracks>"
                + "<MediaDuration>00:00:00</MediaDuration>"
                + "<CurrentURI>\(escape(uri))</CurrentURI>"
                + "<CurrentURIMetaData></CurrentURIMetaData>"
                + "<NextURI></NextURI>"
                + "<NextURIMetaData></NextURIMetaData>"
                + "<PlayMedium>NETWORK</PlayMedium>"
                + "<RecordMedium>NOT_IMPLEMENTED</RecordMedium>"
                + "<WriteStatus>NOT_IMPLEMENTED</WriteStatus>"
            respond(client, body: envelope(service: "AVTransport", action: action, inner: inner))

        case "GetTransportSettings":
            let inner = "<PlayMode>NORMAL</PlayMode><RecQualityMode>NOT_IMPLEMENTED</RecQualityMode>"
            respond(client, body: envelope(service: "AVTransport", action: action, inner: inner))

        case "GetDeviceCapabilities":
            let inner = "<PlayMedia>NETWORK</PlayMedia><RecMedia>NOT_IMPLEMENTED</RecMedia><RecQualityModes>NOT_IMPLEMENTED</RecQualityModes>"
            respond(client, body: envelope(service: "AVTransport", action: action, inner: inner))

        case "GetCurrentTransportActions":
            let inner = "<Actions>Play,Pause,Stop,Seek</Actions>"
            respond(client, body: envelope(service: "AVTransport", action: action, inner: inner))

        default:
            respond(client, body: envelope(service: "AVTransport", action: action))
        }
    }

    private func handleRenderingControl(action: String, client: Client) {
        let inner: String
        switch action {
        case "GetVolume":
            inner = "<CurrentVolume>80</CurrentVolume>"
        case "GetMute":
            inner = "<CurrentMute>0</CurrentMute>"
        case "ListPresets":
            inner = "<CurrentPresetNameList>FactoryDefaults</CurrentPresetNameList>"
        default:
            inner = ""
        }
        respond(client, body: envelope(service: "RenderingControl", action: action, inner: inner))
    }

    private func handleConnectionManager(action: String, client: Client) {
        var inner = ""
        switch action {
        case "GetProtocolInfo":
            inner = "<SourceProtocolInfo></SourceProtocolInfo>"
                + "<SinkProtocolInfo>http-get:*:video/mp4:*,http-get:*:video/x-matroska:*,"
                + "http-get:*:application/vnd.apple.mpegurl:*,http-get:*:audio/mpeg:*,"
                + "http-get:*:image/jpeg:*,http-get:*:*:*</SinkProtocolInfo>"
        case "GetCurrentConnectionIDs":
            inner = "<ConnectionIDs>0</ConnectionIDs>"
        case "GetCurrentConnectionInfo":
            inner = "<RcsID>-1</RcsID><AVTransportID>0</AVTransportID>"
                + "<ProtocolInfo></ProtocolInfo><PeerConnectionManager></PeerConnectionManager>"
                + "<PeerConnectionID>-1</PeerConnectionID><Direction>Input</Direction>"
                + "<Status>OK</Status>"
        default:
            break
        }
        respond(client, body: envelope(service: "ConnectionManager", action: action, inner: inner))
    }

    private func envelope(service: String, action: String, inner: String = "") -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>"
            + "<u:\(action)Response xmlns:u=\"urn:schemas-upnp-org:service:\(service):1\">"
            + inner
            + "</u:\(action)Response></s:Body></s:Envelope>"
    }

    // MARK: 状态

    private func publish() {
        let uri = stateURI
        let title = stateTitle
        let transport = stateTransport
        DispatchQueue.main.async {
            self.currentURI = uri
            self.currentTitle = title
            self.transportState = transport
        }
    }

    private func position() -> Double {
        var value = positionBase
        if stateTransport == "PLAYING", let start = playStartedAt {
            value += Date().timeIntervalSince(start)
        }
        return max(0, value)
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
                self.errorText = "1900 端口被占用，投屏列表里可能搜不到手机"
            }
            return
        }

        var group = ip_mreq()
        group.imr_multiaddr.s_addr = inet_addr("239.255.255.250")
        group.imr_interface.s_addr = INADDR_ANY
        let joined = setsockopt(sock, IPPROTO_IP, IP_ADD_MEMBERSHIP, &group,
                                socklen_t(MemoryLayout<ip_mreq>.size))
        if joined != 0 {
            // iOS 14 起组播要 multicast 权限，免费签名申请不到。
            // 这时还能靠手动添加设备地址（device.xml）连上，先提示清楚。
            DispatchQueue.main.async {
                self.errorText = "系统没放行组播，投屏列表可能搜不到；可手动添加设备地址（见下方）"
            }
        }

        ssdpFD = sock

        let thread = Thread { [weak self] in
            self?.ssdpLoop(sock)
        }
        thread.name = "dlna.receiver.ssdp"
        thread.stackSize = 512 * 1024
        thread.start()
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
            if !matches(st) {
                // 媒体服务器和接收端都想绑 1900，内核只会把每个包分给其中一个 socket。
                // 收到不归自己的搜索就转给 MediaLibraryServer，避免电视漏掉媒体服务器。
                _ = MediaLibraryServer.shared.handleForwardedSearch(text, from: from, sock: sock)
                continue
            }
            reply(to: from, requestST: st, sock: sock)
        }
    }

    private func matches(_ st: String) -> Bool {
        let lower = st.lowercased()
        if lower == "ssdp:all" || lower == "upnp:rootdevice" { return true }
        if lower == udn.lowercased() { return true }
        if lower.contains("devicetype:mediarenderer") { return true }
        return false
    }

    private func reply(to destination: sockaddr_in, requestST: String, sock: Int32) {
        let uuid = udn
        let loc = baseURL + "/dlna/device.xml"

        var targets: [(String, String)] = []
        if requestST == "ssdp:all" {
            targets = [
                ("upnp:rootdevice", uuid + "::upnp:rootdevice"),
                (uuid, uuid),
                ("urn:schemas-upnp-org:device:MediaRenderer:1",
                 uuid + "::urn:schemas-upnp-org:device:MediaRenderer:1")
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
        let loc = baseURL + "/dlna/device.xml"
        let entries = [
            ("upnp:rootdevice", uuid + "::upnp:rootdevice"),
            (uuid, uuid),
            ("urn:schemas-upnp-org:device:MediaRenderer:1",
             uuid + "::urn:schemas-upnp-org:device:MediaRenderer:1")
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

    // MARK: 小工具

    private static func header(_ name: String, in text: String) -> String? {
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            guard key.uppercased() == name.uppercased() else { continue }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func tag(_ name: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(name)>"),
              let end = xml.range(of: "</\(name)>", range: start.upperBound..<xml.endIndex) else {
            return nil
        }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    private func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func name(from uri: String) -> String {
        guard let url = URL(string: uri) else { return "投屏内容" }
        let name = url.lastPathComponent.removingPercentEncoding ?? ""
        return name.isEmpty ? (url.host ?? "投屏内容") : name
    }

    private static func seconds(from target: String) -> Double? {
        let parts = target.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        return parts[0]
    }

    private static func timeText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func httpDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date())
    }

    private final class Client {
        let connection: NWConnection
        var buffer = Data()

        init(_ connection: NWConnection) {
            self.connection = connection
        }
    }

    // MARK: 设备描述

    private var deviceXML: String {
        let base = baseURL
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<root xmlns=\"urn:schemas-upnp-org:device-1-0\" xmlns:dlna=\"urn:schemas-dlna-org:device-1-0\">"
            + "<specVersion><major>1</major><minor>0</minor></specVersion>"
            + "<device>"
            + "<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>"
            + "<friendlyName>工具箱</friendlyName>"
            + "<manufacturer>VideoLinker</manufacturer>"
            + "<manufacturerURL>https://github.com/muxin520i/Toolbox</manufacturerURL>"
            + "<modelDescription>VideoLinker DLNA Renderer</modelDescription>"
            + "<modelName>工具箱接收端</modelName>"
            + "<modelNumber>1.0</modelNumber>"
            + "<serialNumber>\(udn)</serialNumber>"
            + "<UDN>\(udn)</UDN>"
            + "<dlna:X_DLNADOC>DMR-1.50</dlna:X_DLNADOC>"
            + "<serviceList>"
            + "<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>"
            + "<serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>"
            + "<SCPDURL>/dlna/AVTransport.xml</SCPDURL>"
            + "<controlURL>/dlna/control/AVTransport</controlURL>"
            + "<eventSubURL>/dlna/event/AVTransport</eventSubURL></service>"
            + "<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>"
            + "<serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>"
            + "<SCPDURL>/dlna/RenderingControl.xml</SCPDURL>"
            + "<controlURL>/dlna/control/RenderingControl</controlURL>"
            + "<eventSubURL>/dlna/event/RenderingControl</eventSubURL></service>"
            + "<service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>"
            + "<serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>"
            + "<SCPDURL>/dlna/ConnectionManager.xml</SCPDURL>"
            + "<controlURL>/dlna/control/ConnectionManager</controlURL>"
            + "<eventSubURL>/dlna/event/ConnectionManager</eventSubURL></service>"
            + "</serviceList>"
            + "<presentationURL>\(base)/dlna/device.xml</presentationURL>"
            + "</device></root>"
    }

    private static let avTransportSCPD = """
    <?xml version="1.0" encoding="utf-8"?>
    <scpd xmlns="urn:schemas-upnp-org:service-1-0">
      <specVersion><major>1</major><minor>0</minor></specVersion>
      <actionList>
        <action><name>SetAVTransportURI</name><argumentList>
          <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
          <argument><name>CurrentURI</name><direction>in</direction><relatedStateVariable>AVTransportURI</relatedStateVariable></argument>
          <argument><name>CurrentURIMetaData</name><direction>in</direction><relatedStateVariable>AVTransportURIMetaData</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>SetNextAVTransportURI</name><argumentList>
          <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
          <argument><name>NextURI</name><direction>in</direction><relatedStateVariable>NextAVTransportURI</relatedStateVariable></argument>
          <argument><name>NextURIMetaData</name><direction>in</direction><relatedStateVariable>NextAVTransportURIMetaData</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>Play</name><argumentList>
          <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
          <argument><name>Speed</name><direction>in</direction><relatedStateVariable>TransportPlaySpeed</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>Pause</name><argumentList>
          <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>Stop</name><argumentList>
          <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>Seek</name><argumentList>
          <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
          <argument><name>Unit</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_SeekMode</relatedStateVariable></argument>
          <argument><name>Target</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_SeekTarget</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>GetTransportInfo</name><argumentList>
          <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
          <argument><name>CurrentTransportState</name><direction>out</direction><relatedStateVariable>TransportState</relatedStateVariable></argument>
          <argument><name>CurrentTransportStatus</name><direction>out</direction><relatedStateVariable>TransportStatus</relatedStateVariable></argument>
          <argument><name>CurrentSpeed</name><direction>out</direction><relatedStateVariable>TransportPlaySpeed</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>GetPositionInfo</name><argumentList>
          <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
          <argument><name>Track</name><direction>out</direction><relatedStateVariable>CurrentTrack</relatedStateVariable></argument>
          <argument><name>TrackDuration</name><direction>out</direction><relatedStateVariable>CurrentTrackDuration</relatedStateVariable></argument>
          <argument><name>TrackMetaData</name><direction>out</direction><relatedStateVariable>CurrentTrackMetaData</relatedStateVariable></argument>
          <argument><name>TrackURI</name><direction>out</direction><relatedStateVariable>CurrentTrackURI</relatedStateVariable></argument>
          <argument><name>RelTime</name><direction>out</direction><relatedStateVariable>RelativeTimePosition</relatedStateVariable></argument>
          <argument><name>AbsTime</name><direction>out</direction><relatedStateVariable>AbsoluteTimePosition</relatedStateVariable></argument>
          <argument><name>RelCount</name><direction>out</direction><relatedStateVariable>RelativeCounterPosition</relatedStateVariable></argument>
          <argument><name>AbsCount</name><direction>out</direction><relatedStateVariable>AbsoluteCounterPosition</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>GetMediaInfo</name><argumentList>
          <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
          <argument><name>NrTracks</name><direction>out</direction><relatedStateVariable>NumberOfTracks</relatedStateVariable></argument>
          <argument><name>MediaDuration</name><direction>out</direction><relatedStateVariable>CurrentMediaDuration</relatedStateVariable></argument>
          <argument><name>CurrentURI</name><direction>out</direction><relatedStateVariable>AVTransportURI</relatedStateVariable></argument>
          <argument><name>CurrentURIMetaData</name><direction>out</direction><relatedStateVariable>AVTransportURIMetaData</relatedStateVariable></argument>
          <argument><name>NextURI</name><direction>out</direction><relatedStateVariable>NextAVTransportURI</relatedStateVariable></argument>
          <argument><name>NextURIMetaData</name><direction>out</direction><relatedStateVariable>NextAVTransportURIMetaData</relatedStateVariable></argument>
          <argument><name>PlayMedium</name><direction>out</direction><relatedStateVariable>PlaybackStorageMedium</relatedStateVariable></argument>
          <argument><name>RecordMedium</name><direction>out</direction><relatedStateVariable>RecordStorageMedium</relatedStateVariable></argument>
          <argument><name>WriteStatus</name><direction>out</direction><relatedStateVariable>RecordMediumWriteStatus</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>GetTransportSettings</name><argumentList>
          <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
          <argument><name>PlayMode</name><direction>out</direction><relatedStateVariable>CurrentPlayMode</relatedStateVariable></argument>
          <argument><name>RecQualityMode</name><direction>out</direction><relatedStateVariable>CurrentRecordQualityMode</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>GetDeviceCapabilities</name><argumentList>
          <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
          <argument><name>PlayMedia</name><direction>out</direction><relatedStateVariable>PossiblePlaybackStorageMedia</relatedStateVariable></argument>
          <argument><name>RecMedia</name><direction>out</direction><relatedStateVariable>PossibleRecordStorageMedia</relatedStateVariable></argument>
          <argument><name>RecQualityModes</name><direction>out</direction><relatedStateVariable>PossibleRecordQualityModes</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>GetCurrentTransportActions</name><argumentList>
          <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
          <argument><name>Actions</name><direction>out</direction><relatedStateVariable>CurrentTransportActions</relatedStateVariable></argument>
        </argumentList></action>
      </actionList>
      <serviceStateTable>
        <stateVariable sendEvents="yes"><name>TransportState</name><dataType>string</dataType>
          <allowedValueList><allowedValue>STOPPED</allowedValue><allowedValue>PLAYING</allowedValue><allowedValue>PAUSED_PLAYBACK</allowedValue><allowedValue>TRANSITIONING</allowedValue><allowedValue>NO_MEDIA_PRESENT</allowedValue></allowedValueList>
        </stateVariable>
        <stateVariable sendEvents="no"><name>TransportStatus</name><dataType>string</dataType><allowedValueList><allowedValue>OK</allowedValue><allowedValue>ERROR_OCCURRED</allowedValue></allowedValueList></stateVariable>
        <stateVariable sendEvents="no"><name>PlaybackStorageMedium</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>RecordStorageMedium</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>PossiblePlaybackStorageMedia</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>PossibleRecordStorageMedia</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>CurrentPlayMode</name><dataType>string</dataType><allowedValueList><allowedValue>NORMAL</allowedValue></allowedValueList><defaultValue>NORMAL</defaultValue></stateVariable>
        <stateVariable sendEvents="no"><name>TransportPlaySpeed</name><dataType>string</dataType><allowedValueList><allowedValue>1</allowedValue></allowedValueList></stateVariable>
        <stateVariable sendEvents="no"><name>RecordMediumWriteStatus</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>CurrentRecordQualityMode</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>PossibleRecordQualityModes</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>NumberOfTracks</name><dataType>ui4</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>CurrentTrack</name><dataType>ui4</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>CurrentTrackDuration</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>CurrentMediaDuration</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>CurrentTrackMetaData</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>CurrentTrackURI</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>AVTransportURI</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>AVTransportURIMetaData</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>NextAVTransportURI</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>NextAVTransportURIMetaData</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>RelativeTimePosition</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>AbsoluteTimePosition</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>RelativeCounterPosition</name><dataType>i4</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>AbsoluteCounterPosition</name><dataType>i4</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>CurrentTransportActions</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_SeekMode</name><dataType>string</dataType><allowedValueList><allowedValue>REL_TIME</allowedValue></allowedValueList></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_SeekTarget</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_InstanceID</name><dataType>ui4</dataType></stateVariable>
      </serviceStateTable>
    </scpd>
    """

    private static let renderingControlSCPD = """
    <?xml version="1.0" encoding="utf-8"?>
    <scpd xmlns="urn:schemas-upnp-org:service-1-0">
      <specVersion><major>1</major><minor>0</minor></specVersion>
      <actionList>
        <action><name>ListPresets</name><argumentList>
          <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
          <argument><name>CurrentPresetNameList</name><direction>out</direction><relatedStateVariable>PresetNameList</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>SelectPreset</name><argumentList>
          <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
          <argument><name>PresetName</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_PresetName</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>GetMute</name><argumentList>
          <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
          <argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
          <argument><name>CurrentMute</name><direction>out</direction><relatedStateVariable>Mute</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>SetMute</name><argumentList>
          <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
          <argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
          <argument><name>DesiredMute</name><direction>in</direction><relatedStateVariable>Mute</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>GetVolume</name><argumentList>
          <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
          <argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
          <argument><name>CurrentVolume</name><direction>out</direction><relatedStateVariable>Volume</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>SetVolume</name><argumentList>
          <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
          <argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
          <argument><name>DesiredVolume</name><direction>in</direction><relatedStateVariable>Volume</relatedStateVariable></argument>
        </argumentList></action>
      </actionList>
      <serviceStateTable>
        <stateVariable sendEvents="yes"><name>LastChange</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>PresetNameList</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>Mute</name><dataType>boolean</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>Volume</name><dataType>ui2</dataType><allowedValueRange><minimum>0</minimum><maximum>100</maximum><step>1</step></allowedValueRange></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_Channel</name><dataType>string</dataType><allowedValueList><allowedValue>Master</allowedValue></allowedValueList></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_InstanceID</name><dataType>ui4</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_PresetName</name><dataType>string</dataType><allowedValueList><allowedValue>FactoryDefaults</allowedValue></allowedValueList></stateVariable>
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
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionStatus</name><dataType>string</dataType><allowedValueList><allowedValue>OK</allowedValue><allowedValue>ContentFormatMismatch</allowedValue><allowedValue>InsufficientBandwidth</allowedValue><allowedValue>UnreliableChannel</allowedValue><allowedValue>Unknown</allowedValue></allowedValueList></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionManager</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_Direction</name><dataType>string</dataType><allowedValueList><allowedValue>Input</allowedValue><allowedValue>Output</allowedValue></allowedValueList></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_ProtocolInfo</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionID</name><dataType>i4</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_AVTransportID</name><dataType>i4</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_RcsID</name><dataType>i4</dataType></stateVariable>
      </serviceStateTable>
    </scpd>
    """
}

// MARK: - 接收投屏面板

struct DLNAReceiverView: View {
    @ObservedObject private var receiver = DLNAReceiver.shared
    @Environment(\.dismiss) private var dismiss

    @State private var enabled = false
    @State private var request: PlayRequest?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("接收投屏", isOn: $enabled)
                        .tint(Color(red: 1.0, green: 0.55, blue: 0.45))
                        .onChange(of: enabled) { value in
                            if value { receiver.start() } else { receiver.stop() }
                        }

                    if receiver.running {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 7, height: 7)
                            Text("正在广播「工具箱」")
                                .font(.system(size: 13))
                            Spacer()
                            Text(receiver.address.replacingOccurrences(of: "http://", with: ""))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if receiver.running {
                        Text("设备描述：\(receiver.address)/dlna/device.xml")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }

                    if !receiver.errorText.isEmpty {
                        Text(receiver.errorText)
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("状态")
                } footer: {
                    Text("开启后，同一个 Wi-Fi 下的视频 App / 电脑播放器的投屏列表里会出现「工具箱」。这一页要保持打开。")
                }

                Section {
                    Label("在手机视频 App 里点「投屏」，选「工具箱」", systemImage: "1.circle")
                    Label("电脑上用 Windows 播放器的「播放到设备」", systemImage: "2.circle")
                    Label("推送过来后会自动用本机播放器打开", systemImage: "3.circle")
                } header: {
                    Text("怎么用")
                } footer: {
                    Text("只接收 http / https 直链（mp4、m3u8 等）。Netflix 这类加密源推不过来。")
                }

                if !receiver.currentURI.isEmpty {
                    Section("最近接收") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(receiver.currentTitle.isEmpty ? "投屏内容" : receiver.currentTitle)
                                .font(.system(size: 14, weight: .medium))
                                .lineLimit(2)
                            Text(stateText)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Button("在手机上重新播放") {
                            if let url = URL(string: receiver.currentURI) {
                                request = PlayRequest(url: url)
                            }
                        }
                        .disabled(URL(string: receiver.currentURI) == nil)

                        Text(receiver.currentURI)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
            }
            .navigationTitle("接收投屏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                receiver.onPlay = { url in
                    request = PlayRequest(url: url)
                }
                LocalNetworkPermission.probe { _ in }
                enabled = true
                receiver.start()
            }
            .onDisappear {
                receiver.onPlay = nil
                receiver.stop()
                enabled = false
            }
        }
        .fullScreenCover(item: $request) { item in
            PlayerScreen(request: item)
        }
    }

    private var stateText: String {
        switch receiver.transportState {
        case "PLAYING": return "播放中"
        case "PAUSED_PLAYBACK": return "已暂停"
        case "STOPPED": return "已停止"
        default: return "等待播放"
        }
    }
}
