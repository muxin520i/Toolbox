import Foundation
import AMSMB2

// MARK: - 局域网影库：SMB 共享
//
// 走 AMSMB2（SPM）连 SMB2/3 共享。播放不是把 smb:// 地址直接喂给播放器
// （系统播放器不认识这个协议），而是起一个只回环的本地 HTTP 服务，
// 播放器请求哪一段，服务就从共享里读哪一段（见 SMBStreamServer.swift）。

// MARK: - 配置

struct SMBShareConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var host: String = ""
    var share: String = ""
    var username: String = ""

    var isUsable: Bool { !host.isEmpty && !share.isEmpty }

    static let storageKey = "smb.shares.v1"
    static let passwordKeyPrefix = "smb.password."

    static func load() -> [SMBShareConfig] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([SMBShareConfig].self, from: data)
        else { return [] }
        return list
    }

    static func save(_ list: [SMBShareConfig]) {
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

// MARK: - 客户端

/// 一个共享一条连接。连接是懒建立的，断了自己重连。
final class SMBShareClient {
    let config: SMBShareConfig
    /// 显式密码（测试连接时还没存进钥匙串，走这里）；nil 时读钥匙串
    private let passwordOverride: String?
    private var client: SMB2Manager?

    init(config: SMBShareConfig, password: String? = nil) {
        self.config = config
        self.passwordOverride = password
    }

    private func connect() async throws -> SMB2Manager {
        if let client { return client }
        let host = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "smb://\(host)") else {
            throw NSError(domain: "SMB", code: 1, userInfo: [NSLocalizedDescriptionKey: "主机地址写错了"])
        }
        let user = config.username.isEmpty ? "guest" : config.username
        let password = passwordOverride ?? config.savedPassword
        let credential = URLCredential(user: user, password: password,
                                       persistence: .forSession)
        guard let manager = SMB2Manager(url: url, credential: credential) else {
            throw NSError(domain: "SMB", code: 2, userInfo: [NSLocalizedDescriptionKey: "创建连接失败"])
        }
        do {
            try await manager.connectShare(name: config.share)
        } catch {
            throw NSError(domain: "SMB", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "连不上共享：\(error.localizedDescription)"])
        }
        client = manager
        return manager
    }

    func disconnect() async {
        if let client {
            try? await client.disconnectShare()
        }
        client = nil
    }

    /// 列目录，返回可直接用的条目模型
    func list(path: String) async throws -> [MediaEntry] {
        let manager = try await connect()
        let entries = try await manager.contentsOfDirectory(atPath: path)
        var result: [MediaEntry] = []
        for entry in entries {
            guard let name = entry[URLResourceKey.nameKey] as? String else { continue }
            let entryPath = entry[URLResourceKey.pathKey] as? String ?? joinPath(path, name)
            let isDir = (entry[URLResourceKey.fileResourceTypeKey] as? URLFileResourceType) == .directory
            let size = entry[URLResourceKey.fileSizeKey] as? Int64
            result.append(MediaEntry(id: entryPath, title: name, isContainer: isDir,
                                     resourceURL: isDir ? nil : nil, size: size))
        }
        // 目录在前，其余按名字排
        return result.sorted {
            if $0.isContainer != $1.isContainer { return $0.isContainer }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// 按字节范围读文件（给本地流代理用）
    func contents(path: String, range: Range<UInt64>) async throws -> Data {
        let manager = try await connect()
        return try await manager.contents(atPath: path, range: range, progress: nil)
    }

    func fileSize(path: String) async throws -> UInt64 {
        let manager = try await connect()
        let attrs = try await manager.attributesOfItem(atPath: path)
        return attrs[URLResourceKey.fileSizeKey] as? UInt64
            ?? attrs[URLResourceKey.fileSizeKey] as? Int64.map { UInt64($0) }
            ?? 0
    }

    private func joinPath(_ base: String, _ name: String) -> String {
        if base == "/" { return "/" + name }
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }
}
