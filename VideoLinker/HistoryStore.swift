import Foundation
import GRDB

/// 一条播放历史
struct HistoryItem: Codable, Identifiable, Hashable {
    var id: String { url }
    let url: String
    let date: Date

    var displayName: String {
        if let u = URL(string: url) {
            let file = u.lastPathComponent
            if !file.isEmpty, file != "/" {
                return file.removingPercentEncoding ?? file
            }
            if let host = u.host {
                return host
            }
        }
        return url
    }

    var subtitle: String {
        guard let u = URL(string: url), let host = u.host else { return url }
        let path = u.path
        return path.isEmpty || path == "/" ? host : host + path
    }
}

/// 历史记录存储：SQLite 为主，UserDefaults 双写留退路（最多保留 30 条）
enum HistoryStore {
    private static let key = "video.history.v1"
    private static let limit = 30

    private struct Row: Codable, FetchableRecord {
        var url: String
        var playedAt: Double
    }

    static func load() -> [HistoryItem] {
        if let rows = AppDB.read({ db in
            try Row.fetchAll(
                db,
                sql: "SELECT url, playedAt FROM history ORDER BY playedAt DESC LIMIT ?",
                arguments: [limit]
            )
        }) {
            return rows.map { HistoryItem(url: $0.url, date: Date(timeIntervalSince1970: $0.playedAt)) }
        }
        return legacyLoad()
    }

    static func save(_ items: [HistoryItem]) {
        let trimmed = Array(items.prefix(limit))

        AppDB.write { db in
            try db.execute(sql: "DELETE FROM history")
            for item in trimmed {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO history (url, playedAt) VALUES (?, ?)",
                    arguments: [item.url, item.date.timeIntervalSince1970]
                )
            }
        }

        // 双写：旧版本回退时还能读到完整历史
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 新增或置顶一条记录
    @discardableResult
    static func add(_ item: HistoryItem) -> [HistoryItem] {
        var items = load().filter { $0.url != item.url }
        items.insert(item, at: 0)
        items = Array(items.prefix(limit))
        save(items)
        return items
    }

    @discardableResult
    static func remove(_ item: HistoryItem) -> [HistoryItem] {
        var items = load()
        items.removeAll { $0.url == item.url }
        save(items)
        return items
    }

    @discardableResult
    static func clear() -> [HistoryItem] {
        AppDB.write { db in
            try db.execute(sql: "DELETE FROM history")
        }
        UserDefaults.standard.removeObject(forKey: key)
        return []
    }

    // MARK: 只有数据库不可用时才会走这里

    private static func legacyLoad() -> [HistoryItem] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([HistoryItem].self, from: data)) ?? []
    }
}
