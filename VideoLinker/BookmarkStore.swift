import Foundation
import Combine

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

    private static func read() -> [Bookmark] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([Bookmark].self, from: data) else {
            return []
        }
        return list
    }

    private func commit(_ next: [Bookmark]) {
        items = next
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

    func remove(_ bookmark: Bookmark) {
        commit(items.filter { $0.id != bookmark.id })
    }

    func clear() {
        commit([])
    }
}
