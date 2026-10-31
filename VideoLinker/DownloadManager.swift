import Foundation
import Combine
import GRDB
import WebKit

// MARK: - 一条下载

enum DownloadState: String, Codable {
    case running, finished, failed

    var title: String {
        switch self {
        case .running: return "下载中"
        case .finished: return "已完成"
        case .failed: return "失败"
        }
    }
}

final class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()
    @Published var fileName: String
    @Published var source: String
    @Published var progress: Double = 0
    @Published var state: DownloadState = .running
    @Published var localPath: String = ""
    @Published var createdAt: Date = Date()
    /// 失败原因，直接显示给用户看
    @Published var failReason: String = ""
    /// 阶段提示（比如“正在合并为 MP4”）
    @Published var note: String = ""

    init(fileName: String, source: String) {
        self.fileName = fileName
        self.source = source
    }

    var sizeText: String {
        guard !localPath.isEmpty,
              let attr = try? FileManager.default.attributesOfItem(atPath: localPath),
              let size = attr[.size] as? Int64 else { return "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var fileURL: URL? {
        localPath.isEmpty ? nil : URL(fileURLWithPath: localPath)
    }
}

// MARK: - 下载管理

final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    /// 当前正在下载的那一条。items 数组本身不随进度变化，首页要靠它才能拿到最新进度
    @Published private(set) var runningItem: DownloadItem?

    private var timers: [UUID: Timer] = [:]
    private var live: [ObjectIdentifier: DownloadItem] = [:]
    private var sessions: [UUID: URLSessionDownloadTask] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]

    private static let storeKey = "browser.downloads.v1"

    private override init() {
        super.init()
        load()
    }

    // MARK: 接管 WKDownload

    func adopt(_ download: WKDownload, source: String) {
        download.delegate = self
    }

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let dir = Self.directory()
        let raw = suggestedFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = raw.isEmpty ? "download" : raw
        let dest = Self.unique(in: dir, name: name)

        let item = DownloadItem(
            fileName: dest.lastPathComponent,
            source: response.url?.absoluteString ?? ""
        )
        item.localPath = dest.path

        DispatchQueue.main.async {
            self.items.insert(item, at: 0)
            self.items = Array(self.items.prefix(60))
            self.live[ObjectIdentifier(download)] = item
            self.startTimer(download, item: item)
        }
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        DispatchQueue.main.async {
            guard let item = self.live.removeValue(forKey: ObjectIdentifier(download)) else { return }
            self.stopTimer(item.id)
            item.progress = 1
            item.state = .finished
            self.save()
            self.archive(item)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        DispatchQueue.main.async {
            guard let item = self.live.removeValue(forKey: ObjectIdentifier(download)) else { return }
            self.stopTimer(item.id)
            item.state = .failed
        }
    }

    // MARK: 进度

    private func startTimer(_ download: WKDownload, item: DownloadItem) {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self, weak item] _ in
            guard let self = self, let item = item else { return }
            let value = download.progress.fractionCompleted
            if value.isFinite {
                DispatchQueue.main.async {
                    item.progress = min(max(value, 0), 1)
                }
            }
            if item.state != .running {
                self.stopTimer(item.id)
            }
        }
        timers[item.id] = timer
    }

    private func stopTimer(_ id: UUID) {
        timers[id]?.invalidate()
        timers.removeValue(forKey: id)
    }

    // MARK: 下载入口（首页 / 播放页）

    private static let mobileUA = HLSDownloader.userAgent

    enum Outcome {
        case started(DownloadItem)
        case failed(String)
    }

    /// 直链和 m3u8 都从这里进：m3u8 走分片下载，其余当普通文件下
    func start(from urlString: String, title: String? = nil) -> Outcome {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return .failed("链接格式不对") }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            if url.isFileURL { return .failed("这是本机已有的文件，已经在「下载」列表里了") }
            return .failed("只支持 http/https 链接")
        }

        let ext = url.pathExtension.lowercased()
        if ext == "mpd" || ext == "ism" {
            return .failed("这是 DASH 流（mpd），暂时只能下 m3u8，看看站点有没有 m3u8 地址")
        }

        let baseName = Self.displayName(title: title, url: url)

        if HLSDownloader.looksLikeHLS(trimmed) {
            return .started(startHLS(url: url, name: baseName, source: trimmed))
        }

        return .started(startDirect(url: url, name: baseName, source: trimmed))
    }

    /// 普通文件：一个 GET 到底
    private func startDirect(url: URL, name: String, source: String) -> DownloadItem {
        // 按真实后缀存，不知道后缀才落到 mp4，避免把 .ts 装成 .mp4 导致播不了
        let known = ["mp4", "m4v", "mov", "ts", "mkv", "webm", "flv", "mp3", "m4a", "aac", "wav"]
        var ext = url.pathExtension.lowercased()
        if !known.contains(ext) { ext = "mp4" }
        let dest = Self.unique(in: Self.directory(), name: name + "." + ext)

        let item = DownloadItem(fileName: dest.lastPathComponent, source: source)
        item.localPath = dest.path
        items.insert(item, at: 0)
        items = Array(items.prefix(60))
        refreshRunning()

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        if let referer = Self.referer(for: url) {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        let task = URLSession.shared.downloadTask(with: request) { tempURL, _, error in
            DispatchQueue.main.async {
                self.stopTimer(item.id)
                self.sessions.removeValue(forKey: item.id)

                guard let tempURL = tempURL, error == nil else {
                    item.state = .failed
                    item.failReason = "网络请求失败，可能是链接过期或需要登录"
                    self.save()
                    return
                }

                // 有些地址没有后缀，下回来才发现是 m3u8：转成分片下载
                if let head = try? FileHandle(forReadingFrom: tempURL).readData(ofLength: 96),
                   HLSDownloader.isPlaylistContent(head) {
                    try? FileManager.default.removeItem(at: tempURL)
                    self.promoteToHLS(item: item, url: url, name: name, source: source)
                    return
                }

                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    item.progress = 1
                } catch {
                    item.state = .failed
                    item.failReason = "保存失败，存储空间可能不够"
                    self.save()
                    return
                }

                // 直接下到的是裸流（.ts）时同样转成 MP4
                if dest.pathExtension.lowercased() == "ts" {
                    item.note = "正在合并为 MP4…"
                    self.save()
                    Task {
                        var finalURL = dest
                        var failed = false
                        do {
                            finalURL = try await MediaRemuxer.remuxToMP4(dest)
                        } catch {
                            failed = true
                        }
                        await MainActor.run {
                            item.note = failed ? "已保存为 .ts，播放器可能不支持" : ""
                            item.fileName = finalURL.lastPathComponent
                            item.localPath = finalURL.path
                            item.progress = 1
                            item.state = .finished
                            self.save()
                            self.archive(item)
                        }
                    }
                    return
                }

                item.state = .finished
                self.save()
                self.archive(item)
            }
        }

        sessions[item.id] = task
        startTimer(task: task, item: item)
        task.resume()
        return item
    }

    /// 直链下回来发现是播放列表，就地转成分片任务，复用同一条记录
    private func promoteToHLS(item: DownloadItem, url: URL, name: String, source: String) {
        item.progress = 0
        item.state = .running
        startHLS(url: url, name: name, source: source, existing: item)
    }

    /// m3u8：解析清单 → 并发拉分片 → 解密 → 顺序拼接
    @discardableResult
    private func startHLS(url: URL, name: String, source: String, existing: DownloadItem? = nil) -> DownloadItem {
        let item: DownloadItem
        if let existing = existing {
            item = existing
        } else {
            item = DownloadItem(fileName: name + ".ts", source: source)
            items.insert(item, at: 0)
            items = Array(items.prefix(60))
            refreshRunning()
        }

        let referer = Self.referer(for: url)

        let job = Task { [weak self] in
            guard let self = self else { return }
            do {
                let playlist = try await HLSDownloader.parse(playlistURL: url, referer: referer)
                let dest = Self.unique(in: Self.directory(), name: name + "." + playlist.fileExtension)

                await MainActor.run {
                    item.fileName = dest.lastPathComponent
                    item.localPath = dest.path
                }

                try await HLSDownloader.download(playlist, referer: referer, to: dest) { value in
                    DispatchQueue.main.async {
                        item.progress = min(value, 0.99)
                    }
                }

                // 分片拼出来的是裸流，容器不对播放器认不出来，
                // 这里换成 MP4（只转封装，不重新编码），换完才能直接播
                await MainActor.run {
                    item.progress = 0.99
                    item.note = "正在合并为 MP4…"
                }

                var finalURL = dest
                var mergeFailed = false
                do {
                    finalURL = try await MediaRemuxer.remuxIfNeeded(dest)
                } catch {
                    mergeFailed = true
                }

                await MainActor.run {
                    item.note = ""
                    item.fileName = finalURL.lastPathComponent
                    item.localPath = finalURL.path
                    item.progress = 1
                    item.state = .finished
                    if mergeFailed {
                        item.failReason = ""
                        item.note = "已保存为 .ts，播放器可能不支持"
                    }
                    self.jobs.removeValue(forKey: item.id)
                    self.save()
                    self.archive(item)
                }
            } catch {
                await MainActor.run {
                    item.state = .failed
                    item.failReason = (error as? HLSFailure)?.message ?? error.localizedDescription
                    self.jobs.removeValue(forKey: item.id)
                    self.save()
                }
            }
        }
        jobs[item.id] = job
        return item
    }

    private func startTimer(task: URLSessionDownloadTask, item: DownloadItem) {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self, weak item] _ in
            guard let self = self, let item = item else { return }
            let value = task.progress.fractionCompleted
            if value.isFinite {
                DispatchQueue.main.async {
                    item.progress = min(max(value, 0), 1)
                }
            }
            if item.state != .running {
                self.stopTimer(item.id)
            }
        }
        timers[item.id] = timer
    }

    private static func referer(for url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)/"
    }

    private static func displayName(title: String?, url: URL) -> String {
        var name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = url.lastPathComponent.removingPercentEncoding ?? ""
            name = (name as NSString).deletingPathExtension
        }
        if name.isEmpty { name = "video" }
        return String(name.prefix(60))
    }

    // MARK: 增删

    /// 下载完成 → 自动登记进播放列表（默认「下载」列表，可在设置里改目标）
    private func archive(_ item: DownloadItem) {
        let path = item.localPath
        guard !path.isEmpty else { return }
        let ext = (path as NSString).pathExtension.lowercased()
        guard Self.videoExtensions.contains(ext) else { return }
        let title = (item.fileName as NSString).deletingPathExtension
        PlaylistStore.attachDownload(path: path, title: title)
    }

    /// 只有这些后缀才当成视频放进播放列表，网页里的安装包之类不进
    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "ts", "mkv", "webm", "flv", "avi", "wmv",
        "rmvb", "m2ts", "mpg", "mpeg", "ogv", "3gp", "mp3", "m4a", "aac", "wav"
    ]

    /// 文件被重封装后更新记录，避免列表里指向已删除的 .ts
    func replacePath(of item: DownloadItem, with url: URL) {
        item.fileName = url.lastPathComponent
        item.localPath = url.path
        item.note = ""
        save()
    }

    func remove(_ item: DownloadItem) {
        jobs[item.id]?.cancel()
        jobs.removeValue(forKey: item.id)
        sessions[item.id]?.cancel()
        sessions.removeValue(forKey: item.id)
        stopTimer(item.id)
        if let url = item.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        items.removeAll { $0.id == item.id }
        save()
    }

    func clearFinished() {
        for item in items where item.state != .running {
            if let url = item.fileURL { try? FileManager.default.removeItem(at: url) }
        }
        items.removeAll { $0.state != .running }
        save()
    }

    // MARK: 存储

    private struct Record: Codable {
        let fileName: String
        let source: String
        let localPath: String
        let date: Date
    }

    private struct StoredRow: Codable, FetchableRecord {
        var fileName: String
        var source: String
        var localPath: String
        var createdAt: Double
    }

    private func save() {
        refreshRunning()
        let finished = items.filter { $0.state == .finished && !$0.localPath.isEmpty }

        AppDB.write { db in
            try db.execute(sql: "DELETE FROM download")
            for item in finished {
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO download (id, fileName, source, localPath, createdAt)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        item.id.uuidString, item.fileName, item.source,
                        item.localPath, item.createdAt.timeIntervalSince1970
                    ]
                )
            }
        }

        let records = finished.map {
            Record(fileName: $0.fileName, source: $0.source, localPath: $0.localPath, date: $0.createdAt)
        }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    private func refreshRunning() {
        runningItem = items.first { $0.state == .running }
    }

    private func load() {
        var records: [Record] = []

        if let rows = AppDB.read({ db in
            try StoredRow.fetchAll(
                db,
                sql: "SELECT fileName, source, localPath, createdAt FROM download ORDER BY createdAt DESC"
            )
        }) {
            records = rows.map {
                Record(
                    fileName: $0.fileName,
                    source: $0.source,
                    localPath: $0.localPath,
                    date: Date(timeIntervalSince1970: $0.createdAt)
                )
            }
        } else if let data = UserDefaults.standard.data(forKey: Self.storeKey),
                  let legacy = try? JSONDecoder().decode([Record].self, from: data) {
            records = legacy
        }

        items = records
            .filter { FileManager.default.fileExists(atPath: $0.localPath) }
            .map { record in
                let item = DownloadItem(fileName: record.fileName, source: record.source)
                item.localPath = record.localPath
                item.state = .finished
                item.progress = 1
                item.createdAt = record.date
                return item
            }
    }

    // MARK: 路径

    static func directory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func unique(in dir: URL, name: String) -> URL {
        let raw = name.replacingOccurrences(of: "/", with: "-")
        var candidate = dir.appendingPathComponent(raw)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let ext = (raw as NSString).pathExtension
        let base = (raw as NSString).deletingPathExtension
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = dir.appendingPathComponent(next)
            index += 1
            if index > 200 { break }
        }
        return candidate
    }
}
