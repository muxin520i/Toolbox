import Foundation
import CryptoKit
import GRDB
import Security
import WebKit
import Compression

// MARK: - 换机备份
//
// 换手机、重装系统时，列表、进度、备忘、书签、脚本都在 SQLite 里，
// 内置浏览器的登录状态在 WebKit 的网站数据里。这里把两者一起打成一个包，
// 新机导入后下次启动自动换上。
//
// 包结构（v2）：魔数 8 字节 + 是否加密 1 字节 + [盐 16 字节] + 正文。
//   - 加密：正文是 AES-GCM 密文，密码用 SHA-256 迭代派生，不存明文
//   - 不加密：正文就是 plist，方便不带密码直接换机
// 旧版（VLMOVE01）只有加密格式，仍然可以导入。

enum MoveError: LocalizedError {
    case noDatabase
    case badFile
    case wrongPassword
    case damaged
    case emptyPassword
    case shortPassword
    case noSpace

    var errorDescription: String? {
        switch self {
        case .noDatabase: return "还没有可打包的数据"
        case .badFile: return "这个文件不是工具箱的备份包"
        case .wrongPassword: return "密码不对，或者文件被改过"
        case .damaged: return "包内容不完整，重新导出一份试试"
        case .emptyPassword: return "这个备份包设了密码，需要输入密码才能打开"
        case .shortPassword: return "密码至少 6 位"
        case .noSpace: return "存储空间不够，先清理一些文件再试"
        }
    }
}

enum TransferStore {
    /// 旧版魔数：固定加密
    static let legacyMagic = Data("VLMOVE01".utf8)
    /// 新版魔数：第 9 字节标记是否加密
    static let magic = Data("VLBACK02".utf8)
    static let fileExtension = "vlbak"
    static let legacyFileExtension = "vlmove"
    static let minPasswordLength = 6

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VideoLinker", isDirectory: true)
    }

    static var databaseURL: URL {
        directory.appendingPathComponent(AppDB.fileName)
    }

    /// 启动时优先检查这个文件，有就说明上次导入还没生效
    static var pendingDatabase: URL {
        directory.appendingPathComponent("pending-restore.sqlite")
    }

    static var pendingPrefs: URL {
        directory.appendingPathComponent("pending-restore.plist")
    }

    static var pendingCookies: URL {
        directory.appendingPathComponent("pending-cookies.plist")
    }

    static var hasPendingRestore: Bool {
        FileManager.default.fileExists(atPath: pendingDatabase.path)
    }

    /// 备份包落在文稿目录下：App 开了文件共享，这里对应
    /// 「文件」App → 我的 iPhone → 工具箱 → 工具箱备份，用户能直接看到
    static var exportsDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("工具箱备份", isDirectory: true)
    }

    /// 用户导出时用的默认文件名
    static var suggestedFileName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "工具箱备份-\(formatter.string(from: Date())).\(fileExtension)"
    }

    // MARK: 导出

    struct PackageInfo {
        var siteCount: Int = 0
        var webFiles: Int = 0
        var webBytes: Int = 0
        var encrypted: Bool = false
    }

    struct PackageResult {
        let url: URL
        let info: PackageInfo

        var summaryText: String {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let text = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            if info.siteCount > 0 {
                return "\(text) · 含 \(info.siteCount) 个网站数据"
            }
            return text
        }
    }

    /// 打一个包。数据库用 VACUUM INTO 取一致快照，避免读到写了一半的页。
    /// 密码传空字符串表示不加密。
    static func makePackage(
        password: String,
        includePreferences: Bool = true,
        includeWebData: Bool = true
    ) async throws -> (data: Data, info: PackageInfo) {
        if !password.isEmpty && password.count < minPasswordLength {
            throw MoveError.shortPassword
        }
        guard AppDB.isReady else { throw MoveError.noDatabase }

        let snapshot = try databaseSnapshot()
        defer { try? FileManager.default.removeItem(at: snapshot) }

        guard let dbData = try? Data(contentsOf: snapshot), !dbData.isEmpty else {
            throw MoveError.noDatabase
        }

        var info = PackageInfo(encrypted: !password.isEmpty)
        var webArchive: URL?
        defer {
            if let webArchive { try? FileManager.default.removeItem(at: webArchive) }
        }

        var payload: [String: Any] = [
            "version": 2,
            "createdAt": Date(),
            "database": dbData
        ]
        if includePreferences {
            payload["preferences"] = exportablePreferences()
        }

        if includeWebData {
            // 站点数只看磁盘目录与 Cookie 域名，不为一个数字去拉起 WebKit
            let diskSites = WebDataBackup.siteCountOnDisk()

            // WebKit 的落盘是异步的，先跟 cookie 库对一次话，再留一点时间让它写完
            CrashLog.mark("备份：读取登录 Cookie")
            let cookies = await WebDataBackup.collectCookies()
            try? await Task.sleep(nanoseconds: 350_000_000)

            if !cookies.isEmpty {
                payload["cookies"] = cookies
            }
            let cookieSites = Set(cookies.compactMap { $0["domain"] as? String }).count
            info.siteCount = max(diskSites, cookieSites)

            CrashLog.mark("备份：收集网站文件")
            if let collected = WebDataBackup.collect() {
                webArchive = collected.url
                if let blob = WebDataBackup.readSnapshot(collected) {
                    payload["webData"] = blob
                    payload["webDataFiles"] = collected.fileCount
                    payload["webDataBytes"] = collected.originalBytes
                    info.webFiles = collected.fileCount
                    info.webBytes = collected.originalBytes
                }
            }
            CrashLog.mark("备份：网站数据 \(info.webFiles) 个文件")
        }

        let plain = try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .binary,
            options: 0
        )

        guard !password.isEmpty else {
            return (magic + Data([0]) + plain, info)
        }

        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 16, buffer.baseAddress!)
        }

        let key = deriveKey(password, salt: salt)
        let sealed = try AES.GCM.seal(plain, using: key)
        guard let combined = sealed.combined else { throw MoveError.damaged }

        return (magic + Data([1]) + salt + combined, info)
    }

    /// 写到「文件」App 可见的目录，返回地址
    static func writePackage(
        password: String,
        includeWebData: Bool = true
    ) async throws -> PackageResult {
        let built = try await makePackage(password: password, includeWebData: includeWebData)

        let fm = FileManager.default
        let dir = exportsDirectory
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw MoveError.badFile
        }

        // 空间不够时提前说清楚，别写一半失败
        if let free = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
           free < Int64(built.data.count) + 32 * 1024 * 1024 {
            throw MoveError.noSpace
        }

        let url = dir.appendingPathComponent(suggestedFileName)
        try? fm.removeItem(at: url)
        try built.data.write(to: url, options: .atomic)

        // 备份包本身没必要再进 iCloud 备份，避免占两份空间
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)

        pruneOldExports(keeping: 5)
        return PackageResult(url: url, info: built.info)
    }

    /// 只留最近几份，避免反复导出把设备撑满
    private static func pruneOldExports(keeping limit: Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: exportsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let packages = items
            .filter { $0.pathExtension == fileExtension || $0.pathExtension == legacyFileExtension }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l > r
            }

        guard packages.count > limit else { return }
        for url in packages.dropFirst(limit) {
            try? fm.removeItem(at: url)
        }
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

    /// 只读文件头，判断这个包要不要密码
    static func isEncrypted(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: magic.count + 1),
              head.count > magic.count
        else { return true }

        if head.prefix(magic.count) == magic {
            return head[magic.count] == 1
        }
        // 旧包一定是加密的
        return true
    }

    /// 校验密码、解包，并把数据库、偏好、网站数据写成「待恢复」。
    /// 真正替换在下次启动时做。
    static func stageImport(from url: URL, password: String) throws {
        guard let data = try? Data(contentsOf: url) else { throw MoveError.badFile }
        try stageImport(data: data, password: password)
    }

    static func stageImport(data: Data, password: String) throws {
        let payload = try decode(data: data, password: password)

        guard let dbData = payload["database"] as? Data, !dbData.isEmpty else {
            throw MoveError.damaged
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: pendingDatabase)
        try dbData.write(to: pendingDatabase, options: .atomic)

        if let prefs = payload["preferences"] as? [String: Any],
           let prefsData = try? PropertyListSerialization.data(fromPropertyList: prefs, format: .binary, options: 0) {
            try? prefsData.write(to: pendingPrefs, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: pendingPrefs)
        }

        // 网站数据：Cookie 走接口回写，其余文件解到 pending-webdata
        if let cookies = payload["cookies"] as? [[String: Any]], !cookies.isEmpty,
           let cookieData = try? PropertyListSerialization.data(fromPropertyList: cookies, format: .binary, options: 0) {
            try? cookieData.write(to: pendingCookies, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: pendingCookies)
        }

        if let webData = payload["webData"] as? Data {
            WebDataBackup.stage(webData)
        } else {
            WebDataBackup.discardPending()
        }
    }

    /// 解出 payload，兼容新旧格式
    private static func decode(data: Data, password: String) throws -> [String: Any] {
        guard data.count > magic.count + 2 else { throw MoveError.badFile }

        if data.prefix(magic.count) == magic {
            let flag = data[magic.count]

            if flag == 0 {
                let plain = data.subdata(in: (magic.count + 1)..<data.count)
                return try parsePayload(plain)
            }

            guard flag == 1 else { throw MoveError.badFile }
            if password.isEmpty { throw MoveError.emptyPassword }
            guard password.count >= minPasswordLength else { throw MoveError.shortPassword }

            let saltStart = magic.count + 1
            guard data.count > saltStart + 16 + 16 else { throw MoveError.badFile }
            let salt = data.subdata(in: saltStart..<(saltStart + 16))
            let body = data.subdata(in: (saltStart + 16)..<data.count)

            let plain: Data
            do {
                let box = try AES.GCM.SealedBox(combined: body)
                plain = try AES.GCM.open(box, using: deriveKey(password, salt: salt))
            } catch {
                throw MoveError.wrongPassword
            }
            return try parsePayload(plain)
        }

        if data.prefix(legacyMagic.count) == legacyMagic {
            if password.isEmpty { throw MoveError.emptyPassword }
            guard password.count >= minPasswordLength else { throw MoveError.shortPassword }

            let saltStart = legacyMagic.count
            guard data.count > saltStart + 16 + 16 else { throw MoveError.badFile }
            let salt = data.subdata(in: saltStart..<(saltStart + 16))
            let body = data.subdata(in: (saltStart + 16)..<data.count)

            let plain: Data
            do {
                let box = try AES.GCM.SealedBox(combined: body)
                plain = try AES.GCM.open(box, using: deriveKey(password, salt: salt))
            } catch {
                throw MoveError.wrongPassword
            }
            return try parsePayload(plain)
        }

        throw MoveError.badFile
    }

    private static func parsePayload(_ data: Data) throws -> [String: Any] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let payload = plist as? [String: Any]
        else { throw MoveError.damaged }
        return payload
    }

    /// 放弃这次导入
    static func discardPending() {
        try? FileManager.default.removeItem(at: pendingDatabase)
        try? FileManager.default.removeItem(at: pendingPrefs)
        try? FileManager.default.removeItem(at: pendingCookies)
        WebDataBackup.discardPending()
    }

    // MARK: 应用

    /// 必须在任何 WKWebView 建起来之前调用：网站数据要换文件，
    /// 等 WebKit 起来之后再动目录会打架。
    static func applyPendingWebDataIfNeeded() {
        WebDataBackup.applyPendingIfNeeded()
    }

    /// 在数据库打开之前调用：把当前库备份一份，再用待恢复的库替换。
    static func applyPendingIfNeeded() {
        // 兜底：万一启动早期没来得及换，这里再试一次
        WebDataBackup.applyPendingIfNeeded()

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

        // Cookie 要等 WebKit 可用，放到主线程稍微延后一点
        if fm.fileExists(atPath: pendingCookies.path) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                Task { await restorePendingCookiesIfNeeded() }
            }
        }
    }

    /// 把包里带的 Cookie 写回 WebKit。文件级恢复可能因为目录结构差异失效，
    /// 这一步是登录状态的主要保障。
    static func restorePendingCookiesIfNeeded() async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pendingCookies.path),
              let data = try? Data(contentsOf: pendingCookies),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let list = plist as? [[String: Any]]
        else { return }

        await WebDataBackup.restoreCookies(list)
        try? fm.removeItem(at: pendingCookies)
        print("[Transfer] 已回写 \(list.count) 条网站 Cookie")
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

// MARK: - 网站数据
//
// WebKit 把 Cookie、LocalStorage、IndexedDB 都放在 Library/WebKit 下，
// 缓存（NetworkCache / CacheStorage / Cache.db）体积大又没有迁移价值，打包时跳过。
// 文件按相对路径存进一个自定义归档，恢复时整目录换掉；Cookie 另外用
// WKHTTPCookieStore 回写一遍，双保险。

enum WebDataBackup {
    static let archiveMagic = Data("VLWD01".utf8)
    /// 总量上限。登录态真正靠的是 Cookie 和小体积 LocalStorage，
    /// 定得越小越安全：整个归档最后要进 plist、再参与加密，都是整块内存操作。
    static let maxBytes = 64 * 1024 * 1024
    /// 单文件上限。IndexedDB 里会有几十上百 MB 的 blob，一次性读进来就是闪退。
    static let maxFileBytes = 12 * 1024 * 1024

    private static let skippedNames: Set<String> = [
        "Cache.db", "Cache.db-shm", "Cache.db-wal",
        "NetworkCache", "CacheStorage", "WebKitCache", "MediaCache",
        "ResourceLoadStatistics", "AlternativeServices",
        ".DS_Store"
    ]

    static var libraryDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    }

    static var webKitDirectory: URL {
        libraryDirectory.appendingPathComponent("WebKit", isDirectory: true)
    }

    static var cookiesDirectory: URL {
        libraryDirectory.appendingPathComponent("Cookies", isDirectory: true)
    }

    /// 导入前自动留的旧网站数据
    static var backupDirectory: URL {
        libraryDirectory.appendingPathComponent("WebKit.restore-backup", isDirectory: true)
    }

    static var pendingDirectory: URL {
        TransferStore.directory.appendingPathComponent("pending-webdata", isDirectory: true)
    }

    static var hasPending: Bool {
        FileManager.default.fileExists(atPath: pendingDirectory.path)
    }

    // MARK: 站点统计

    /// 直接数磁盘上的站点目录，不碰 WebKit。
    /// 备份页一打开就要显示这个数字，用 `WKWebsiteDataStore` 去问会拉起网络进程，
    /// 在还没建过 WebView 的场景里没有意义，也可能把界面卡住。
    static func siteCountOnDisk() -> Int {
        let fm = FileManager.default
        let base = webKitDirectory.appendingPathComponent("WebsiteData", isDirectory: true)
        var hosts = Set<String>()

        for name in ["LocalStorage", "IndexedDB", "ServiceWorkers", "Databases"] {
            let dir = base.appendingPathComponent(name, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for item in items where !item.hasPrefix(".") {
                hosts.insert(item)
            }
        }

        // 老系统把本地存储直接放在 WebKit/LocalStorage 下
        if hosts.isEmpty {
            let legacy = webKitDirectory.appendingPathComponent("LocalStorage", isDirectory: true)
            if let items = try? fm.contentsOfDirectory(atPath: legacy.path) {
                for item in items where !item.hasPrefix(".") {
                    hosts.insert(item)
                }
            }
        }

        return hosts.count
    }

    // MARK: Cookie

    /// 读 Cookie。`WKWebsiteDataStore` 属于 WebKit 的 UI 侧对象，要在主线程访问；
    /// 后台线程直接拿可能崩，且不会留下异常日志。
    static func collectCookies() async -> [[String: Any]] {
        let box = CookieBox()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeGuard()
            Task { @MainActor in
                WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                    let list: [[String: Any]] = cookies.compactMap { cookie in
                        guard !cookie.name.isEmpty, !cookie.domain.isEmpty else { return nil }
                        var dict: [String: Any] = [
                            "name": cookie.name,
                            "value": cookie.value,
                            "domain": cookie.domain,
                            "path": cookie.path.isEmpty ? "/" : cookie.path,
                            "secure": cookie.isSecure
                        ]
                        if let expires = cookie.expiresDate {
                            dict["expires"] = expires.timeIntervalSince1970
                        }
                        return dict
                    }
                    box.set(list)
                    once.once { continuation.resume() }
                }
            }
            // 回调万一不来，也不要让打包界面一直转圈
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                once.once { continuation.resume() }
            }
        }
        return box.list
    }

    /// 跨线程带回 Cookie 结果
    private final class CookieBox: @unchecked Sendable {
        private var value: [[String: Any]] = []
        private let lock = NSLock()

        var list: [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ newValue: [[String: Any]]) {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    /// 保证 continuation 只恢复一次，重复 resume 会直接崩
    private final class ResumeGuard: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()

        func once(_ body: () -> Void) {
            lock.lock()
            if done {
                lock.unlock()
                return
            }
            done = true
            lock.unlock()
            body()
        }
    }

    static func restoreCookies(_ list: [[String: Any]]) async {
        let store = WKWebsiteDataStore.default().httpCookieStore

        for dict in list {
            guard let name = dict["name"] as? String, !name.isEmpty,
                  let value = dict["value"] as? String,
                  let domain = dict["domain"] as? String, !domain.isEmpty
            else { continue }

            var props: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: (dict["path"] as? String) ?? "/",
                .secure: (dict["secure"] as? Bool) == true ? "TRUE" : "FALSE"
            ]
            if let stamp = dict["expires"] as? Double, stamp > 0 {
                props[.expires] = Date(timeIntervalSince1970: stamp)
            }

            guard let cookie = HTTPCookie(properties: props) else { continue }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.setCookie(cookie) { continuation.resume() }
            }
        }
    }

    // MARK: 打包

    struct Snapshot {
        /// 归档写在临时文件里，不再整块攒在内存中
        let url: URL
        let fileCount: Int
        let originalBytes: Int
    }

    /// 逐条读、逐条压缩、逐条写盘。
    /// 以前是把所有内容 append 进一个 Data，碰到大 IndexedDB 会把内存顶穿，
    /// 系统直接杀进程，表现就是点一下闪退、也留不下崩溃日志。
    static func collect() -> Snapshot? {
        let fm = FileManager.default
        let archive = fm.temporaryDirectory
            .appendingPathComponent("vl-webdata-\(UUID().uuidString).bin")
        guard fm.createFile(atPath: archive.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: archive)
        else { return nil }

        var finished = false
        defer {
            try? handle.close()
            if !finished { try? fm.removeItem(at: archive) }
        }

        do {
            try handle.write(contentsOf: archiveMagic)
            try handle.write(contentsOf: u32Data(0))   // 文件数占位
        } catch {
            return nil
        }

        var count = 0
        var total = 0
        let roots: [(URL, String)] = [(webKitDirectory, "WebKit"), (cookiesDirectory, "Cookies")]

        outer: for (root, prefix) in roots {
            guard fm.fileExists(atPath: root.path),
                  let enumerator = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
                    options: []
                  )
            else { continue }

            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
                )
                let isDirectory = values?.isDirectory ?? false

                if skippedNames.contains(name) {
                    if isDirectory { enumerator.skipDescendants() }
                    continue
                }
                if isDirectory { continue }
                // 只收普通文件，避免读到管道、套接字这类东西时卡死
                guard values?.isRegularFile == true else { continue }
                guard let size = values?.fileSize, size > 0, size <= maxFileBytes else { continue }
                if total + size > maxBytes { break outer }
                guard let raw = try? Data(contentsOf: url), !raw.isEmpty else { continue }

                var relative = prefix
                if url.path.hasPrefix(root.path) {
                    relative += String(url.path.dropFirst(root.path.count))
                } else {
                    relative += "/" + name
                }

                let packed = lzfseCompress(raw)
                let flag: UInt8 = packed != nil ? 1 : 0
                let payload = packed ?? raw
                let pathData = Data(relative.utf8)
                guard payload.count <= Int(UInt32.max),
                      pathData.count > 0, pathData.count <= Int(UInt16.max)
                else { continue }

                var head = Data()
                appendU16(UInt16(pathData.count), to: &head)
                head.append(pathData)
                appendU64(UInt64(raw.count), to: &head)
                head.append(flag)
                appendU32(UInt32(payload.count), to: &head)

                do {
                    try handle.write(contentsOf: head)
                    try handle.write(contentsOf: payload)
                } catch {
                    break outer
                }

                count += 1
                total += raw.count
                // 每个文件读完立刻释放，内存峰值只跟单个文件有关
            }
        }

        guard count > 0 else { return nil }

        // 回填文件数
        do {
            let end = try handle.offset()
            try handle.seek(toOffset: 6)
            try handle.write(contentsOf: u32Data(UInt32(count)))
            try handle.seek(toOffset: end)
        } catch {
            return nil
        }

        finished = true
        return Snapshot(url: archive, fileCount: count, originalBytes: total)
    }

    /// 归档文件有多大就映射多大，序列化时由 plist 自己复制，不必先整块读进来
    static func readSnapshot(_ snapshot: Snapshot) -> Data? {
        try? Data(contentsOf: snapshot.url, options: .mappedIfSafe)
    }

    private static func u32Data(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }

    // MARK: 还原

    /// 把归档解到 pending-webdata，启动时再整体换目录
    @discardableResult
    static func stage(_ archive: Data) -> Int {
        guard archive.count >= 10, archive.prefix(archiveMagic.count) == archiveMagic else { return 0 }
        guard let count = readU32(archive, 6), count > 0 else { return 0 }

        let fm = FileManager.default
        try? fm.removeItem(at: pendingDirectory)
        do {
            try fm.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        } catch {
            return 0
        }

        var offset = 10
        var written = 0

        for _ in 0..<Int(count) {
            guard let pathLength = readU16(archive, offset) else { break }
            offset += 2
            guard offset + Int(pathLength) <= archive.count else { break }
            guard let pathData = String(data: archive.subdata(in: offset..<(offset + Int(pathLength))), encoding: .utf8)
            else { break }
            offset += Int(pathLength)

            guard let originalSize = readU64(archive, offset) else { break }
            offset += 8
            guard offset < archive.count else { break }
            let flag = archive[offset]
            offset += 1
            guard let payloadSize = readU32(archive, offset) else { break }
            offset += 4
            guard offset + Int(payloadSize) <= archive.count else { break }

            let payload = archive.subdata(in: offset..<(offset + Int(payloadSize)))
            offset += Int(payloadSize)

            guard !pathData.contains(".."), pathData != "/", !pathData.isEmpty else { continue }
            let destination = pendingDirectory.appendingPathComponent(pathData)
            guard destination.path.hasPrefix(pendingDirectory.path) else { continue }

            let bytes: Data?
            if flag == 1 {
                bytes = originalSize > 0 && originalSize <= UInt64(maxBytes)
                    ? lzfseDecompress(payload, size: Int(originalSize))
                    : nil
            } else {
                bytes = payload
            }
            guard let bytes else { continue }

            try? fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if (try? bytes.write(to: destination, options: .atomic)) != nil {
                written += 1
            }
        }

        return written
    }

    /// 启动最早期调用：把旧目录备份一份，再把 pending 整体换上去
    static func applyPendingIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pendingDirectory.path) else { return }

        // 先留旧数据，出问题还能手工退回去
        if fm.fileExists(atPath: webKitDirectory.path) {
            try? fm.removeItem(at: backupDirectory)
            do {
                try fm.moveItem(at: webKitDirectory, to: backupDirectory)
            } catch {
                // 旧目录挪不动（被系统占着），这次先放弃，包留在 pending 里下次再试
                print("[Transfer] 旧网站数据挪不动：\(error)")
                return
            }
        }

        var webKitApplied = false
        for name in ["WebKit", "Cookies"] {
            let source = pendingDirectory.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = libraryDirectory.appendingPathComponent(name, isDirectory: true)
            try? fm.removeItem(at: destination)
            do {
                try fm.moveItem(at: source, to: destination)
                if name == "WebKit" { webKitApplied = true }
            } catch {
                print("[Transfer] 换上 \(name) 失败：\(error)")
            }
        }

        // 主目录没换成功就保留 pending，别把唯一一份数据删了
        if webKitApplied || !fm.fileExists(atPath: pendingDirectory.appendingPathComponent("WebKit").path) {
            try? fm.removeItem(at: pendingDirectory)
            print("[Transfer] 已换上导入的网站数据")
        }
    }

    static func discardPending() {
        try? FileManager.default.removeItem(at: pendingDirectory)
    }

    // MARK: 压缩

    private static func lzfseCompress(_ data: Data) -> Data? {
        guard data.count > 512 else { return nil }
        let capacity = data.count + 256
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                      let src = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_encode_buffer(dst, capacity, src, data.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written > 0, written < data.count else { return nil }
        output.removeSubrange(written..<output.count)
        return output
    }

    private static func lzfseDecompress(_ data: Data, size: Int) -> Data? {
        guard size > 0 else { return nil }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                      let src = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(dst, size, src, data.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written == size else { return nil }
        return output
    }

    // MARK: 字节序

    private static func appendU16(_ value: UInt16, to data: inout Data) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendU32(_ value: UInt32, to data: inout Data) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendU64(_ value: UInt64, to data: inout Data) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return data.subdata(in: offset..<(offset + 2))
            .withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
            .littleEndian
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data.subdata(in: offset..<(offset + 4))
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            .littleEndian
    }

    private static func readU64(_ data: Data, _ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        return data.subdata(in: offset..<(offset + 8))
            .withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            .littleEndian
    }
}
