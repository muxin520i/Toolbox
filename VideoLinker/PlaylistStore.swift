import Foundation

/// 播放列表里的一个条目
struct PlaylistItem: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var url: String
    var title: String
    /// 已下载到本机时的文件路径；在线链接为 nil
    var localPath: String? = nil

    var isLocal: Bool {
        if localPath != nil { return true }
        return url.lowercased().hasPrefix("file://")
    }

    /// 本地条目的文件是否还在（在线条目恒为 true）
    var localFileExists: Bool {
        guard isLocal else { return true }
        let path = localPath ?? (URL(string: url)?.path ?? "")
        guard !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let u = URL(string: url), let host = u.host {
            return host
        }
        if let path = localPath {
            return (path as NSString).lastPathComponent
        }
        return url
    }

    var subtitle: String {
        if isLocal {
            guard localFileExists else { return "文件已删除，可在下载管理里重新下载" }
            let path = localPath ?? (URL(string: url)?.path ?? "")
            if let attr = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attr[.size] as? Int64 {
                return "已下载 · " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            }
            return "已下载到本机"
        }
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

    /// 内置「下载」列表的 id
    private static let downloadListKey = "video.downloadListID.v1"
    /// 设置里选的「下载保存到」目标列表；auto 表示内置下载列表
    static let downloadTargetKey = "settings.downloadPlaylist"
    static let autoTarget = "auto"
    static let defaultDownloadListName = "下载"

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

    /// 新建并返回新列表，用于设置里「下载保存到」现场建一个
    static func createList(named name: String) -> Playlist? {
        let before = Set(load().map { $0.id })
        _ = create(named: name)
        return load().first { !before.contains($0.id) }
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
        // 删掉的正好是内置下载列表，就把记录清掉，下次下载重新建一个
        if UserDefaults.standard.string(forKey: downloadListKey) == id.uuidString {
            UserDefaults.standard.removeObject(forKey: downloadListKey)
        }
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

    /// 把若干条目搬到另一个列表；目标里已有同地址的会自动跳过，返回实际搬过去的条数
    @discardableResult
    static func move(_ itemIDs: Set<UUID>, from source: UUID, to target: UUID) -> Int {
        guard !itemIDs.isEmpty, source != target else { return 0 }
        var playlists = load()
        guard let s = playlists.firstIndex(where: { $0.id == source }),
              let t = playlists.firstIndex(where: { $0.id == target }) else { return 0 }

        let moving = playlists[s].items.filter { itemIDs.contains($0.id) }
        guard !moving.isEmpty else { return 0 }

        var existing = Set(playlists[t].items.map { $0.url })
        for item in moving where !existing.contains(item.url) {
            playlists[t].items.append(item)
            existing.insert(item.url)
        }
        if playlists[t].items.count > maxItems {
            playlists[t].items = Array(playlists[t].items.prefix(maxItems))
        }
        playlists[s].items.removeAll { itemIDs.contains($0.id) }
        save(playlists)
        return moving.count
    }

    /// 找出某个地址被哪些列表包含，用于界面上的状态提示
    static func playlists(containing url: String) -> [Playlist] {
        load().filter { playlist in
            playlist.items.contains { $0.url == url }
        }
    }

    // MARK: 下载归档

    /// 内置「下载」列表 id：不存在就创建，保证下载的视频一定有地方放
    static func downloadListID() -> UUID {
        var playlists = load()

        if let raw = UserDefaults.standard.string(forKey: downloadListKey),
           let id = UUID(uuidString: raw),
           playlists.contains(where: { $0.id == id }) {
            return id
        }

        if let existing = playlists.first(where: { $0.name == defaultDownloadListName }) {
            UserDefaults.standard.set(existing.id.uuidString, forKey: downloadListKey)
            return existing.id
        }

        let list = Playlist(name: defaultDownloadListName)
        playlists.insert(list, at: 0)
        save(playlists)
        UserDefaults.standard.set(list.id.uuidString, forKey: downloadListKey)
        return list.id
    }

    /// 只查不建，界面判断用
    static func existingDownloadListID() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: downloadListKey),
              let id = UUID(uuidString: raw),
              load().contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// 设置里「下载保存到」的目标；没配或选的列表已删就回落到内置下载列表
    static func downloadTargetID() -> UUID {
        let raw = UserDefaults.standard.string(forKey: downloadTargetKey) ?? autoTarget
        if raw != autoTarget, let id = UUID(uuidString: raw),
           load().contains(where: { $0.id == id }) {
            return id
        }
        return downloadListID()
    }

    /// 下载完成后把本地文件登记进播放列表，返回落到了哪个列表
    @discardableResult
    static func attachDownload(path: String, title: String) -> Playlist? {
        guard !path.isEmpty else { return nil }
        let target = downloadTargetID()
        let fileURL = URL(fileURLWithPath: path)
        let item = PlaylistItem(url: fileURL.absoluteString, title: title, localPath: path)
        let lists = add(item, to: target)
        return lists.first { $0.id == target }
    }
}
