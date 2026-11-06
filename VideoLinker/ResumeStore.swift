import Foundation
import GRDB

// MARK: - 观看进度记忆

struct ResumeEntry: Codable {
    var position: Double
    var duration: Double
    var updated: Date
}

enum ResumeStore {
    private static let key = "video.resume.v1"
    private static let favoriteKey = "video.favorites.v1"
    private static let limit = 200

    /// 进度是全 App 调用最频繁的查询（列表每一行都要问一次），整表缓存在内存里；
    /// 所有写入都经过这个类，写完立刻刷新缓存，所以不会读到旧值。
    private static var cache: [String: ResumeEntry]?

    private struct Row: Codable, FetchableRecord {
        var url: String
        var position: Double
        var duration: Double
        var updatedAt: Double
    }

    // MARK: 进度

    static func all() -> [String: ResumeEntry] {
        if let cached = cache { return cached }

        var table: [String: ResumeEntry] = [:]
        if let rows = AppDB.read({ db in
            try Row.fetchAll(db, sql: "SELECT url, position, duration, updatedAt FROM resume")
        }) {
            for row in rows {
                table[row.url] = ResumeEntry(
                    position: row.position,
                    duration: row.duration,
                    updated: Date(timeIntervalSince1970: row.updatedAt)
                )
            }
        } else {
            table = legacyAll()
        }

        cache = table
        return table
    }

    /// 只返回“值得续播”的位置：太靠前、快到结尾、时长未知的都当作从头开始
    static func position(for url: String) -> Double? {
        guard let entry = all()[url] else { return nil }
        guard entry.duration > 30 else { return nil }
        guard entry.position >= 5 else { return nil }
        guard entry.duration - entry.position > 15 else { return nil }
        return entry.position
    }

    /// 0~1 的观看百分比，用于历史列表上的进度条
    static func progress(for url: String) -> Double? {
        guard let entry = all()[url], entry.duration > 0 else { return nil }
        return min(1, max(0, entry.position / entry.duration))
    }

    static func save(url: String, position: Double, duration: Double) {
        guard !url.isEmpty else { return }
        guard duration > 0, position > 0 else { return }

        var table = all()
        table[url] = ResumeEntry(position: position, duration: duration, updated: Date())

        // 定期清理：超过 200 条或 90 天没看过的丢掉
        if table.count > limit {
            let sorted = table.sorted { $0.value.updated > $1.value.updated }
            table = Dictionary(uniqueKeysWithValues: sorted.prefix(limit).map { ($0.key, $0.value) })
        }
        let cutoff = Date().addingTimeInterval(-90 * 24 * 3600)
        table = table.filter { $0.value.updated > cutoff }

        persist(table)
    }

    static func remove(url: String) {
        var table = all()
        table.removeValue(forKey: url)
        persist(table)
    }

    /// 重复文件合并：把旧路径的观看进度挪到保留下来的文件上，
    /// 保留文件本身已经有更靠后的进度就不动它。
    /// 同步用：同一个地址取更新更晚的进度
    static func merge(_ remote: [String: ResumeEntry]) {
        guard !remote.isEmpty else { return }
        var table = all()
        for (url, entry) in remote {
            if let local = table[url], local.updated > entry.updated { continue }
            table[url] = entry
        }
        persist(table)
    }

    static func migrate(from oldURL: String, to newURL: String) {
        guard oldURL != newURL, let entry = all()[oldURL] else { return }
        if let existing = all()[newURL], existing.position >= entry.position {
            remove(url: oldURL)
            return
        }
        save(url: newURL, position: entry.position, duration: entry.duration)
        remove(url: oldURL)
    }

    static func clear() {
        cache = [:]
        AppDB.write { db in
            try db.execute(sql: "DELETE FROM resume")
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func persist(_ table: [String: ResumeEntry]) {
        cache = table

        AppDB.write { db in
            try db.execute(sql: "DELETE FROM resume")
            for (url, entry) in table {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO resume (url, position, duration, updatedAt) VALUES (?, ?, ?, ?)",
                    arguments: [url, entry.position, entry.duration, entry.updated.timeIntervalSince1970]
                )
            }
        }

        if let data = try? JSONEncoder().encode(table) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func legacyAll() -> [String: ResumeEntry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: ResumeEntry].self, from: data)) ?? [:]
    }

    // MARK: 收藏

    static func favorites() -> Set<String> {
        if let urls = AppDB.read({ db in
            try String.fetchAll(db, sql: "SELECT url FROM favorite ORDER BY addedAt DESC")
        }) {
            return Set(urls)
        }
        return Set(UserDefaults.standard.stringArray(forKey: favoriteKey) ?? [])
    }

    static func isFavorite(_ url: String) -> Bool {
        favorites().contains(url)
    }

    /// 整表覆盖，供导入备份等场景使用
    static func setFavorites(_ set: Set<String>) {
        AppDB.write { db in
            try db.execute(sql: "DELETE FROM favorite")
            let now = Date().timeIntervalSince1970
            for url in set {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO favorite (url, addedAt) VALUES (?, ?)",
                    arguments: [url, now]
                )
            }
        }
        UserDefaults.standard.set(Array(set), forKey: favoriteKey)
    }

    /// 切换收藏，返回切换后的状态
    @discardableResult
    static func toggleFavorite(_ url: String) -> Bool {
        var set = favorites()
        let starred: Bool
        if set.contains(url) {
            set.remove(url)
            starred = false
            AppDB.write { db in
                try db.execute(sql: "DELETE FROM favorite WHERE url = ?", arguments: [url])
            }
        } else {
            set.insert(url)
            starred = true
            AppDB.write { db in
                try db.execute(
                    sql: "INSERT OR REPLACE INTO favorite (url, addedAt) VALUES (?, ?)",
                    arguments: [url, Date().timeIntervalSince1970]
                )
            }
        }
        UserDefaults.standard.set(Array(set), forKey: favoriteKey)
        return starred
    }
}
