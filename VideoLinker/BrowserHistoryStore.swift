import Foundation
import Combine
import GRDB

// MARK: - 网页浏览历史

struct WebVisit: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var url: String
    var date: Date = Date()

    var host: String {
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return host
    }
}

final class BrowserHistory: ObservableObject {
    static let shared = BrowserHistory()

    private static let storeKey = "browser.history.v1"
    private let limit = 800

    @Published private(set) var items: [WebVisit] = []

    private struct Row: Codable, FetchableRecord {
        var id: String
        var title: String
        var url: String
        var visitedAt: Double
    }

    private init() {
        if let rows = AppDB.read({ db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, title, url, visitedAt FROM webVisit ORDER BY visitedAt DESC LIMIT ?",
                arguments: [limit]
            )
        }) {
            items = rows.compactMap { row -> WebVisit? in
                guard let visitID = UUID(uuidString: row.id) else { return nil }
                return WebVisit(
                    id: visitID,
                    title: row.title,
                    url: row.url,
                    date: Date(timeIntervalSince1970: row.visitedAt)
                )
            }
        } else if let data = UserDefaults.standard.data(forKey: Self.storeKey),
                  let list = try? JSONDecoder().decode([WebVisit].self, from: data) {
            items = list
        }
    }

    private func commit(_ next: [WebVisit]) {
        items = next
        let trimmed = Array(next.prefix(limit))

        AppDB.write { db in
            try db.execute(sql: "DELETE FROM webVisit")
            for visit in trimmed {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO webVisit (id, title, url, visitedAt) VALUES (?, ?, ?, ?)",
                    arguments: [visit.id.uuidString, visit.title, visit.url, visit.date.timeIntervalSince1970]
                )
            }
        }

        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    /// 同一条地址只留最新的一条
    func record(title: String, url: String) {
        guard url.hasPrefix("http") else { return }
        guard !url.contains("about:blank") else { return }
        var next = items.filter { $0.url != url }
        next.insert(WebVisit(title: title, url: url), at: 0)
        commit(Array(next.prefix(limit)))
    }

    func remove(_ visit: WebVisit) {
        commit(items.filter { $0.id != visit.id })
    }

    func removeAll(matching url: String) {
        commit(items.filter { $0.url != url })
    }

    func clear() {
        commit([])
    }

    /// 按天分组，最新的在前
    func grouped() -> [(String, [WebVisit])] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"

        let calendar = Calendar.current
        var buckets: [(String, [WebVisit])] = []
        var index: [String: Int] = [:]

        for visit in items {
            var key: String
            if calendar.isDateInToday(visit.date) {
                key = "今天"
            } else if calendar.isDateInYesterday(visit.date) {
                key = "昨天"
            } else {
                key = formatter.string(from: visit.date)
            }

            if let position = index[key] {
                buckets[position].1.append(visit)
            } else {
                index[key] = buckets.count
                buckets.append((key, [visit]))
            }
        }
        return buckets
    }

    var isEmpty: Bool { items.isEmpty }
}
