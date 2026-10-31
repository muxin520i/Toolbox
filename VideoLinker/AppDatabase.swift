import Foundation
import GRDB

// MARK: - 数据库
//
// v2.7 起，原先散落在 UserDefaults 里的 JSON 全部搬进一个 SQLite 库：
// 播放历史 / 观看进度 / 收藏 / 播放列表 / 用户脚本 / 脚本存储值 / 下载记录 /
// 网页历史 / 书签 / 主页快捷方式。
//
// 两个原则：
// 1. 升级只搬一次（meta 表里打标记），且搬之前先把旧的 UserDefaults 整包备份成文件；
// 2. 之后的每次写入仍然同步写一份到 UserDefaults（双写）。万一这版有问题，
//    退回旧版本依然能看到完整数据，不会丢。
//
// 数据库打不开（磁盘满、文件损坏）时不会崩：queue 为 nil，各 Store 自动回落到旧的
// UserDefaults 读写路径，功能照常，只是没有 SQL 查询能力。

enum AppDB {
    static let fileName = "videolinker.sqlite"

    /// Application Support/VideoLinker/ —— 不进 iCloud 备份冲突，也不对用户可见
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VideoLinker", isDirectory: true)
    }()

    static var fileURL: URL { directory.appendingPathComponent(fileName) }

    /// 懒加载：第一次被访问时建库、建表、跑迁移、搬旧数据
    static let queue: DatabaseQueue? = open()

    static var isReady: Bool { queue != nil }

    static var schemaVersion: String {
        guard let version = read({ db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'schema.version'") })
        else { return "未初始化" }
        return version ?? "v1"
    }

    private static func open() -> DatabaseQueue? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            var config = Configuration()
            config.label = "VideoLinker"
            config.foreignKeysEnabled = true

            let queue = try DatabaseQueue(path: fileURL.path, configuration: config)
            try migrator.migrate(queue)
            LegacyImporter.run(on: queue)
            return queue
        } catch {
            print("[AppDB] 打开数据库失败，回落到旧存储：\(error)")
            return nil
        }
    }

    // MARK: 迁移

    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        // 已经上线的库不允许因为改 schema 被清空
        migrator.eraseDatabaseOnSchemaChange = false

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS history (
                    url TEXT PRIMARY KEY NOT NULL,
                    playedAt DOUBLE NOT NULL
                );
                CREATE INDEX IF NOT EXISTS history_time ON history(playedAt DESC);

                CREATE TABLE IF NOT EXISTS resume (
                    url TEXT PRIMARY KEY NOT NULL,
                    position DOUBLE NOT NULL,
                    duration DOUBLE NOT NULL,
                    updatedAt DOUBLE NOT NULL
                );
                CREATE INDEX IF NOT EXISTS resume_time ON resume(updatedAt DESC);

                CREATE TABLE IF NOT EXISTS favorite (
                    url TEXT PRIMARY KEY NOT NULL,
                    addedAt DOUBLE NOT NULL
                );

                CREATE TABLE IF NOT EXISTS playlist (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    createdAt DOUBLE NOT NULL,
                    position INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS playlistItem (
                    id TEXT PRIMARY KEY NOT NULL,
                    playlistID TEXT NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
                    url TEXT NOT NULL,
                    title TEXT NOT NULL,
                    localPath TEXT,
                    position INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS playlistItem_list ON playlistItem(playlistID, position);
                CREATE UNIQUE INDEX IF NOT EXISTS playlistItem_url ON playlistItem(playlistID, url);

                CREATE TABLE IF NOT EXISTS script (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    matches TEXT NOT NULL,
                    code TEXT NOT NULL,
                    enabled INTEGER NOT NULL,
                    documentStart INTEGER NOT NULL,
                    updatedAt DOUBLE NOT NULL,
                    position INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS scriptValue (
                    scriptID TEXT NOT NULL,
                    key TEXT NOT NULL,
                    value TEXT NOT NULL,
                    PRIMARY KEY (scriptID, key)
                );

                CREATE TABLE IF NOT EXISTS download (
                    id TEXT PRIMARY KEY NOT NULL,
                    fileName TEXT NOT NULL,
                    source TEXT NOT NULL,
                    localPath TEXT NOT NULL,
                    createdAt DOUBLE NOT NULL
                );
                CREATE UNIQUE INDEX IF NOT EXISTS download_path ON download(localPath);

                CREATE TABLE IF NOT EXISTS webVisit (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    url TEXT NOT NULL,
                    visitedAt DOUBLE NOT NULL
                );
                CREATE INDEX IF NOT EXISTS webVisit_time ON webVisit(visitedAt DESC);

                CREATE TABLE IF NOT EXISTS bookmark (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    url TEXT NOT NULL,
                    addedAt DOUBLE NOT NULL
                );

                CREATE TABLE IF NOT EXISTS shortcut (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    url TEXT NOT NULL,
                    colorIndex INTEGER NOT NULL,
                    addedAt DOUBLE NOT NULL,
                    position INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS meta (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                """)

            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema.version', 'v1')")
        }

        return migrator
    }()

    // MARK: 读写

    /// 读失败返回 nil，调用方据此回落到旧存储
    static func read<T>(_ body: (Database) throws -> T) -> T? {
        guard let queue = AppDB.queue else { return nil }
        do {
            return try queue.read(body)
        } catch {
            print("[AppDB] 读失败：\(error)")
            return nil
        }
    }

    @discardableResult
    static func write(_ body: (Database) throws -> Void) -> Bool {
        guard let queue = AppDB.queue else { return false }
        do {
            try queue.write(body)
            return true
        } catch {
            print("[AppDB] 写失败：\(error)")
            return false
        }
    }

    static func count(_ table: String) -> Int {
        read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 } ?? 0
    }

    // MARK: meta

    static func meta(_ key: String) -> String? {
        read { db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) } ?? nil
    }

    static func setMeta(_ key: String, _ value: String) {
        write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", arguments: [key, value])
        }
    }

    // MARK: 诊断

    static var sizeText: String {
        let fm = FileManager.default
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let path = fileURL.path + suffix
            if let attr = try? fm.attributesOfItem(atPath: path), let size = attr[.size] as? Int64 {
                total += size
            }
        }
        guard total > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    /// 设置页「存储」卡片要显示的一套数字
    struct Report {
        var ready: Bool
        var schema: String
        var size: String
        var path: String
        var counts: [(name: String, count: Int)]
        /// 旧存储里的条数，用来跟库里对一下
        var legacy: [(name: String, count: Int)]

        var mismatch: [String] {
            var result: [String] = []
            for row in counts {
                guard let old = legacy.first(where: { $0.name == row.name }) else { continue }
                // 旧存储有上限裁剪、去重等规则，只有库比旧存储少才算异常
                if row.count < old.count {
                    result.append("\(row.name)：库里 \(row.count) 条，旧存储 \(old.count) 条")
                }
            }
            return result
        }
    }

    static func report() -> Report {
        let counts: [(name: String, count: Int)] = [
            (name: "播放历史", count: count("history")),
            (name: "观看进度", count: count("resume")),
            (name: "收藏", count: count("favorite")),
            (name: "播放列表", count: count("playlist")),
            (name: "列表条目", count: count("playlistItem")),
            (name: "用户脚本", count: count("script")),
            (name: "下载记录", count: count("download")),
            (name: "网页历史", count: count("webVisit")),
            (name: "书签", count: count("bookmark")),
            (name: "快捷方式", count: count("shortcut"))
        ]
        return Report(
            ready: isReady,
            schema: schemaVersion,
            size: sizeText,
            path: fileURL.path,
            counts: counts,
            legacy: LegacyImporter.legacyCounts()
        )
    }
}

// MARK: - 旧数据搬迁

enum LegacyImporter {
    /// 老版本 UserDefaults 里的键，搬迁完只读不写（写入仍由各 Store 双写）
    static let historyKey = "video.history.v1"
    static let resumeKey = "video.resume.v1"
    static let favoriteKey = "video.favorites.v1"
    static let playlistKey = "video.playlists.v1"
    static let scriptKey = "userscripts.v1"
    static let scriptValueKey = "userscript.values.v1"
    static let downloadKey = "browser.downloads.v1"
    static let visitKey = "browser.history.v1"
    static let bookmarkKey = "browser.bookmarks.v1"
    static let shortcutKey = "browser.shortcuts.v1"

    private static let flagKey = "legacy.import.v1"

    private struct LegacyDownload: Codable {
        var fileName: String
        var source: String
        var localPath: String
        var date: Date
    }

    static func run(on queue: DatabaseQueue) {
        let done = (try? queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [flagKey])
        }) ?? nil
        guard done != "1" else { return }

        backupDefaults()

        let defaults = UserDefaults.standard
        let history = decode([HistoryItem].self, from: defaults.data(forKey: historyKey)) ?? []
        let resume = decode([String: ResumeEntry].self, from: defaults.data(forKey: resumeKey)) ?? [:]
        let favorites = defaults.stringArray(forKey: favoriteKey) ?? []
        let playlists = decode([Playlist].self, from: defaults.data(forKey: playlistKey)) ?? []
        let scripts = decode([Userscript].self, from: defaults.data(forKey: scriptKey)) ?? []
        let downloads = decode([LegacyDownload].self, from: defaults.data(forKey: downloadKey)) ?? []
        let visits = decode([WebVisit].self, from: defaults.data(forKey: visitKey)) ?? []
        let bookmarks = decode([Bookmark].self, from: defaults.data(forKey: bookmarkKey)) ?? []
        let shortcuts = decode([Shortcut].self, from: defaults.data(forKey: shortcutKey)) ?? []
        let scriptValues: [String: [String: Any]] = {
            guard let data = defaults.data(forKey: scriptValueKey),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let map = object as? [String: [String: Any]] else { return [:] }
            return map
        }()

        do {
            try queue.write { db in
                let hasHistory = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM history") ?? 0) > 0
                if !hasHistory {
                    for item in history {
                        try db.execute(
                            sql: "INSERT OR REPLACE INTO history (url, playedAt) VALUES (?, ?)",
                            arguments: [item.url, item.date.timeIntervalSince1970]
                        )
                    }
                }

                let hasResume = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM resume") ?? 0) > 0
                if !hasResume {
                    for (url, entry) in resume {
                        try db.execute(
                            sql: "INSERT OR REPLACE INTO resume (url, position, duration, updatedAt) VALUES (?, ?, ?, ?)",
                            arguments: [url, entry.position, entry.duration, entry.updated.timeIntervalSince1970]
                        )
                    }
                }

                let hasFavorite = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM favorite") ?? 0) > 0
                if !hasFavorite {
                    for url in favorites {
                        try db.execute(
                            sql: "INSERT OR REPLACE INTO favorite (url, addedAt) VALUES (?, ?)",
                            arguments: [url, Date().timeIntervalSince1970]
                        )
                    }
                }

                let hasPlaylist = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist") ?? 0) > 0
                if !hasPlaylist {
                    for (index, playlist) in playlists.enumerated() {
                        try db.execute(
                            sql: "INSERT OR REPLACE INTO playlist (id, name, createdAt, position) VALUES (?, ?, ?, ?)",
                            arguments: [playlist.id.uuidString, playlist.name, playlist.createdAt.timeIntervalSince1970, index]
                        )
                        for (order, item) in playlist.items.enumerated() {
                            try db.execute(
                                sql: """
                                    INSERT OR REPLACE INTO playlistItem
                                    (id, playlistID, url, title, localPath, position) VALUES (?, ?, ?, ?, ?, ?)
                                    """,
                                arguments: [item.id.uuidString, playlist.id.uuidString, item.url, item.title, item.localPath ?? "", order]
                            )
                        }
                    }
                }

                let hasScript = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM script") ?? 0) > 0
                if !hasScript {
                    for (index, script) in scripts.enumerated() {
                        let matches = encode(script.matches) ?? "[]"
                        try db.execute(
                            sql: """
                                INSERT OR REPLACE INTO script
                                (id, name, matches, code, enabled, documentStart, updatedAt, position)
                                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                                """,
                            arguments: [
                                script.id.uuidString, script.name, matches, script.code,
                                script.enabled ? 1 : 0, script.documentStart ? 1 : 0,
                                script.updatedAt.timeIntervalSince1970, index
                            ]
                        )
                    }
                }

                let hasDownload = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM download") ?? 0) > 0
                if !hasDownload {
                    for record in downloads {
                        try db.execute(
                            sql: "INSERT OR REPLACE INTO download (id, fileName, source, localPath, createdAt) VALUES (?, ?, ?, ?, ?)",
                            arguments: [
                                UUID().uuidString, record.fileName, record.source,
                                record.localPath, record.date.timeIntervalSince1970
                            ]
                        )
                    }
                }

                let hasVisit = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM webVisit") ?? 0) > 0
                if !hasVisit {
                    for visit in visits {
                        try db.execute(
                            sql: "INSERT OR REPLACE INTO webVisit (id, title, url, visitedAt) VALUES (?, ?, ?, ?)",
                            arguments: [visit.id.uuidString, visit.title, visit.url, visit.date.timeIntervalSince1970]
                        )
                    }
                }

                let hasBookmark = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark") ?? 0) > 0
                if !hasBookmark {
                    for bookmark in bookmarks {
                        try db.execute(
                            sql: "INSERT OR REPLACE INTO bookmark (id, title, url, addedAt) VALUES (?, ?, ?, ?)",
                            arguments: [bookmark.id.uuidString, bookmark.title, bookmark.url, bookmark.addedAt.timeIntervalSince1970]
                        )
                    }
                }

                let hasShortcut = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM shortcut") ?? 0) > 0
                if !hasShortcut {
                    for (order, shortcut) in shortcuts.enumerated() {
                        try db.execute(
                            sql: """
                                INSERT OR REPLACE INTO shortcut (id, title, url, colorIndex, addedAt, position)
                                VALUES (?, ?, ?, ?, ?, ?)
                                """,
                            arguments: [
                                shortcut.id.uuidString, shortcut.title, shortcut.url,
                                shortcut.colorIndex, shortcut.addedAt.timeIntervalSince1970, order
                            ]
                        )
                    }
                }

                let hasValue = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scriptValue") ?? 0) > 0
                if !hasValue {
                    for (scope, values) in scriptValues {
                        for (key, raw) in values {
                            guard let text = jsonString(raw) else { continue }
                            try db.execute(
                                sql: "INSERT OR REPLACE INTO scriptValue (scriptID, key, value) VALUES (?, ?, ?)",
                                arguments: [scope, key, text]
                            )
                        }
                    }
                }

                try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", arguments: [flagKey, "1"])
            }
            print("[AppDB] 旧数据搬迁完成：\(history.count) 条历史 / \(playlists.count) 个列表 / \(scripts.count) 个脚本")
        } catch {
            print("[AppDB] 旧数据搬迁失败：\(error)")
        }
    }

    /// 搬之前把整个 UserDefaults 里我们关心的键原样存一份到文件，出问题能查
    private static func backupDefaults() {
        let defaults = UserDefaults.standard
        let keys = [
            historyKey, resumeKey, favoriteKey, playlistKey, scriptKey,
            scriptValueKey, downloadKey, visitKey, bookmarkKey, shortcutKey
        ]
        var dump: [String: String] = [:]
        for key in keys {
            guard let data = defaults.data(forKey: key) else { continue }
            dump[key] = data.base64EncodedString()
        }
        guard !dump.isEmpty else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "legacy-backup-\(formatter.string(from: Date())).json"
        let url = AppDB.directory.appendingPathComponent(name)
        if let data = try? JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted]) {
            try? data.write(to: url)
        }
    }

    // MARK: 诊断用

    /// 旧存储里每类数据有多少条，用来和数据库对账
    static func legacyCounts() -> [(name: String, count: Int)] {
        let defaults = UserDefaults.standard
        let history = decode([HistoryItem].self, from: defaults.data(forKey: historyKey))?.count ?? 0
        let resume = decode([String: ResumeEntry].self, from: defaults.data(forKey: resumeKey))?.count ?? 0
        let favorites = defaults.stringArray(forKey: favoriteKey)?.count ?? 0
        let playlists = decode([Playlist].self, from: defaults.data(forKey: playlistKey)) ?? []
        let scripts = decode([Userscript].self, from: defaults.data(forKey: scriptKey))?.count ?? 0
        let downloads = decode([LegacyDownload].self, from: defaults.data(forKey: downloadKey))?.count ?? 0
        let visits = decode([WebVisit].self, from: defaults.data(forKey: visitKey))?.count ?? 0
        let bookmarks = decode([Bookmark].self, from: defaults.data(forKey: bookmarkKey))?.count ?? 0
        let shortcuts = decode([Shortcut].self, from: defaults.data(forKey: shortcutKey))?.count ?? 0

        return [
            (name: "播放历史", count: history),
            (name: "观看进度", count: resume),
            (name: "收藏", count: favorites),
            (name: "播放列表", count: playlists.count),
            (name: "列表条目", count: playlists.reduce(0) { $0 + $1.items.count }),
            (name: "用户脚本", count: scripts),
            (name: "下载记录", count: downloads),
            (name: "网页历史", count: visits),
            (name: "书签", count: bookmarks),
            (name: "快捷方式", count: shortcuts)
        ]
    }

    // MARK: 小工具

    static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func jsonString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
