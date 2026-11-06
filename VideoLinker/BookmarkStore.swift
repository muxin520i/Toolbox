import Foundation
import Combine
import GRDB

// MARK: - 书签

struct Bookmark: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var url: String
    var addedAt: Date = Date()

    var host: String {
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// 卡片上显示的那个字
    var initial: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first { return String(first).uppercased() }
        return "·"
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? host : trimmed
    }
}

final class BookmarkLibrary: ObservableObject {
    static let shared = BookmarkLibrary()

    private static let storeKey = "browser.bookmarks.v1"

    @Published private(set) var items: [Bookmark]

    private init() {
        items = Self.read()
    }

    private struct Row: Codable, FetchableRecord {
        var id: String
        var title: String
        var url: String
        var addedAt: Double
    }

    private static func read() -> [Bookmark] {
        if let rows = AppDB.read({ db in
            try Row.fetchAll(db, sql: "SELECT id, title, url, addedAt FROM bookmark ORDER BY addedAt DESC")
        }) {
            return rows.compactMap { row -> Bookmark? in
                guard let bookmarkID = UUID(uuidString: row.id) else { return nil }
                return Bookmark(
                    id: bookmarkID,
                    title: row.title,
                    url: row.url,
                    addedAt: Date(timeIntervalSince1970: row.addedAt)
                )
            }
        }

        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([Bookmark].self, from: data) else {
            return []
        }
        return list
    }

    private func commit(_ next: [Bookmark]) {
        items = next

        AppDB.write { db in
            try db.execute(sql: "DELETE FROM bookmark")
            for bookmark in next {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO bookmark (id, title, url, addedAt) VALUES (?, ?, ?, ?)",
                    arguments: [bookmark.id.uuidString, bookmark.title, bookmark.url, bookmark.addedAt.timeIntervalSince1970]
                )
            }
        }

        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    func contains(_ url: String) -> Bool {
        items.contains { $0.url == url }
    }

    /// 同一地址不重复收藏，已存在则更新标题
    func add(title: String, url: String) {
        guard !url.isEmpty else { return }
        var copy = items.filter { $0.url != url }
        copy.insert(Bookmark(title: title, url: url), at: 0)
        commit(Array(copy.prefix(40)))
    }

    /// 同步用：按地址去重合并，远端独有的追加进来
    func merge(_ remote: [Bookmark]) {
        guard !remote.isEmpty else { return }
        var seen = Set(items.map { $0.url })
        var next = items
        for bookmark in remote.sorted(by: { $0.addedAt > $1.addedAt }) {
            guard !bookmark.url.isEmpty, !seen.contains(bookmark.url) else { continue }
            next.append(bookmark)
            seen.insert(bookmark.url)
        }
        next.sort { $0.addedAt > $1.addedAt }
        commit(Array(next.prefix(40)))
    }

    func remove(_ bookmark: Bookmark) {
        commit(items.filter { $0.id != bookmark.id })
    }

    func clear() {
        commit([])
    }
}
