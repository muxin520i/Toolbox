import Foundation
import Security

// MARK: - 钥匙串
//
// WebDAV 密码不适合放 UserDefaults（明文可读），走 Keychain。

enum Keychain {
    static func set(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VideoLinker",
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VideoLinker",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VideoLinker",
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - 配置

struct WebDAVConfig: Codable, Equatable {
    var baseURL: String = ""
    var username: String = ""

    var isUsable: Bool {
        !baseURL.isEmpty && URL(string: baseURL) != nil
    }

    static let storageKey = "webdav.config.v1"
    static let passwordKey = "webdav.password"

    static func load() -> WebDAVConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let config = try? JSONDecoder().decode(WebDAVConfig.self, from: data)
        else { return WebDAVConfig() }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: WebDAVConfig.storageKey)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        Keychain.delete(passwordKey)
    }

    static var savedPassword: String {
        get { Keychain.get(passwordKey) ?? "" }
        set { Keychain.set(newValue, forKey: passwordKey) }
    }
}

// MARK: - 目录条目

struct WebDAVEntry: Identifiable, Equatable {
    /// 相对 base 的路径，以 / 开头，目录结尾带 /
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?

    var id: String { path }
}

// MARK: - 客户端

enum WebDAVError: LocalizedError {
    case badURL
    case unauthorized
    case notFound
    case server(Int)
    case badXML
    case network(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "地址格式不对，需要 http:// 或 https:// 开头"
        case .unauthorized: return "账号或密码不对（401）"
        case .notFound: return "路径不存在（404）"
        case .server(let code): return "服务器返回 \(code)"
        case .badXML: return "看不懂返回内容，可能不是 WebDAV 服务"
        case .network(let msg): return msg
        }
    }
}

final class WebDAVClient {
    let config: WebDAVConfig
    private let password: String

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    init(config: WebDAVConfig, password: String = WebDAVConfig.savedPassword) {
        self.config = config
        self.password = password
    }

    /// 把相对路径拼成完整 URL；目录会自动补结尾斜杠
    func url(for path: String, directory: Bool = false) throws -> URL {
        guard var text = URL(string: config.baseURL)?.absoluteString else { throw WebDAVError.badURL }
        while text.hasSuffix("/") { text.removeLast() }

        var relative = path
        if relative.hasPrefix("/") { relative.removeFirst() }
        let encoded = relative
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")

        var full = text
        if !encoded.isEmpty { full += "/" + encoded }
        if directory || encoded.isEmpty { full += "/" }

        guard let url = URL(string: full) else { throw WebDAVError.badURL }
        return url
    }

    var authorization: String? {
        guard !config.username.isEmpty || !password.isEmpty else { return nil }
        let raw = "\(config.username):\(password)"
        return "Basic " + Data(raw.utf8).base64EncodedString()
    }

    /// 列目录（Depth: 1）
    func list(path: String) async throws -> [WebDAVEntry] {
        let target = try url(for: path, directory: true)

        var request = URLRequest(url: target)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let auth = authorization {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <d:propfind xmlns:d="DAV:">
              <d:prop>
                <d:displayname/>
                <d:getcontentlength/>
                <d:getlastmodified/>
                <d:resourcetype/>
              </d:prop>
            </d:propfind>
            """.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw WebDAVError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw WebDAVError.badXML }
        switch http.statusCode {
        case 200, 207: break
        case 401, 403: throw WebDAVError.unauthorized
        case 404: throw WebDAVError.notFound
        default: throw WebDAVError.server(http.statusCode)
        }

        let parser = WebDAVListParser()
        guard parser.parse(data) else { throw WebDAVError.badXML }

        let basePath = (URL(string: config.baseURL)?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let currentPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var result: [WebDAVEntry] = []
        for raw in parser.entries {
            guard var relative = Self.relativePath(from: raw.href, basePath: basePath) else { continue }
            let isDir = raw.isDirectory || raw.href.hasSuffix("/")
            let trimmed = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            // 第一行通常是目录自己，跳过
            if trimmed == currentPath { continue }
            if relative.isEmpty { continue }

            if !relative.hasPrefix("/") { relative = "/" + relative }
            if isDir, !relative.hasSuffix("/") { relative += "/" }

            let name = Self.displayName(raw.href, path: relative)
            result.append(
                WebDAVEntry(
                    path: relative,
                    name: name,
                    isDirectory: isDir,
                    size: raw.size,
                    modified: raw.modified
                )
            )
        }

        // 目录在前，再按名字排
        return result.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: 上传 / 下载 / 建目录

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await Self.session.data(for: request)
        } catch {
            throw WebDAVError.network(error.localizedDescription)
        }
    }

    /// PUT 一个文件
    func put(path: String, data: Data, contentType: String = "application/octet-stream") async throws {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let auth = authorization {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let (_, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.network("服务器没有返回状态")
        }
        switch http.statusCode {
        case 200, 201, 204: return
        case 401, 403: throw WebDAVError.unauthorized
        case 404: throw WebDAVError.notFound
        default: throw WebDAVError.server(http.statusCode)
        }
    }

    /// GET 一个文件
    func get(path: String) async throws -> Data {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = "GET"
        if let auth = authorization {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.network("服务器没有返回状态")
        }
        switch http.statusCode {
        case 200: return data
        case 401, 403: throw WebDAVError.unauthorized
        case 404: throw WebDAVError.notFound
        default: throw WebDAVError.server(http.statusCode)
        }
    }

    /// 建目录。已经存在（405）也算成功
    func makeDirectory(path: String) async throws {
        var request = URLRequest(url: try url(for: path, directory: true))
        request.httpMethod = "MKCOL"
        if let auth = authorization {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let (_, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200, 201, 204, 405: return
        case 401, 403: throw WebDAVError.unauthorized
        default: throw WebDAVError.server(http.statusCode)
        }
    }

    /// href 可能是绝对路径 /dav/a.mp4，也可能是完整 URL，统一裁成相对 base 的路径
    private static func relativePath(from href: String, basePath: String) -> String? {
        var text = href
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            guard let url = URL(string: text) else { return nil }
            text = url.path
        }
        guard let decoded = text.removingPercentEncoding else { return nil }

        let trimmedBase = basePath.isEmpty ? "" : "/" + basePath
        if !trimmedBase.isEmpty, decoded.hasPrefix(trimmedBase) {
            var tail = String(decoded.dropFirst(trimmedBase.count))
            if !tail.hasPrefix("/") { tail = "/" + tail }
            return tail
        }
        return decoded
    }

    private static func displayName(_ href: String, path: String) -> String {
        var trimmed = path
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        let last = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return last.removingPercentEncoding ?? last
    }
}

// MARK: - PROPFIND 解析

private final class WebDAVListParser: NSObject, XMLParserDelegate {

    struct Raw {
        var href: String = ""
        var isDirectory = false
        var size: Int64 = 0
        var modified: Date?
    }

    private(set) var entries: [Raw] = []
    private var current: Raw?
    private var currentElement = ""
    private var buffer = ""

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        currentElement = name
        buffer = ""

        switch name {
        case "response":
            current = Raw()
        case "collection":
            current?.isDirectory = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "href":
            if current?.href.isEmpty ?? false {
                current?.href = text
            }
        case "getcontentlength":
            if let value = Int64(text) { current?.size = value }
        case "getlastmodified":
            if let date = Self.httpDate(text) { current?.modified = date }
        case "response":
            if let item = current, !item.href.isEmpty { entries.append(item) }
            current = nil
        default:
            break
        }
        buffer = ""
    }

    private static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}
