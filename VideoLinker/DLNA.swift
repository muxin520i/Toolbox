import Foundation
import SwiftUI

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
