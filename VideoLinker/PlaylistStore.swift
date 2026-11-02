import Foundation
import GRDB

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
    /// 私密保险箱里的列表：列表页默认不显示，验证面容 ID 后才出来
    var isPrivate: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, items, createdAt, isPrivate
    }

    init(id: UUID = UUID(),
         name: String,
         items: [PlaylistItem] = [],
         createdAt: Date = Date(),
         isPrivate: Bool = false) {
        self.id = id
        self.name = name
        self.items = items
        self.createdAt = createdAt
        self.isPrivate = isPrivate
    }

    /// 旧备份 / 旧 UserDefaults 里没有 isPrivate，缺字段时按「公开」处理，
    /// 不能让它解码失败把整份列表丢掉
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        items = try container.decodeIfPresent([PlaylistItem].self, forKey: .items) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
    }
}

/// 播放列表有任何改动时广播，界面收到就重读。
/// 从 sheet 里加完视频回来，总览页不会走 onAppear，没有这条通知就会一直显示旧数据
extension Notification.Name {
    static let playlistsDidChange = Notification.Name("video.playlistsDidChange")
}

/// 播放列表存储（SQLite + UserDefaults 双写）
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

    /// 列表页、播放页都会频繁读，整份缓存在内存；写入统一走 save()，写完即刷新
    private static var cache: [Playlist]?

    /// 私密保险箱本次是否已解锁。解锁状态放在这里，
    /// 「加入列表」「局域网页面」这些不在列表页的地方也能统一隐藏
    static var privateUnlocked = false

    /// 给人看的列表：未解锁时自动去掉私密列表
    static func visible() -> [Playlist] {
        let all = load()
        return privateUnlocked ? all : all.filter { !$0.isPrivate }
    }

    private struct ListRow: Codable, FetchableRecord {
        var id: String
        var name: String
        var createdAt: Double
        var isPrivate: Bool
    }

    private struct ItemRow: Codable, FetchableRecord {
        var id: String
        var playlistID: String
        var url: String
        var title: String
        var localPath: String?
    }

    static func load() -> [Playlist] {
        if let cached = cache { return cached }

        let lists = AppDB.read { db -> [Playlist] in
            let listRows = try ListRow.fetchAll(
                db,
                sql: "SELECT id, name, createdAt, isPrivate FROM playlist ORDER BY position ASC"
            )
            let itemRows = try ItemRow.fetchAll(
                db,
                sql: "SELECT id, playlistID, url, title, localPath FROM playlistItem ORDER BY playlistID, position ASC"
            )

            var grouped: [String: [PlaylistItem]] = [:]
            for row in itemRows {
                guard let itemID = UUID(uuidString: row.id) else { continue }
                let path = (row.localPath?.isEmpty == false) ? row.localPath : nil
                grouped[row.playlistID, default: []].append(
                    PlaylistItem(id: itemID, url: row.url, title: row.title, localPath: path)
                )
            }

            return listRows.compactMap { row -> Playlist? in
                guard let listID = UUID(uuidString: row.id) else { return nil }
                return Playlist(
                    id: listID,
                    name: row.name,
                    items: grouped[row.id] ?? [],
                    createdAt: Date(timeIntervalSince1970: row.createdAt),
                    isPrivate: row.isPrivate
                )
            }
        }

        let result = lists ?? legacyLoad()
        cache = result
        return result
    }

    static func save(_ playlists: [Playlist]) {
        let limited = Array(playlists.prefix(maxPlaylists)).map { list -> Playlist in
            var copy = list
            copy.items = Array(list.items.prefix(maxItems))
            return copy
        }
        cache = limited

        // 整表重写：列表最多 20 个、条目最多 100，量很小，
        // 这样排序、移动、去重都不会留下错位的 position
        AppDB.write { db in
            try db.execute(sql: "DELETE FROM playlistItem")
            try db.execute(sql: "DELETE FROM playlist")
            for (index, list) in limited.enumerated() {
                try db.execute(
                    sql: "INSERT INTO playlist (id, name, createdAt, isPrivate, position) VALUES (?, ?, ?, ?, ?)",
                    arguments: [list.id.uuidString, list.name, list.createdAt.timeIntervalSince1970,
                                list.isPrivate ? 1 : 0, index]
                )
                for (order, item) in list.items.enumerated() {
                    try db.execute(
                        sql: """
                            INSERT OR REPLACE INTO playlistItem
                            (id, playlistID, url, title, localPath, position) VALUES (?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            item.id.uuidString, list.id.uuidString, item.url, item.title,
                            item.localPath ?? "", order
                        ]
                    )
                }
            }
        }

        // 双写，回退旧版本时列表还在
        if let data = try? JSONEncoder().encode(limited) {
            UserDefaults.standard.set(data, forKey: key)
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .playlistsDidChange, object: nil)
        }
    }

    private static func legacyLoad() -> [Playlist] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Playlist].self, from: data)) ?? []
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

    /// 移入 / 移出私密保险箱
    @discardableResult
    static func setPrivate(_ id: UUID, _ value: Bool) -> [Playlist] {
        var playlists = load()
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return playlists }
        playlists[index].isPrivate = value
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
        // 满了从最前面丢：之前是 prefix(maxItems)，新加的在末尾会被直接截掉，
        // 表现就是「点了加入，列表里却没有」
        if playlists[index].items.count > maxItems {
            playlists[index].items.removeFirst(playlists[index].items.count - maxItems)
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

    // MARK: 列表排序

    /// 列表总览的排序方式
    enum ListSort: String, CaseIterable, Identifiable {
        case nameAscending
        case nameDescending
        case itemCount
        case newest
        case oldest

        var id: String { rawValue }

        var title: String {
            switch self {
            case .nameAscending: return "名称 A → Z"
            case .nameDescending: return "名称 Z → A"
            case .itemCount: return "视频多的在前"
            case .newest: return "最近创建的在前"
            case .oldest: return "最早创建的在前"
            }
        }

        var icon: String {
            switch self {
            case .nameAscending, .nameDescending: return "textformat.abc"
            case .itemCount: return "number"
            case .newest: return "clock"
            case .oldest: return "clock.arrow.circlepath"
            }
        }
    }

    /// 手动拖动排序（列表总览）
    @discardableResult
    static func move(fromOffsets source: IndexSet, toOffset destination: Int) -> [Playlist] {
        var playlists = load()
        playlists.move(fromOffsets: source, toOffset: destination)
        save(playlists)
        return load()
    }

    /// 把一个列表挪到最前面
    @discardableResult
    static func moveToTop(_ id: UUID) -> [Playlist] {
        var playlists = load()
        guard let index = playlists.firstIndex(where: { $0.id == id }), index > 0 else {
            return playlists
        }
        let list = playlists.remove(at: index)
        playlists.insert(list, at: 0)
        save(playlists)
        return load()
    }

    @discardableResult
    static func sort(_ order: ListSort) -> [Playlist] {
        var playlists = load()
        switch order {
        case .nameAscending:
            playlists.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending:
            playlists.sort { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .itemCount:
            playlists.sort {
                if $0.items.count != $1.items.count { return $0.items.count > $1.items.count }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .newest:
            playlists.sort { $0.createdAt > $1.createdAt }
        case .oldest:
            playlists.sort { $0.createdAt < $1.createdAt }
        }
        save(playlists)
        return load()
    }

    /// 改某一条视频的标题
    @discardableResult
    static func renameItem(_ itemID: UUID, in playlistID: UUID, to title: String) -> [Playlist] {
        var playlists = load()
        guard let listIndex = playlists.firstIndex(where: { $0.id == playlistID }),
              let itemIndex = playlists[listIndex].items.firstIndex(where: { $0.id == itemID }) else {
            return playlists
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return playlists }
        playlists[listIndex].items[itemIndex].title = trimmed
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
            playlists[t].items.removeFirst(playlists[t].items.count - maxItems)
        }
        playlists[s].items.removeAll { itemIDs.contains($0.id) }
        save(playlists)
        return moving.count
    }

    /// 文件被删掉后清理列表里的死条目（本地条目且文件已不存在）
    @discardableResult
    static func pruneMissingLocalItems() -> Int {
        var playlists = load()
        var removed = 0
        for index in playlists.indices {
            let before = playlists[index].items.count
            playlists[index].items.removeAll { $0.isLocal && !$0.localFileExists }
            removed += before - playlists[index].items.count
        }
        guard removed > 0 else { return 0 }
        save(playlists)
        return removed
    }

    /// 找出某个本地文件属于哪些列表，存储管理里做提示用
    static func playlists(containingLocalPath path: String) -> [Playlist] {
        load().filter { list in
            list.items.contains { $0.localPath == path }
        }
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

    /// 重复文件合并：把指向被删文件的条目改到保留下来的文件上；
    /// 同一个列表里改完出现重复条目时只留第一条。返回改动的条目数。
    @discardableResult
    static func mergeDuplicatePaths(_ replacements: [String: String]) -> Int {
        guard !replacements.isEmpty else { return 0 }

        var lists = load()
        var changed = 0

        for index in lists.indices {
            var seen = Set<String>()
            var kept: [PlaylistItem] = []

            for var item in lists[index].items {
                if let old = item.localPath, let new = replacements[old] {
                    item.localPath = new
                    item.url = URL(fileURLWithPath: new).absoluteString
                    changed += 1
                }

                let key = item.localPath ?? item.url
                if seen.contains(key) {
                    changed += 1
                    continue
                }
                seen.insert(key)
                kept.append(item)
            }

            lists[index].items = kept
        }

        if changed > 0 { save(lists) }
        return changed
    }

    /// 下载完成后把本地文件登记进播放列表，返回落到了哪个列表
    @discardableResult
    static func attachDownload(path: String, title: String) -> Playlist? {
        guard !path.isEmpty else { return nil }
        let item = PlaylistItem(
            url: URL(fileURLWithPath: path).absoluteString,
            title: title,
            localPath: path
        )

        var target = downloadTargetID()
        if !load().contains(where: { $0.id == target }) {
            target = downloadListID()
        }

        var lists = add(item, to: target)
        if let list = lists.first(where: { $0.id == target }),
           list.items.contains(where: { $0.localPath == path }) {
            return list
        }

        // 目标列表写不进去（刚好被删、库异常），再兜一次内置「下载」列表
        let fallback = downloadListID()
        guard fallback != target else { return nil }
        lists = add(item, to: fallback)
        return lists.first { $0.id == fallback }
    }

    /// 之前处理过的路径。补登记只做一次，用户之后手动删掉就不会被反复塞回来
    private static let reconciledKey = "video.reconciledLocalPaths.v1"

    /// 下载记录里有、任何播放列表里都没有的本地文件，补进内置「下载」列表。
    ///
    /// 老版本有一段时间下载完成后没写进列表，这些文件在「本机视频」里会显示成
    /// 「已在列表」，用户点不到「+」，等于永远加不进去。这里按路径兜一次。
    @discardableResult
    static func reconcileDownloads(_ entries: [(path: String, title: String)]) -> Int {
        guard !entries.isEmpty else { return 0 }

        var handled = Set(UserDefaults.standard.stringArray(forKey: reconciledKey) ?? [])
        let candidates = entries.filter { !handled.contains($0.path) }
        guard !candidates.isEmpty else { return 0 }

        // 先确认真的有待补的条目再动列表，否则可能平白新建出一个空的「下载」列表
        let allLocalPaths = Set(load().flatMap { $0.items.compactMap { $0.localPath } })
        let pending = candidates.filter { !allLocalPaths.contains($0.path) }
        guard !pending.isEmpty else {
            handled.formUnion(candidates.map { $0.path })
            UserDefaults.standard.set(Array(handled), forKey: reconciledKey)
            return 0
        }

        let target = downloadListID()

        // downloadListID() 可能刚建过列表，要重新读一遍
        var playlists = load()
        guard let index = playlists.firstIndex(where: { $0.id == target }) else { return 0 }

        var existing = Set(playlists[index].items.compactMap { $0.localPath })
        var added = 0

        for entry in pending {
            handled.insert(entry.path)
            guard !existing.contains(entry.path) else { continue }
            playlists[index].items.append(
                PlaylistItem(
                    url: URL(fileURLWithPath: entry.path).absoluteString,
                    title: entry.title,
                    localPath: entry.path
                )
            )
            existing.insert(entry.path)
            added += 1
        }

        if playlists[index].items.count > maxItems {
            playlists[index].items.removeFirst(playlists[index].items.count - maxItems)
        }
        if added > 0 {
            save(playlists)
        }
        handled.formUnion(candidates.map { $0.path })
        UserDefaults.standard.set(Array(handled), forKey: reconciledKey)
        return added
    }
}
