import Foundation
import Citadel
import NIOCore

// MARK: - 远程文件（FTP / SFTP）
//
// 局域网里除了 SMB，还有一堆只开 FTP 的老 NAS、只给 SFTP 的服务器和 VPS。
// 这里把两种协议收成同一套接口：
//
//   list(path:)        列目录
//   fileSize(path:)    文件大小
//   read(offset:length:)  按字节读（给本地流代理用，播放器拖进度不整份下载）
//
// FTP 是自己用 POSIX socket 写的（PASV + MLSD/LIST + REST 续传）；
// SFTP 走 Citadel（SPM），只用到列目录、属性、范围读三个能力。

// MARK: - 配置

enum RemoteProtocol: String, Codable, CaseIterable, Identifiable {
    case ftp
    case sftp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        }
    }

    var defaultPort: Int {
        switch self {
        case .ftp: return 21
        case .sftp: return 22
        }
    }

    var symbol: String {
        switch self {
        case .ftp: return "network"
        case .sftp: return "lock.shield"
        }
    }
}

struct RemoteAccountConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var proto: RemoteProtocol = .ftp
    var host: String = ""
    var port: Int = 0
    var username: String = ""
    /// 登录后先进哪个目录，FTP 常见 /volume1/video
    var basePath: String = "/"

    var isUsable: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }

    var effectivePort: Int { port > 0 ? port : proto.defaultPort }

    var normalizedBasePath: String {
        let trimmed = basePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    static let storageKey = "remote.accounts.v1"
    static let passwordKeyPrefix = "remote.password."

    static func load() -> [RemoteAccountConfig] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([RemoteAccountConfig].self, from: data)
        else { return [] }
        return list
    }

    static func save(_ list: [RemoteAccountConfig]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    var savedPassword: String {
        get { Keychain.get(Self.passwordKeyPrefix + id.uuidString) ?? "" }
        set { Keychain.set(newValue, forKey: Self.passwordKeyPrefix + id.uuidString) }
    }

    func clearPassword() {
        Keychain.delete(Self.passwordKeyPrefix + id.uuidString)
    }
}

// MARK: - 目录条目

struct RemoteEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let isContainer: Bool
    let size: Int64?
}

// MARK: - 统一接口

protocol RemoteFileSource: AnyObject {
    func list(path: String) async throws -> [RemoteEntry]
    func fileSize(path: String) async throws -> UInt64
    func read(path: String, offset: UInt64, length: Int) async throws -> Data
    func verify() async throws
}

// MARK: - 错误

struct RemoteFileError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - FTP

/// 一条控制连接 + 同步命令实现，所有操作都排在 queue 上，不会并发打架。
final class FTPClient: RemoteFileSource, @unchecked Sendable {

    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private let basePath: String

    private let queue = DispatchQueue(label: "toolbox.ftp.client")
    private var controlFD: Int32 = -1
    private var readBuffer = Data()
    private var loggedIn = false

    init(host: String, port: Int, username: String, password: String, basePath: String = "/") {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.basePath = basePath == "/" ? "/" : basePath
    }

    convenience init(config: RemoteAccountConfig, password: String? = nil) {
        self.init(host: config.host.trimmingCharacters(in: .whitespacesAndNewlines),
                  port: config.effectivePort,
                  username: config.username,
                  password: password ?? config.savedPassword,
                  basePath: config.normalizedBasePath)
    }

    // MARK: 对外（async 包装）

    func list(path: String) async throws -> [RemoteEntry] {
        try await run { try $0.listSync(path: path) }
    }

    func fileSize(path: String) async throws -> UInt64 {
        try await run { try $0.sizeSync(path: path) }
    }

    func read(path: String, offset: UInt64, length: Int) async throws -> Data {
        try await run { try $0.readSync(path: path, offset: offset, length: length) }
    }

    func verify() async throws {
        try await run { client in
            let root = client.basePath
            _ = try client.listSync(path: root)
            return ()
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self, self.controlFD >= 0 else { return }
            _ = try? self.command("QUIT", expecting: 221)
            close(self.controlFD)
            self.controlFD = -1
            self.loggedIn = false
            self.readBuffer.removeAll()
        }
    }

    private func run<T>(_ body: @escaping (FTPClient) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.ensureLoggedIn()
                    continuation.resume(returning: try body(self))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: 连接与登录

    private func ensureLoggedIn() throws {
        if loggedIn, controlFD >= 0 { return }
        closeControl()

        controlFD = try Self.openSocket(host: host, port: port, timeout: 12)
        let (code, text) = try readResponse()
        guard code == 220 else {
            throw RemoteFileError(message: "FTP 服务器没有正常打招呼（\(code)）")
        }

        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let actualUser = user.isEmpty ? "anonymous" : user
        let actualPass = user.isEmpty ? (password.isEmpty ? "anonymous@" : password) : password

        let (userCode, userText) = try command("USER \(actualUser)", expecting: nil)
        if userCode == 331 {
            let (passCode, passText) = try command("PASS \(actualPass)", expecting: nil)
            guard passCode == 230 || passCode == 202 else {
                throw RemoteFileError(message: "登录失败：\(passText)")
            }
        } else if userCode != 230 {
            throw RemoteFileError(message: "登录失败：\(userText)")
        }

        _ = try command("TYPE I", expecting: 200)
        loggedIn = true

        if basePath != "/" {
            // 进不去就留在根目录，不阻断浏览
            _ = try? command("CWD \(basePath)", expecting: 250)
        }
    }

    private func closeControl() {
        if controlFD >= 0 {
            close(controlFD)
            controlFD = -1
        }
        loggedIn = false
        readBuffer.removeAll()
    }

    // MARK: 目录

    private func listSync(path: String) throws -> [RemoteEntry] {
        let directory = path.isEmpty ? "/" : path
        do {
            let raw = try dataCommand("MLSD \(directory)")
            return Self.parseMLSD(raw, directory: directory)
        } catch let error as RemoteFileError where error.message.contains("500") || error.message.contains("502") {
            // 老服务器不认 MLSD，退回 LIST
            let raw = try dataCommand("LIST \(directory)")
            return Self.parseLIST(raw).map {
                RemoteEntry(id: Self.joinPath(directory, $0.title),
                            title: $0.title,
                            isContainer: $0.isContainer,
                            size: $0.size)
            }
        }
    }

    private func sizeSync(path: String) throws -> UInt64 {
        _ = try? command("TYPE I", expecting: 200)
        let (code, text) = try command("SIZE \(path)", expecting: nil)
        guard code == 213 else {
            // 没有 SIZE 就退回列父目录找
            let parent = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            if let list = try? listSync(path: parent.isEmpty ? "/" : parent),
               let match = list.first(where: { $0.title == name }),
               let size = match.size {
                return UInt64(max(0, size))
            }
            throw RemoteFileError(message: "读不到文件大小（\(code)）")
        }
        let digits = text.split(separator: "\n").last.map(String.init) ?? text
        let value = digits.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: " ").last ?? ""
        guard let size = UInt64(value.trimmingCharacters(in: .whitespaces)) else {
            throw RemoteFileError(message: "文件大小格式不认识：\(text)")
        }
        return size
    }

    private func readSync(path: String, offset: UInt64, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        _ = try command("TYPE I", expecting: 200)

        let dataFD = try openPassive()
        var closed = false
        defer { if !closed { close(dataFD) } }

        if offset > 0 {
            let (code, text) = try command("REST \(offset)", expecting: nil)
            guard code == 350 else {
                throw RemoteFileError(message: "服务器不支持从中间读（\(code) \(text)）")
            }
        }

        try send("RETR \(path)")
        let (startCode, startText) = try readResponse()
        guard startCode == 150 || startCode == 125 else {
            throw RemoteFileError(message: "打开文件失败：\(startText)")
        }

        var data = Data()
        var remaining = length
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while remaining > 0 {
            let want = min(chunk.count, remaining)
            let count = recv(dataFD, &chunk, want, 0)
            if count <= 0 { break }
            data.append(contentsOf: chunk[0..<count])
            remaining -= count
        }
        close(dataFD)
        closed = true

        // 把 226 收掉，免得下一条命令读到上一单的尾巴
        _ = try? readResponse()
        return data
    }

    /// 发一条命令，把数据连接读干净
    private func dataCommand(_ commandLine: String) throws -> String {
        let dataFD = try openPassive()
        var closed = false
        defer { if !closed { close(dataFD) } }

        try send(commandLine)
        let (code, text) = try readResponse()
        guard code == 150 || code == 125 else {
            throw RemoteFileError(message: "目录打不开：\(code) \(text)")
        }

        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = recv(dataFD, &chunk, chunk.count, 0)
            if count <= 0 { break }
            data.append(contentsOf: chunk[0..<count])
        }
        close(dataFD)
        closed = true

        _ = try? readResponse()
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: 被动模式

    private func openPassive() throws -> Int32 {
        let (code, text) = try command("PASV", expecting: nil)
        guard code == 227 else {
            throw RemoteFileError(message: "服务器不接受被动模式（\(code)）")
        }
        guard let inside = text.range(of: "("), let end = text.range(of: ")", range: inside.upperBound..<text.endIndex) else {
            throw RemoteFileError(message: "PASV 返回看不懂：\(text)")
        }
        let numbers = text[inside.upperBound..<end.lowerBound]
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 6 else {
            throw RemoteFileError(message: "PASV 地址格式不对：\(text)")
        }

        // 服务器在 NAT 后面时常回内网 IP，用控制连接的对端地址更靠谱
        let peer = Self.peerAddress(controlFD) ?? "\(numbers[0]).\(numbers[1]).\(numbers[2]).\(numbers[3])"
        let dataPort = numbers[4] * 256 + numbers[5]
        return try Self.openSocket(host: peer, port: dataPort, timeout: 12)
    }

    // MARK: 协议收发

    @discardableResult
    private func command(_ line: String, expecting expected: Int?) throws -> (Int, String) {
        try send(line)
        let (code, text) = try readResponse()
        if let expected, code != expected {
            throw RemoteFileError(message: "\(line.split(separator: " ").first ?? "") 失败：\(code) \(text)")
        }
        return (code, text)
    }

    private func send(_ line: String) throws {
        guard controlFD >= 0 else { throw RemoteFileError(message: "连接已断开") }
        var payload = Data((line + "\r\n").utf8)
        while !payload.isEmpty {
            let sent = payload.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.send(controlFD, base, raw.count, 0)
            }
            if sent <= 0 { throw RemoteFileError(message: "命令发不出去") }
            payload.removeFirst(sent)
        }
    }

    /// 读一条（或多行）响应，返回状态码和完整文本
    private func readResponse() throws -> (Int, String) {
        var lines: [String] = []
        while true {
            let line = try readLine()
            lines.append(line)
            guard line.count >= 3, let code = Int(line.prefix(3)) else { continue }
            let fourth = line.count >= 4 ? line[line.index(line.startIndex, offsetBy: 3)] : " "
            if fourth == "-" { continue }
            return (code, lines.joined(separator: "\n"))
        }
    }

    private func readLine() throws -> String {
        while true {
            if let range = readBuffer.range(of: Data("\r\n".utf8)) {
                let lineData = readBuffer.subdata(in: readBuffer.startIndex..<range.lowerBound)
                readBuffer.removeSubrange(readBuffer.startIndex..<range.upperBound)
                if let text = String(data: lineData, encoding: .utf8) { return text }
                return String(decoding: lineData, as: UTF8.self)
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = recv(controlFD, &chunk, chunk.count, 0)
            if count <= 0 {
                throw RemoteFileError(message: "服务器把连接断了")
            }
            readBuffer.append(contentsOf: chunk[0..<count])
            if readBuffer.count > 256 * 1024 {
                throw RemoteFileError(message: "服务器回了一条超长响应")
            }
        }
    }

    // MARK: 解析

    private static func parseMLSD(_ text: String, directory: String) -> [RemoteEntry] {
        var result: [RemoteEntry] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let space = trimmed.firstIndex(of: " ") else { continue }
            let facts = String(trimmed[trimmed.startIndex..<space])
            var name = String(trimmed[trimmed.index(after: space)...])
            if name == "." || name == ".." { continue }

            var isDir = false
            var size: Int64?
            for pair in facts.split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = parts[0].lowercased()
                let value = String(parts[1])
                if key == "type" { isDir = value.lowercased() == "dir" || value.lowercased() == "cdir" || value.lowercased() == "pdir" }
                if key == "size" { size = Int64(value) }
            }
            if isDir { name = name.trimmingCharacters(in: .whitespaces) }
            let full = joinPath(directory, name)
            result.append(RemoteEntry(id: full, title: name, isContainer: isDir, size: size))
        }
        return sorted(result)
    }

    private static func parseLIST(_ text: String) -> [RemoteEntry] {
        var result: [RemoteEntry] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.lowercased().hasPrefix("total ") else { continue }

            // Unix 风格：drwxr-xr-x 2 user group 4096 Jan 01 12:00 name
            if let first = trimmed.first, "d-l".contains(first) {
                let parts = trimmed.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
                guard parts.count >= 9 else { continue }
                let name = String(parts[8])
                if name == "." || name == ".." { continue }
                let isDir = first == "d"
                let size = Int64(parts[4])
                result.append(RemoteEntry(id: name, title: name, isContainer: isDir, size: size))
                continue
            }

            // DOS 风格：01-01-24  12:00PM  <DIR>  name
            if trimmed.count > 8, trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)] == "-" {
                let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                if parts.count >= 4 {
                    let name = String(parts[3])
                    let isDir = parts[2].uppercased().contains("DIR")
                    let size = isDir ? nil : Int64(parts[2])
                    result.append(RemoteEntry(id: name, title: name, isContainer: isDir, size: size))
                }
            }
        }
        return sorted(result)
    }

    /// LIST 只给了名字，id 由调用方补全；MLSD 已经带完整路径
    private static func sorted(_ list: [RemoteEntry]) -> [RemoteEntry] {
        list.sorted {
            if $0.isContainer != $1.isContainer { return $0.isContainer }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func joinPath(_ base: String, _ name: String) -> String {
        if base == "/" { return "/" + name }
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    // MARK: socket 小工具

    private static func openSocket(host: String, port: Int, timeout: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let list = result else {
            throw RemoteFileError(message: "找不到主机 \(host)")
        }
        defer { freeaddrinfo(list) }

        var pointer: UnsafeMutablePointer<addrinfo>? = list
        while let info = pointer {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                var tv = timeval(tv_sec: timeout, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                if connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    return fd
                }
                close(fd)
            }
            pointer = info.pointee.ai_next
        }
        throw RemoteFileError(message: "连不上 \(host):\(port)")
    }

    private static func peerAddress(_ fd: Int32) -> String? {
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getpeername(fd, sa, &length)
            }
        }
        guard ok == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var raw = addr.sin_addr
        guard inet_ntop(AF_INET, &raw, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }
}

// MARK: - SFTP

final class SFTPRemoteClient: RemoteFileSource, @unchecked Sendable {

    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private let basePath: String

    private let queue = DispatchQueue(label: "toolbox.sftp.client")
    private var ssh: SSHClient?
    private var sftp: SFTPClient?

    init(host: String, port: Int, username: String, password: String, basePath: String = "/") {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.basePath = basePath == "/" ? "/" : basePath
    }

    convenience init(config: RemoteAccountConfig, password: String? = nil) {
        self.init(host: config.host.trimmingCharacters(in: .whitespacesAndNewlines),
                  port: config.effectivePort,
                  username: config.username,
                  password: password ?? config.savedPassword,
                  basePath: config.normalizedBasePath)
    }

    var startPath: String { basePath }

    private func ensureConnected() async throws -> SFTPClient {
        if let sftp { return sftp }

        let settings = SSHClientSettings(
            host: host,
            port: port,
            authenticationMethod: {
                .passwordBased(username: self.username, password: self.password)
            },
            hostKeyValidator: .acceptAnything()
        )
        do {
            let client = try await SSHClient.connect(to: settings)
            let session = try await client.openSFTP()
            self.ssh = client
            self.sftp = session
            return session
        } catch {
            throw RemoteFileError(message: "SFTP 连接失败：\(error.localizedDescription)")
        }
    }

    func list(path: String) async throws -> [RemoteEntry] {
        let client = try await ensureConnected()
        do {
            let names = try await client.listDirectory(atPath: path)
            var result: [RemoteEntry] = []
            for group in names {
                for component in group.components {
                    let name = component.filename
                    if name == "." || name == ".." { continue }
                    let isDir = component.longname.hasPrefix("d")
                    let size = component.attributes.size.map { Int64($0) }
                    let full = path == "/" ? "/" + name : (path.hasSuffix("/") ? path + name : path + "/" + name)
                    result.append(RemoteEntry(id: full, title: name, isContainer: isDir, size: size))
                }
            }
            return result.sorted {
                if $0.isContainer != $1.isContainer { return $0.isContainer }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        } catch {
            throw RemoteFileError(message: "列目录失败：\(error.localizedDescription)")
        }
    }

    func fileSize(path: String) async throws -> UInt64 {
        let client = try await ensureConnected()
        do {
            let attrs = try await client.getAttributes(at: path)
            return attrs.size ?? 0
        } catch {
            throw RemoteFileError(message: "读不到文件大小：\(error.localizedDescription)")
        }
    }

    func read(path: String, offset: UInt64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let client = try await ensureConnected()
        do {
            let file = try await client.openFile(filePath: path, flags: .read)
            defer { Task { try? await file.close() } }
            let buffer = try await file.read(from: offset, length: UInt32(clamping: length))
            return Data(buffer: buffer)
        } catch {
            throw RemoteFileError(message: "读取失败：\(error.localizedDescription)")
        }
    }

    func verify() async throws {
        _ = try await list(path: startPath)
    }

    func disconnect() async {
        let session = sftp
        let client = ssh
        sftp = nil
        ssh = nil
        try? await session?.close()
        try? await client?.close()
    }
}

// MARK: - 工厂

enum RemoteFileFactory {
    static func make(config: RemoteAccountConfig, password: String? = nil) -> RemoteFileSource {
        switch config.proto {
        case .ftp:
            return FTPClient(config: config, password: password)
        case .sftp:
            return SFTPRemoteClient(config: config, password: password)
        }
    }
}
