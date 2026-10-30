import Foundation

/// 播放列表里的一个条目
struct PlaylistItem: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var url: String
    var title: String

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let u = URL(string: url), let host = u.host {
            return host
        }
        return url
    }

    var subtitle: String {
        guard let u = URL(string: url) else { return url }
        if let host = u.host {
            return host + (u.path.isEmpty || u.path == "/" ? "" : u.path)
        }
        return url
    }
}

/// 一个播放列表
struct Playlist: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var items: [PlaylistItem] = []
    var createdAt: Date = Date()
}

/// 播放列表存储（UserDefaults + JSON）
enum PlaylistStore {
    private static let key = "video.playlists.v1"
    private static let maxPlaylists = 20
    private static let maxItems = 100

    static func load() -> [Playlist] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Playlist].self, from: data)) ?? []
    }

    static func save(_ playlists: [Playlist]) {
        if let data = try? JSONEncoder().encode(Array(playlists.prefix(maxPlaylists))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    @discardableResult
    static func create(named name: String) -> [Playlist] {
        var playlists = load()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "未命名列表" : trimmed
        playlists.insert(Playlist(name: finalName), at: 0)
        save(playlists)
        return load()
    }

    @discardableResult
    static func rename(_ id: UUID, to name: String) -> [Playlist] {
        var playlists = load()
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return playlists }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            playlists[index].name = trimmed
        }
        save(playlists)
        return load()
    }

    @discardableResult
    static func delete(_ id: UUID) -> [Playlist] {
        var playlists = load()
        playlists.removeAll { $0.id == id }
        save(playlists)
        return load()
    }

    /// 往列表里加一条，同一个地址不会重复添加
    @discardableResult
    static func add(_ item: PlaylistItem, to playlistID: UUID) -> [Playlist] {
        var playlists = load()
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return playlists }
        if playlists[index].items.contains(where: { $0.url == item.url }) {
            return playlists
        }
        playlists[index].items.append(item)
        if playlists[index].items.count > maxItems {
            playlists[index].items = Array(playlists[index].items.prefix(maxItems))
        }
        save(playlists)
        return load()
    }

    @discardableResult
    static func removeItem(_ itemID: UUID, from playlistID: UUID) -> [Playlist] {
        var playlists = load()
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return playlists }
        playlists[index].items.removeAll { $0.id == itemID }
        save(playlists)
        return load()
    }

    @discardableResult
    static func moveItem(in playlistID: UUID, from source: IndexSet, to destination: Int) -> [Playlist] {
        var playlists = load()
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return playlists }
        playlists[index].items.move(fromOffsets: source, toOffset: destination)
        save(playlists)
        return load()
    }

    /// 找出某个地址被哪些列表包含，用于界面上的状态提示
    static func playlists(containing url: String) -> [Playlist] {
        load().filter { playlist in
            playlist.items.contains { $0.url == url }
        }
    }
}
