import Foundation
import Combine
import GRDB
import WebKit

// MARK: - 一条下载

enum DownloadState: String, Codable {
    case queued, running, paused, finished, failed

    var title: String {
        switch self {
        case .queued: return "等待中"
        case .running: return "下载中"
        case .paused: return "已暂停"
        case .finished: return "已完成"
        case .failed: return "失败"
        }
    }

    /// 还没结束的都要落盘，下次打开 App 还在
    var isUnfinished: Bool {
        self == .queued || self == .running || self == .paused
    }
}

final class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()
    @Published var fileName: String
    @Published var source: String
    @Published var progress: Double = 0
    @Published var state: DownloadState = .queued
    @Published var localPath: String = ""
    @Published var createdAt: Date = Date()
    /// 失败原因，直接显示给用户看
    @Published var failReason: String = ""
    /// 阶段提示（比如“正在合并为 MP4”）
    @Published var note: String = ""
    @Published var received: Int64 = 0
    @Published var expected: Int64 = 0

    /// HLS 走自研分片下载，拿不到系统的 resumeData
    var isHLS = false
    /// 后台任务标识，用来把系统回调对回这一条
    var taskID = 0
    /// 断点续传数据，暂停或网络中断时保存
    var resumeData: Data?
    /// 目标文件：排队时就定好，重试不会又生成一个新名字
    var destURL: URL?

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

    /// 下载中的「3.2 MB / 18.4 MB」
    var transferText: String {
        guard received > 0 else { return "" }
        let done = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        guard expected > 0 else { return done }
        let total = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
        return done + " / " + total
    }
}

// MARK: - 下载管理

final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate, URLSessionDownloadDelegate {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    /// 当前正在下载的那一条。items 数组本身不随进度变化，首页要靠它才能拿到最新进度
    @Published private(set) var runningItem: DownloadItem?
    /// 同时下载几条，设置页可改
    @Published var concurrency: Int = 3 {
        didSet {
            UserDefaults.standard.set(concurrency, forKey: SettingsKey.downloadConcurrency)
            pump()
        }
    }

    private var timers: [UUID: Timer] = [:]
    private var live: [ObjectIdentifier: DownloadItem] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var itemForTask: [Int: DownloadItem] = [:]
    private var session: URLSession?
    private var pendingCompletion: (() -> Void)?

    private static let storeKey = "browser.downloads.v1"
    private static let queueKey = "browser.downloads.queue.v2"
    private static let sessionID = "com.example.VideoLinker.downloads"

    private override init() {
        super.init()
        let stored = UserDefaults.standard.integer(forKey: SettingsKey.downloadConcurrency)
        concurrency = stored > 0 ? min(stored, 5) : 3
        load()
        // 上次没下完的继续排队
        DispatchQueue.main.async { [weak self] in
            self?.pump()
        }
    }

    // MARK: 后台会话

    private var backgroundSession: URLSession {
        if let session = session { return session }

        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 6
        config.httpMaximumConnectionsPerHost = 4

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility

        let created = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        session = created
        return created
    }

    /// 系统把 App 唤醒来处理后台下载事件时，AppDelegate 把 completion 交过来
    func handleBackgroundEvents(_ completion: @escaping () -> Void) {
        pendingCompletion = completion
        // 触发一次会话初始化，系统才会继续投递回调
        _ = backgroundSession
        pump()
    }

    // MARK: 队列

    /// 按并发上限把排队的任务放出去
    private func pump() {
        let limit = max(1, min(concurrency, 5))
        var running = items.filter { $0.state == .running }.count

        if running < limit {
            for item in items where item.state == .queued {
                guard running < limit else { break }
                if item.isHLS {
                    beginHLS(item)
                } else {
                    beginDirect(item)
                }
                running += 1
            }
        }

        refreshRunning()
    }

    private func beginDirect(_ item: DownloadItem) {
        guard let url = URL(string: item.source) else {
            item.state = .failed
            item.failReason = "链接格式不对"
            save()
            return
        }

        item.state = .running
        item.note = ""
        item.failReason = ""
        item.progress = 0
        item.received = 0

        if item.destURL == nil {
            let known = ["mp4", "m4v", "mov", "ts", "mkv", "webm", "flv",
                         "mp3", "m4a", "aac", "wav", "flac", "avi", "rmvb"]
            var ext = url.pathExtension.lowercased()
            if !known.contains(ext) { ext = "mp4" }
            let base = (item.fileName as NSString).deletingPathExtension
            item.destURL = Self.unique(in: Self.directory(), name: base + "." + ext)
        }

        let task: URLSessionDownloadTask
        if let data = item.resumeData, !data.isEmpty {
            task = backgroundSession.downloadTask(withResumeData: data)
        } else {
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            request.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
            if let referer = Self.referer(for: url) {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }
            task = backgroundSession.downloadTask(with: request)
        }

        item.resumeData = nil
        item.taskID = task.taskIdentifier
        itemForTask[task.taskIdentifier] = item
        task.resume()
        save()
    }

    /// m3u8：解析清单 → 并发拉分片 → 解密 → 顺序拼接
    private func beginHLS(_ item: DownloadItem) {
        guard let url = URL(string: item.source) else {
            item.state = .failed
            item.failReason = "链接格式不对"
            save()
            return
        }

        item.state = .running
        item.note = ""
        item.failReason = ""
        item.progress = 0

        let referer = Self.referer(for: url)
        let baseName = (item.fileName as NSString).deletingPathExtension

        let job = Task { [weak self] in
            guard let self = self else { return }
            do {
                let playlist = try await HLSDownloader.parse(playlistURL: url, referer: referer)
                try Task.checkCancellation()

                let target: URL
                if let existing = item.destURL,
                   existing.pathExtension.lowercased() == playlist.fileExtension {
                    target = existing
                } else {
                    target = Self.unique(in: Self.directory(),
                                         name: baseName + "." + playlist.fileExtension)
                }
                item.destURL = target
                // HLS 没法真正断点续传，重来时先把旧文件清掉，避免残留字节接在后面
                try? FileManager.default.removeItem(at: target)

                await MainActor.run {
                    item.fileName = target.lastPathComponent
                    item.localPath = target.path
                }

                try await HLSDownloader.download(playlist, referer: referer, to: target) { value in
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

                var finalURL = target
                var mergeFailed = false
                do {
                    finalURL = try await MediaRemuxer.remuxIfNeeded(target)
                } catch {
                    mergeFailed = true
                }

                await MainActor.run {
                    item.note = mergeFailed ? "已保存为 .ts，播放器可能不支持" : ""
                    item.fileName = finalURL.lastPathComponent
                    item.localPath = finalURL.path
                    item.destURL = finalURL
                    item.progress = 1
                    item.state = .finished
                    self.jobs.removeValue(forKey: item.id)
                    self.save()
                    self.archive(item)
                    self.pump()
                }
            } catch {
                await MainActor.run {
                    self.jobs.removeValue(forKey: item.id)
                    if item.state == .paused {
                        self.save()
                        self.pump()
                        return
                    }
                    item.state = .failed
                    item.failReason = (error as? HLSFailure)?.message ?? "分片下载中断，可点重试"
                    self.save()
                    self.pump()
                }
            }
        }
        jobs[item.id] = job
    }

    // MARK: 暂停 / 继续 / 重试

    func pause(_ item: DownloadItem) {
        guard item.state == .running || item.state == .queued else { return }
        item.state = .paused
        item.note = ""

        if item.isHLS {
            jobs[item.id]?.cancel()
            jobs.removeValue(forKey: item.id)
        } else if item.taskID != 0 {
            // 暂停时尽量把断点数据留下来，继续时能接着下
            session?.getAllTasks { tasks in
                for task in tasks where task.taskIdentifier == item.taskID {
                    if let downloadTask = task as? URLSessionDownloadTask {
                        downloadTask.cancel(byProducingResumeData: { data in
                            guard let data = data, !data.isEmpty else { return }
                            DispatchQueue.main.async {
                                item.resumeData = data
                                self.save()
                            }
                        })
                    } else {
                        task.cancel()
                    }
                }
            }
        }
        save()
        pump()
    }

    func resume(_ item: DownloadItem) {
        guard item.state == .paused || item.state == .failed else { return }
        item.state = .queued
        item.failReason = ""
        save()
        pump()
    }

    func retry(_ item: DownloadItem) {
        guard item.state == .failed else { return }
        item.state = .queued
        item.progress = 0
        item.failReason = ""
        save()
        pump()
    }

    func pauseAll() {
        for item in items where item.state == .running || item.state == .queued {
            pause(item)
        }
    }

    func resumeAll() {
        for item in items where item.state == .paused {
            item.state = .queued
        }
        save()
        pump()
    }

    // MARK: URLSession 回调

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let item = itemForTask[downloadTask.taskIdentifier] else { return }
        let expected = totalBytesExpectedToWrite
        DispatchQueue.main.async {
            item.received = totalBytesWritten
            if expected > 0 {
                item.expected = expected
                item.progress = min(0.99, Double(totalBytesWritten) / Double(expected))
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let item = itemForTask[downloadTask.taskIdentifier] else { return }
        itemForTask.removeValue(forKey: downloadTask.taskIdentifier)

        let dest = item.destURL ?? Self.unique(in: Self.directory(), name: item.fileName)
        item.destURL = dest

        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            DispatchQueue.main.async {
                item.state = .failed
                item.failReason = "保存失败，存储空间可能不够"
                self.save()
                self.pump()
            }
            return
        }

        // 有些地址没有后缀，下回来才发现是 m3u8：就地转成分片任务
        if let head = try? FileHandle(forReadingFrom: dest).readData(ofLength: 96),
           HLSDownloader.isPlaylistContent(head) {
            try? FileManager.default.removeItem(at: dest)
            DispatchQueue.main.async {
                item.isHLS = true
                item.state = .queued
                item.progress = 0
                item.received = 0
                item.destURL = nil
                self.save()
                self.pump()
            }
            return
        }

        DispatchQueue.main.async {
            item.localPath = dest.path
            item.fileName = dest.lastPathComponent
            item.progress = 1
            self.finish(item)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let item = itemForTask[task.taskIdentifier] else { return }
        itemForTask.removeValue(forKey: task.taskIdentifier)

        // 正常结束已经在 didFinishDownloadingTo 里处理过
        guard let error = error else { return }

        let nsError = error as NSError
        let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data

        DispatchQueue.main.async {
            if item.state == .paused || item.state == .queued {
                if let resume = resume, !resume.isEmpty { item.resumeData = resume }
                self.save()
                self.pump()
                return
            }

            if let resume = resume, !resume.isEmpty {
                item.resumeData = resume
                item.failReason = "连接中断，点「继续」会接着下"
            } else {
                item.failReason = Self.describe(error)
            }
            item.state = .failed
            self.save()
            self.pump()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            if let completion = self.pendingCompletion {
                self.pendingCompletion = nil
                completion()
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet: return "没网了，联网后点重试"
        case NSURLErrorTimedOut: return "连接超时，点重试"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "服务器连不上"
        case NSURLErrorCancelled: return "已取消"
        default: return "下载失败：\(nsError.localizedDescription)"
        }
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

        let item = DownloadItem(fileName: dest.lastPathComponent, source: response.url?.absoluteString ?? "")
        item.localPath = dest.path
        item.destURL = dest
        item.state = .running

        DispatchQueue.main.async {
            self.items.insert(item, at: 0)
            self.items = Array(self.items.prefix(80))
            self.live[ObjectIdentifier(download)] = item
            self.startTimer(download, item: item)
            self.save()
        }
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        DispatchQueue.main.async {
            guard let item = self.live.removeValue(forKey: ObjectIdentifier(download)) else { return }
            self.stopTimer(item.id)
            item.progress = 1
            self.finish(item)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        DispatchQueue.main.async {
            guard let item = self.live.removeValue(forKey: ObjectIdentifier(download)) else { return }
            self.stopTimer(item.id)
            item.state = .failed
            item.failReason = Self.describe(error)
            self.save()
        }
    }

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

    // MARK: 完成

    private func finish(_ item: DownloadItem) {
        guard let dest = item.destURL ?? item.fileURL else {
            item.state = .finished
            save()
            return
        }

        // 直接下到的是裸流（.ts）时转成 MP4
        if dest.pathExtension.lowercased() == "ts" {
            item.note = "正在合并为 MP4…"
            item.localPath = dest.path
            save()
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
                    item.destURL = finalURL
                    item.progress = 1
                    item.state = .finished
                    self.save()
                    self.archive(item)
                    self.pump()
                }
            }
            return
        }

        item.note = ""
        item.progress = 1
        item.state = .finished
        save()
        archive(item)
        pump()
    }

    // MARK: 下载入口（首页 / 播放页 / 嗅探）

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
        let item = DownloadItem(fileName: baseName, source: trimmed)
        item.isHLS = HLSDownloader.looksLikeHLS(trimmed)

        items.insert(item, at: 0)
        items = Array(items.prefix(80))
        save()
        pump()
        return .started(item)
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
        "rmvb", "m2ts", "mpg", "mpeg", "ogv", "3gp", "mp3", "m4a", "aac", "wav", "flac"
    ]

    /// 文件被重封装后更新记录，避免列表里指向已删除的 .ts
    func replacePath(of item: DownloadItem, with url: URL) {
        item.fileName = url.lastPathComponent
        item.localPath = url.path
        item.destURL = url
        item.note = ""
        save()
    }

    func remove(_ item: DownloadItem) {
        jobs[item.id]?.cancel()
        jobs.removeValue(forKey: item.id)
        stopTimer(item.id)

        if !item.isHLS, item.taskID != 0 {
            session?.getAllTasks { tasks in
                for task in tasks where task.taskIdentifier == item.taskID {
                    task.cancel()
                }
            }
        }
        itemForTask.removeValue(forKey: item.taskID)

        if let url = item.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        items.removeAll { $0.id == item.id }
        save()
        pump()
    }

    /// 清理：只清已经结束（完成 / 失败 / 暂停）的，正在下的不动
    func clearFinished() {
        for item in items where item.state != .running {
            if let url = item.fileURL { try? FileManager.default.removeItem(at: url) }
        }
        items.removeAll { $0.state != .running }
        save()
        pump()
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

    /// 没下完的：字段跟 Record 不同，单独存一份到 UserDefaults
    private struct QueueRecord: Codable {
        let fileName: String
        let source: String
        let state: String
        let progress: Double
        let createdAt: Date
        let isHLS: Bool
        let resumeData: String?
        let destPath: String?
    }

    private func save() {
        refreshRunning()

        let finished = items.filter { $0.state == .finished && !$0.localPath.isEmpty }
        let pending = items.filter { $0.state.isUnfinished }

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

        let queue = pending.map { item in
            QueueRecord(
                fileName: item.fileName,
                source: item.source,
                state: item.state.rawValue,
                progress: item.progress,
                createdAt: item.createdAt,
                isHLS: item.isHLS,
                resumeData: item.resumeData?.base64EncodedString(),
                destPath: item.destURL?.path
            )
        }
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: Self.queueKey)
        }
    }

    private func refreshRunning() {
        runningItem = items.first { $0.state == .running } ?? items.first { $0.state == .queued }
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

        var restored: [DownloadItem] = records
            .filter { FileManager.default.fileExists(atPath: $0.localPath) }
            .map { record in
                let item = DownloadItem(fileName: record.fileName, source: record.source)
                item.localPath = record.localPath
                item.destURL = URL(fileURLWithPath: record.localPath)
                item.state = .finished
                item.progress = 1
                item.createdAt = record.date
                return item
            }

        // 上次没下完的排回队列：暂停的仍暂停，其余自动接着下
        if let data = UserDefaults.standard.data(forKey: Self.queueKey),
           let queue = try? JSONDecoder().decode([QueueRecord].self, from: data) {
            for record in queue {
                guard let state = DownloadState(rawValue: record.state), state.isUnfinished else { continue }
                let item = DownloadItem(fileName: record.fileName, source: record.source)
                item.isHLS = record.isHLS
                item.createdAt = record.createdAt
                item.progress = record.progress
                item.destURL = record.destPath.map { URL(fileURLWithPath: $0) }
                item.resumeData = record.resumeData.flatMap { Data(base64Encoded: $0) }
                item.state = state == .paused ? .paused : .queued
                restored.insert(item, at: 0)
            }
        }

        items = Array(restored.prefix(80))
        refreshRunning()
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
