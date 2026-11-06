import Foundation
import CryptoKit
import GRDB
import Security

// MARK: - 换机搬家
//
// 换手机、重装系统时，列表、进度、备忘、书签、脚本全在 SQLite 里。
// 这里把整库和必要的偏好打成一个加密包，新机导入后下次启动自动换上。
//
// 包结构：魔数 8 字节 + 盐 16 字节 + AES-GCM 密文（nonce + 密文 + tag）。
// 密码用 SHA-256 迭代派生，不存任何明文。

enum MoveError: LocalizedError {
    case noDatabase
    case badFile
    case wrongPassword
    case damaged
    case emptyPassword
    case shortPassword

    var errorDescription: String? {
        switch self {
        case .noDatabase: return "还没有可打包的数据"
        case .badFile: return "这个文件不是工具箱的搬家包"
        case .wrongPassword: return "密码不对，或者文件被改过"
        case .damaged: return "包内容不完整，重新导出一份试试"
        case .emptyPassword: return "先设一个密码"
        case .shortPassword: return "密码至少 6 位"
        }
    }
}

enum TransferStore {
    static let magic = Data("VLMOVE01".utf8)
    static let fileExtension = "vlmove"
    static let minPasswordLength = 6

    /// 自己算目录，避免在 AppDB 初始化过程中反向依赖它
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VideoLinker", isDirectory: true)
    }

    static var databaseURL: URL {
        directory.appendingPathComponent(AppDB.fileName)
    }

    /// 启动时优先检查这两个文件，有就说明上次导入还没生效
    static var pendingDatabase: URL {
        directory.appendingPathComponent("pending-restore.sqlite")
    }

    static var pendingPrefs: URL {
        directory.appendingPathComponent("pending-restore.plist")
    }

    static var hasPendingRestore: Bool {
        FileManager.default.fileExists(atPath: pendingDatabase.path)
    }

    /// 用户导出时用的默认文件名
    static var suggestedFileName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return "工具箱搬家-\(formatter.string(from: Date())).\(fileExtension)"
    }

    // MARK: 导出

    /// 打一个加密包。数据库用 VACUUM INTO 取一致快照，避免读到写了一半的页。
    static func makePackage(password: String, includePreferences: Bool = true) throws -> Data {
        guard password.count >= minPasswordLength else { throw MoveError.shortPassword }
        guard AppDB.isReady else { throw MoveError.noDatabase }

        let snapshot = try databaseSnapshot()
        defer { try? FileManager.default.removeItem(at: snapshot) }

        guard let dbData = try? Data(contentsOf: snapshot), !dbData.isEmpty else {
            throw MoveError.noDatabase
        }

        var payload: [String: Any] = [
            "version": 1,
            "createdAt": Date(),
            "database": dbData
        ]
        if includePreferences {
            payload["preferences"] = exportablePreferences()
        }

        let plain = try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .binary,
            options: 0
        )

        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 16, buffer.baseAddress!)
        }

        let key = deriveKey(password, salt: salt)
        let sealed = try AES.GCM.seal(plain, using: key)
        guard let combined = sealed.combined else { throw MoveError.damaged }

        return magic + salt + combined
    }

    /// 写到临时目录，返回可分享的地址
    static func writePackage(password: String) throws -> URL {
        let data = try makePackage(password: password)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedFileName)
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 取一份一致的数据库快照。VACUUM INTO 不支持时退回直接复制。
    private static func databaseSnapshot() throws -> URL {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("transfer-snapshot-\(UUID().uuidString).sqlite")
        try? FileManager.default.removeItem(at: target)

        var vacuumFailed = false
        AppDB.write { db in
            do {
                let escaped = target.path.replacingOccurrences(of: "'", with: "''")
                try db.execute(sql: "VACUUM INTO '\(escaped)'")
            } catch {
                vacuumFailed = true
            }
        }

        if vacuumFailed || !FileManager.default.fileExists(atPath: target.path) {
            let source = databaseURL
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw MoveError.noDatabase
            }
            try FileManager.default.copyItem(at: source, to: target)
        }

        return target
    }

    // MARK: 导入

    /// 校验密码、解包，并把数据库写成「待恢复」。真正替换在下次启动时做。
    static func stageImport(from url: URL, password: String) throws {
        guard password.count >= minPasswordLength else { throw MoveError.shortPassword }
        guard let data = try? Data(contentsOf: url) else { throw MoveError.badFile }
        try stageImport(data: data, password: password)
    }

    static func stageImport(data: Data, password: String) throws {
        guard password.count >= minPasswordLength else { throw MoveError.shortPassword }
        guard data.count > magic.count + 16 + 16 else { throw MoveError.badFile }
        guard data.prefix(magic.count) == magic else { throw MoveError.badFile }

        let saltStart = magic.count
        let salt = data.subdata(in: saltStart..<(saltStart + 16))
        let body = data.subdata(in: (saltStart + 16)..<data.count)

        let key = deriveKey(password, salt: salt)

        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(combined: body)
            plain = try AES.GCM.open(box, using: key)
        } catch {
            throw MoveError.wrongPassword
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: plain, options: [], format: nil),
              let payload = plist as? [String: Any],
              let dbData = payload["database"] as? Data,
              !dbData.isEmpty
        else { throw MoveError.damaged }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: pendingDatabase)
        try dbData.write(to: pendingDatabase, options: .atomic)

        if let prefs = payload["preferences"] as? [String: Any],
           let prefsData = try? PropertyListSerialization.data(fromPropertyList: prefs, format: .binary, options: 0) {
            try? prefsData.write(to: pendingPrefs, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: pendingPrefs)
        }
    }

    /// 放弃这次导入
    static func discardPending() {
        try? FileManager.default.removeItem(at: pendingDatabase)
        try? FileManager.default.removeItem(at: pendingPrefs)
    }

    /// 在数据库打开之前调用：把当前库备份一份，再用待恢复的库替换。
    static func applyPendingIfNeeded() {
        guard hasPendingRestore else { return }

        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let current = databaseURL
        if fm.fileExists(atPath: current.path) {
            let backup = directory.appendingPathComponent("restore-backup.sqlite")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: current, to: backup)
            try? fm.removeItem(at: current)
        }

        // 旧库可能留下 -wal / -shm，不清掉会和新库对不上
        for suffix in ["-wal", "-shm"] {
            try? fm.removeItem(atPath: current.path + suffix)
        }

        do {
            try fm.moveItem(at: pendingDatabase, to: current)
        } catch {
            print("[Transfer] 恢复数据库失败：\(error)")
            return
        }

        if let prefsData = try? Data(contentsOf: pendingPrefs),
           let plist = try? PropertyListSerialization.propertyList(from: prefsData, options: [], format: nil),
           let dict = plist as? [String: Any] {
            let defaults = UserDefaults.standard
            for (key, value) in dict {
                defaults.set(value, forKey: key)
            }
        }

        try? fm.removeItem(at: pendingPrefs)
        print("[Transfer] 已切换到导入的数据库")
    }

    // MARK: 偏好

    /// 只带能影响使用体验的键，系统键和临时键不碰
    private static let preferencePrefixes = [
        "settings.", "gesture.", "feel.", "list.", "browser.",
        "video.", "memo.", "playlist.", "webdav.config", "share."
    ]

    private static func exportablePreferences() -> [String: Any] {
        let all = UserDefaults.standard.dictionaryRepresentation()
        var result: [String: Any] = [:]

        for (key, value) in all {
            guard preferencePrefixes.contains(where: { key.hasPrefix($0) }) else { continue }
            let plistSafe = value is String || value is Bool || value is Int
                || value is Double || value is Data || value is Date
                || value is [Any] || value is [String: Any]
            guard plistSafe else { continue }

            // 单项太大（比如旧版整包 JSON）就不带了，数据库里已经有
            if let data = value as? Data, data.count > 512 * 1024 { continue }
            if let text = value as? String, text.count > 200_000 { continue }

            result[key] = value
        }

        return result
    }

    // MARK: 加密

    private static func deriveKey(_ password: String, salt: Data) -> SymmetricKey {
        let base = Data(password.utf8) + salt
        var digest = Data(SHA256.hash(data: base))
        for _ in 0..<20_000 {
            digest = Data(SHA256.hash(data: digest + base))
        }
        return SymmetricKey(data: digest)
    }
}
