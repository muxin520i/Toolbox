import Foundation
import Combine
import GRDB

// MARK: - 备忘录

/// 一条备忘。正文就是全部内容，标题取第一行，列表里再截一段预览。
struct Memo: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var text: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// 第一行非空内容当标题
    var title: String {
        let first = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return first.isEmpty ? "无标题" : String(first.prefix(60))
    }

    /// 标题之后的几行，压成一行给列表预览
    var preview: String {
        var lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count > 1 else { return "" }
        lines.removeFirst()
        return String(lines.joined(separator: " ").prefix(160))
    }

    /// 正文里认出来的 http / https 地址
    var links: [String] {
        let source = text as NSString
        guard source.length > 0, let regex = Memo.linkRegex else { return [] }
        return regex
            .matches(in: text, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range) }
    }

    var linkCount: Int { links.count }

    var dateText: String {
        let today = Calendar.current.isDateInToday(updatedAt)
        return (today ? Memo.timeFormatter : Memo.dateFormatter).string(from: updatedAt)
    }

    private static let linkRegex = try? NSRegularExpression(
        pattern: "https?://[^\\s，。；、）】》\"'<>]+",
        options: [.caseInsensitive]
    )

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "今天 HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}

/// 备忘录存储：SQLite 为主，UserDefaults 双写兜底。
/// 备忘是纯文本，不涉及文件，重装后数据容器里还在，不会被清掉。
final class MemoStore: ObservableObject {
    static let shared = MemoStore()

    private static let storeKey = "settings.memos.v1"
    private static let maxItems = 300
    private static let maxLength = 20000

    @Published private(set) var items: [Memo] = []

    private init() {
        items = Self.read()
    }

    private struct Row: Codable, FetchableRecord {
        var id: String
        var text: String
        var createdAt: Double
        var updatedAt: Double
    }

    private static func read() -> [Memo] {
        if let rows = AppDB.read({ db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, text, createdAt, updatedAt FROM memo ORDER BY updatedAt DESC"
            )
        }) {
            return rows.compactMap { row -> Memo? in
                guard let memoID = UUID(uuidString: row.id) else { return nil }
                return Memo(
                    id: memoID,
                    text: row.text,
                    createdAt: Date(timeIntervalSince1970: row.createdAt),
                    updatedAt: Date(timeIntervalSince1970: row.updatedAt)
                )
            }
        }

        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([Memo].self, from: data) else {
            return []
        }
        return Array(list.prefix(maxItems))
    }

    private func commit(_ next: [Memo]) {
        let limited = Array(next.prefix(Self.maxItems))
        items = limited

        AppDB.write { db in
            try db.execute(sql: "DELETE FROM memo")
            for memo in limited {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO memo (id, text, createdAt, updatedAt) VALUES (?, ?, ?, ?)",
                    arguments: [
                        memo.id.uuidString,
                        memo.text,
                        memo.createdAt.timeIntervalSince1970,
                        memo.updatedAt.timeIntervalSince1970
                    ]
                )
            }
        }

        if let data = try? JSONEncoder().encode(limited) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    @discardableResult
    func add(_ text: String) -> Memo? {
        guard let clean = Self.clean(text) else { return nil }
        let memo = Memo(text: clean)
        commit([memo] + items)
        return memo
    }

    func update(_ memo: Memo, text: String) {
        guard let clean = Self.clean(text) else { return }
        var copy = items
        guard let index = copy.firstIndex(where: { $0.id == memo.id }) else { return }
        var updated = copy.remove(at: index)
        updated.text = clean
        updated.updatedAt = Date()
        commit([updated] + copy)
    }

    func remove(_ memo: Memo) {
        commit(items.filter { $0.id != memo.id })
    }

    /// 撤销删除：按原来的位置插回去
    func insert(_ memo: Memo, at index: Int) {
        var copy = items
        guard !copy.contains(where: { $0.id == memo.id }) else { return }
        copy.insert(memo, at: max(0, min(index, copy.count)))
        commit(copy)
    }

    func clear() {
        commit([])
    }

    private static func clean(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.count > maxLength {
            value = String(value.prefix(maxLength))
        }
        return value
    }
}
