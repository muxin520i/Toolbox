import Foundation
import Combine
import GRDB

// MARK: - 主页快捷方式

struct Shortcut: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var url: String
    var colorIndex: Int = 0
    var addedAt: Date = Date()

    var host: String {
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? host : trimmed
    }

    var initial: String {
        if let first = displayTitle.first { return String(first).uppercased() }
        return "·"
    }

    /// 站点自己的 favicon，取不到就用首字母
    var iconURL: URL? {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return nil }
        return URL(string: "https://\(host)/favicon.ico")
    }
}

final class ShortcutLibrary: ObservableObject {
    static let shared = ShortcutLibrary()

    private static let storeKey = "browser.shortcuts.v1"

    @Published private(set) var items: [Shortcut] = []

    private struct Row: Codable, FetchableRecord {
        var id: String
        var title: String
        var url: String
        var colorIndex: Int
        var addedAt: Double
    }

    private init() {
        if let rows = AppDB.read({ db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, title, url, colorIndex, addedAt FROM shortcut ORDER BY position ASC"
            )
        }) {
            items = rows.compactMap { row -> Shortcut? in
                guard let shortcutID = UUID(uuidString: row.id) else { return nil }
                return Shortcut(
                    id: shortcutID,
                    title: row.title,
                    url: row.url,
                    colorIndex: row.colorIndex,
                    addedAt: Date(timeIntervalSince1970: row.addedAt)
                )
            }
        } else if let data = UserDefaults.standard.data(forKey: Self.storeKey),
                  let list = try? JSONDecoder().decode([Shortcut].self, from: data) {
            items = list
        }
    }

    private func commit(_ next: [Shortcut]) {
        items = next

        // 快捷方式是可以手动调顺序的，所以用 position 而不是时间排序
        AppDB.write { db in
            try db.execute(sql: "DELETE FROM shortcut")
            for (index, shortcut) in next.enumerated() {
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO shortcut (id, title, url, colorIndex, addedAt, position)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        shortcut.id.uuidString, shortcut.title, shortcut.url,
                        shortcut.colorIndex, shortcut.addedAt.timeIntervalSince1970, index
                    ]
                )
            }
        }

        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    func add(title: String, url: String, colorIndex: Int = 0) {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var next = items.filter { $0.url != clean }
        next.append(Shortcut(title: title, url: clean, colorIndex: colorIndex))
        commit(Array(next.prefix(48)))
    }

    func update(_ item: Shortcut) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var next = items
        next[index] = item
        commit(next)
    }

    func remove(_ item: Shortcut) {
        commit(items.filter { $0.id != item.id })
    }

    func moveToFront(_ item: Shortcut) {
        var next = items.filter { $0.id != item.id }
        next.insert(item, at: 0)
        commit(next)
    }

    func clear() {
        commit([])
    }
}
