import Foundation

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

    // MARK: 进度

    static func all() -> [String: ResumeEntry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: ResumeEntry].self, from: data)) ?? [:]
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

        if let data = try? JSONEncoder().encode(table) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func remove(url: String) {
        var table = all()
        table.removeValue(forKey: url)
        if let data = try? JSONEncoder().encode(table) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: 收藏

    static func favorites() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: favoriteKey) ?? [])
    }

    static func isFavorite(_ url: String) -> Bool {
        favorites().contains(url)
    }

    /// 切换收藏，返回切换后的状态
    @discardableResult
    static func toggleFavorite(_ url: String) -> Bool {
        var set = favorites()
        let starred: Bool
        if set.contains(url) {
            set.remove(url)
            starred = false
        } else {
            set.insert(url)
            starred = true
        }
        UserDefaults.standard.set(Array(set), forKey: favoriteKey)
        return starred
    }
}
