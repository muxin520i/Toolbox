import Foundation

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

/// 历史记录本地存储（UserDefaults + JSON，最多保留 30 条）
enum HistoryStore {
    private static let key = "video.history.v1"
    private static let limit = 30

    static func load() -> [HistoryItem] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([HistoryItem].self, from: data)) ?? []
    }

    static func save(_ items: [HistoryItem]) {
        let trimmed = Array(items.prefix(limit))
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

    static func clear() -> [HistoryItem] {
        UserDefaults.standard.removeObject(forKey: key)
        return []
    }
}
