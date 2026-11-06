import Foundation
import Combine
import UIKit

// MARK: - 多设备同步
//
// 不做实时同步，走「开 App 手动点一下」的半自动模式：把本机数据打成一个 JSON 快照，
// 和 WebDAV 上的那份合并，再把合并结果写回去。
//
// 合并规则统一按「并集 + 时间新的赢」：
// - 播放列表按 id 并集，列表内条目按 id 和地址双重去重
// - 备忘按 id，更新时间晚的覆盖早的
// - 书签按地址去重，多的那台追加
// - 观看进度按地址，取更新的那条
//
// 不做删除传播：一端删掉的东西，另一端同步后还会回来。宁可多留，也不误删。

struct SyncSnapshot: Codable {
    var version: Int = 1
    var device: String
    var savedAt: Date
    var playlists: [Playlist]
    var memos: [Memo]
    var bookmarks: [Bookmark]
    var resume: [String: ResumeEntry]
}

final class SyncStore: ObservableObject {
    static let shared = SyncStore()

    @Published private(set) var syncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastMessage: String?

    private let directory = "VideoLinker"
    private let filePath = "VideoLinker/sync.json"
    private let lastKey = "sync.lastAt"

    private init() {
        if let stamp = UserDefaults.standard.object(forKey: lastKey) as? Date {
            lastSync = stamp
        }
        lastMessage = UserDefaults.standard.string(forKey: "sync.lastMessage")
    }

    /// 返回给界面看的一句话摘要
    func sync() async throws -> String {
        guard !syncing else { return "正在同步" }

        let config = WebDAVConfig.load()
        guard config.isUsable else { throw WebDAVError.badURL }

        syncing = true
        defer { syncing = false }

        let client = WebDAVClient(config: config)
        try? await client.makeDirectory(path: directory)

        let local = makeSnapshot()
        var remote: SyncSnapshot?

        do {
            let data = try await client.get(path: filePath)
            remote = try? JSONDecoder().decode(SyncSnapshot.self, from: data)
        } catch WebDAVError.notFound {
            remote = nil
        }

        var counts = (lists: 0, memos: 0, bookmarks: 0, resume: 0)
        if let remote {
            counts = apply(remote)
        }

        let merged = makeSnapshot()
        let payload = try JSONEncoder().encode(merged)
        try await client.put(path: filePath, data: payload, contentType: "application/json")

        let now = Date()
        lastSync = now
        UserDefaults.standard.set(now, forKey: lastKey)

        let summary: String
        if remote == nil {
            summary = "已上传本机数据，共 \(merged.playlists.count) 个列表"
        } else if counts.lists + counts.memos + counts.bookmarks + counts.resume == 0 {
            summary = "两边一致，没有新内容"
        } else {
            var parts: [String] = []
            if counts.lists > 0 { parts.append("\(counts.lists) 个列表") }
            if counts.memos > 0 { parts.append("\(counts.memos) 条备忘") }
            if counts.bookmarks > 0 { parts.append("\(counts.bookmarks) 个书签") }
            if counts.resume > 0 { parts.append("\(counts.resume) 条进度") }
            summary = "已合并 " + parts.joined(separator: "、")
        }

        lastMessage = summary
        UserDefaults.standard.set(summary, forKey: "sync.lastMessage")
        return summary
    }

    /// 只把本机推上去，不拉取
    func uploadOnly() async throws -> String {
        let config = WebDAVConfig.load()
        guard config.isUsable else { throw WebDAVError.badURL }

        syncing = true
        defer { syncing = false }

        let client = WebDAVClient(config: config)
        try? await client.makeDirectory(path: directory)

        let snapshot = makeSnapshot()
        try await client.put(path: filePath, data: try JSONEncoder().encode(snapshot), contentType: "application/json")

        let now = Date()
        lastSync = now
        UserDefaults.standard.set(now, forKey: lastKey)
        let summary = "已上传 \(snapshot.playlists.count) 个列表、\(snapshot.memos.count) 条备忘"
        lastMessage = summary
        UserDefaults.standard.set(summary, forKey: "sync.lastMessage")
        return summary
    }

    /// 只拉远端覆盖本机，不做上传
    func downloadOnly() async throws -> String {
        let config = WebDAVConfig.load()
        guard config.isUsable else { throw WebDAVError.badURL }

        syncing = true
        defer { syncing = false }

        let client = WebDAVClient(config: config)
        let data = try await client.get(path: filePath)
        guard let remote = try? JSONDecoder().decode(SyncSnapshot.self, from: data) else {
            throw WebDAVError.badXML
        }

        let counts = apply(remote)
        let now = Date()
        lastSync = now
        UserDefaults.standard.set(now, forKey: lastKey)

        let summary = "已拉取 \(counts.lists) 个列表、\(counts.memos) 条备忘"
        lastMessage = summary
        UserDefaults.standard.set(summary, forKey: "sync.lastMessage")
        return summary
    }

    // MARK: 内部

    private func makeSnapshot() -> SyncSnapshot {
        SyncSnapshot(
            device: Self.deviceName,
            savedAt: Date(),
            playlists: PlaylistStore.load(),
            memos: MemoStore.shared.items,
            bookmarks: BookmarkLibrary.shared.items,
            resume: ResumeStore.all()
        )
    }

    /// 把远端合并进本机，返回各项新增了多少
    private func apply(_ remote: SyncSnapshot) -> (lists: Int, memos: Int, bookmarks: Int, resume: Int) {
        let beforeLists = Set(PlaylistStore.load().flatMap { $0.items.map { $0.id } })
        let beforeMemos = Set(MemoStore.shared.items.map { $0.id })
        let beforeBookmarks = Set(BookmarkLibrary.shared.items.map { $0.url })
        let beforeResume = ResumeStore.all()

        PlaylistStore.merge(remote.playlists)
        MemoStore.shared.merge(remote.memos)
        BookmarkLibrary.shared.merge(remote.bookmarks)
        ResumeStore.merge(remote.resume)

        let afterLists = Set(PlaylistStore.load().flatMap { $0.items.map { $0.id } })
        let afterMemos = Set(MemoStore.shared.items.map { $0.id })
        let afterBookmarks = Set(BookmarkLibrary.shared.items.map { $0.url })
        let afterResume = ResumeStore.all()

        var resumeAdded = 0
        for (url, entry) in afterResume {
            if let old = beforeResume[url], old.updated >= entry.updated { continue }
            resumeAdded += 1
        }

        return (
            max(0, afterLists.count - beforeLists.count),
            max(0, afterMemos.count - beforeMemos.count),
            max(0, afterBookmarks.count - beforeBookmarks.count),
            resumeAdded
        )
    }

    static var deviceName: String {
        let name = UIDevice.current.name
        return name.isEmpty ? "iPhone" : name
    }
}
