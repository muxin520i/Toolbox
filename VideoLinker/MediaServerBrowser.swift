import Foundation
import SwiftUI

// MARK: - 局域网影库：DLNA 媒体服务器
//
// 发现：SSDP M-SEARCH（ST = MediaServer:1）→ 拿 LOCATION 描述 XML
// 浏览：ContentDirectory:1 的 Browse 动作（BrowseDirectChildren），解析 DIDL-Lite
// 播放：条目里的 http-get 资源地址，直接交给播放器
//
// 全部手写 HTTP + SOAP，不引第三方库。NAS 常见实现（群晖、威联通、
// OpenWrt 的 minidlna 等）都走这套标准协议。

// MARK: - 模型

struct MediaServerDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let controlURL: URL
}

/// 影库里的一个节点：目录或媒体文件。DLNA 与 SMB 浏览共用。
struct MediaEntry: Identifiable, Equatable {
    /// DLNA 用 objectID，SMB 用完整路径
    let id: String
    let title: String
    let isContainer: Bool
    let resourceURL: URL?
    let size: Int64?
}

// MARK: - 发现与浏览

final class MediaServerBrowser: ObservableObject {
    @Published private(set) var devices: [MediaServerDevice] = []
    @Published private(set) var scanning = false
    @Published private(set) var hint = ""

    private var socketFD: Int32 = -1
    private var stopped = false

    func scan() {
        guard !scanning else { return }
        devices = []
        hint = ""
        scanning = true
        stopped = false

        let thread = Thread { [weak self] in
            self?.runSSDP()
        }
        thread.name = "lanlibrary.discovery"
        thread.stackSize = 512 * 1024
        thread.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            self.scanning = false
            self.stopped = true
            if self.socketFD >= 0 {
                close(self.socketFD)
                self.socketFD = -1
            }
            if self.devices.isEmpty {
                self.hint = "没找到媒体服务器。确认 NAS 和手机在同一个 Wi-Fi，NAS 已打开媒体共享（DLNA）"
            }
        }
    }

    // MARK: SSDP

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
        var buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(4.5)

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
            + "ST: urn:schemas-upnp-org:device:MediaServer:1\r\n\r\n"
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
            usleep(300_000)
        }
    }

    /// 拿设备描述 XML，找 ContentDirectory 服务的控制地址
    private func fetchDescription(_ location: String) {
        guard let url = URL(string: location) else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 4

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data,
                  let xml = String(data: data, encoding: .utf8),
                  xml.contains("MediaServer"),
                  let name = Self.firstTag("friendlyName", in: xml) ?? Self.attrTag("friendlyName", in: xml),
                  let control = Self.contentDirectoryControl(in: xml),
                  let controlURL = URL(string: control, relativeTo: url)?.absoluteURL else { return }

            let device = MediaServerDevice(id: location, name: name, controlURL: controlURL)
            DispatchQueue.main.async {
                guard let self, !self.devices.contains(where: { $0.id == device.id }) else { return }
                self.devices.append(device)
            }
        }.resume()
    }

    // MARK: 浏览

    /// 列出某个容器下的直接子节点。返回条目数组；总数超过一次性返回上限时提示
    func browse(_ device: MediaServerDevice, objectID: String) async throws -> [MediaEntry] {
        let body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>"
            + "<u:Browse xmlns:u=\"urn:schemas-upnp-org:service:ContentDirectory:1\">"
            + "<ObjectID>\(Self.escape(objectID))</ObjectID>"
            + "<BrowseFlag>BrowseDirectChildren</BrowseFlag>"
            + "<Filter>*</Filter>"
            + "<StartingIndex>0</StartingIndex>"
            + "<RequestedCount>0</RequestedCount>"
            + "<SortCriteria></SortCriteria>"
            + "</u:Browse></s:Body></s:Envelope>"

        var request = URLRequest(url: device.controlURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "MediaServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "媒体服务器拒绝了浏览请求"])
        }
        guard let xml = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "MediaServer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "返回内容读不懂"])
        }
        guard let result = Self.tag("Result", in: xml) else {
            throw NSError(domain: "MediaServer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "这个目录是空的或不可读"])
        }
        let didl = Self.htmlUnescape(result)
        return Self.parseDIDL(didl)
    }

    // MARK: DIDL-Lite 解析

    static func parseDIDL(_ xml: String) -> [MediaEntry] {
        var entries: [MediaEntry] = []

        let pattern = #"<(container|item)\b([^>]*)>(.*?)</\1>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return entries
        }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        for match in regex.matches(in: xml, options: [], range: range) {
            guard let kindRange = Range(match.range(at: 1), in: xml),
                  let attrRange = Range(match.range(at: 2), in: xml),
                  let innerRange = Range(match.range(at: 3), in: xml) else { continue }

            let kind = String(xml[kindRange])
            let attrs = String(xml[attrRange])
            let inner = String(xml[innerRange])

            let objectID = attr(attrs, "id") ?? ""
            guard !objectID.isEmpty else { continue }

            let title = firstTagContent("dc:title", in: inner) ?? firstTagContent("title", in: inner) ?? "(未命名)"
            let isContainer = kind == "container"

            var resourceURL: URL?
            var size: Int64?
            if !isContainer {
                // 取第一个 http-get 的资源地址
                let resPattern = #"<res\b([^>]*)>([^<]+)</res>"#
                if let resRegex = try? NSRegularExpression(pattern: resPattern, options: []),
                   let first = resRegex.firstMatch(in: inner, options: [], range: NSRange(inner.startIndex..<inner.endIndex, in: inner)),
                   let resAttrRange = Range(first.range(at: 1), in: inner),
                   let resURLRange = Range(first.range(at: 2), in: inner) {
                    let resAttrs = String(inner[resAttrRange])
                    let protocolInfo = attr(resAttrs, "protocolInfo") ?? ""
                    if protocolInfo.isEmpty || protocolInfo.contains("http-get") {
                        let rawURL = String(inner[resURLRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        resourceURL = URL(string: rawURL)
                        size = Int64(attr(resAttrs, "size") ?? "")
                    }
                }
            }

            entries.append(MediaEntry(id: objectID,
                                      title: htmlUnescape(title),
                                      isContainer: isContainer,
                                      resourceURL: resourceURL,
                                      size: size))
        }
        return entries
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

    /// <name>value</name>
    private static func tag(_ name: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(name)>"),
              let end = xml.range(of: "</\(name)>", range: start.upperBound..<xml.endIndex) else {
            return nil
        }
        let value = String(xml[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// <name attr="...">value</name> 的 value
    private static func firstTag(_ name: String, in xml: String) -> String? {
        let pattern = "<\(name)[^>]*>([^<]*)</\(name)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: xml, options: [], range: NSRange(xml.startIndex..<xml.endIndex, in: xml)),
              let r = Range(match.range(at: 1), in: xml) else { return nil }
        let value = String(xml[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func attrTag(_ name: String, in xml: String) -> String? {
        let pattern = "<\(name)\\s+([^>]*)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: xml, options: [], range: NSRange(xml.startIndex..<xml.endIndex, in: xml)),
              let r = Range(match.range(at: 1), in: xml) else { return nil }
        return attr(String(xml[r]), "value")
    }

    private static func attr(_ block: String, _ name: String) -> String? {
        let pattern = "\(name)\\s*=\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: block, options: [], range: NSRange(block.startIndex..<block.endIndex, in: block)),
              let r = Range(match.range(at: 1), in: block) else { return nil }
        return String(block[r])
    }

    private static func firstTagContent(_ name: String, in xml: String) -> String? {
        firstTag(name, in: xml)
    }

    private static func contentDirectoryControl(in xml: String) -> String? {
        let pattern = "<service>(.*?)</service>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        for match in regex.matches(in: xml, options: [], range: range) {
            guard let blockRange = Range(match.range(at: 1), in: xml) else { continue }
            let block = String(xml[blockRange])
            guard block.contains("ContentDirectory") else { continue }
            return tag("controlURL", in: block)
        }
        return nil
    }

    static func htmlUnescape(_ text: String) -> String {
        var s = text
        // 数字实体 &#NNN; &#xHH; —— 从后往前替换，前面的索引不受影响
        let numPattern = "&#(x?[0-9a-fA-F]+);"
        if let regex = try? NSRegularExpression(pattern: numPattern, options: []) {
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            for match in regex.matches(in: s, options: [], range: range).reversed() {
                guard let entityRange = Range(match.range(at: 0), in: s),
                      let numRange = Range(match.range(at: 1), in: s) else { continue }
                let numText = String(s[numRange])
                let value: UInt32?
                if numText.hasPrefix("x") || numText.hasPrefix("X") {
                    value = UInt32(numText.dropFirst(), radix: 16)
                } else {
                    value = UInt32(numText)
                }
                if let value, let scalar = UnicodeScalar(value) {
                    s.replaceSubrange(entityRange, with: String(Character(scalar)))
                }
            }
        }
        let named: [(String, String)] = [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
        ]
        for (from, to) in named {
            s = s.replacingOccurrences(of: from, with: to)
        }
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        return s
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
