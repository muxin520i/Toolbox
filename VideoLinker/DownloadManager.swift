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
    /// 实时速度（字节/秒），下载页直接显示
    @Published var speed: Double = 0
    /// 总大小是按平均值估出来的（HLS 场景），显示时加「≈」
    var estimatedTotal = false

    /// HLS 走自研分片下载，拿不到系统的 resumeData
    var isHLS = false
    /// 后台任务标识，用来把系统回调对回这一条
    var taskID = 0
    /// 断点续传时已经下完的那部分字节数，任务回调只报「本次」的量，得加上它
    var baseOffset: Int64 = 0
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
        // HLS 没有总字节数，是按已下分片的平均值估的，标个约等号
        return done + " / " + (estimatedTotal ? "≈" + total : total)
    }

    /// 「2.4 MB/s」「860 KB/s」这种，按量级自动选单位
    var speedText: String {
        guard speed > 0 else {
            // 下载中即使这一秒没收到数据也占着位置，别让速度整个消失
            return state == .running && note.isEmpty ? "0 KB/s" : ""
        }
        if speed >= 1024 * 1024 {
            return String(format: "%.1f MB/s", speed / 1024 / 1024)
        }
        if speed >= 1024 {
            return String(format: "%.0f KB/s", speed / 1024)
        }
        return String(format: "%.0f B/s", speed)
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
    /// 后台回调跑在独立串行队列，索引必须加锁，否则会读到半成品甚至崩
    private let indexLock = NSLock()
    /// 正在跑的分片任务：taskID → (哪一条, 第几片，-1 表示初始化段)
    private var segTasks: [Int: (itemID: UUID, index: Int)] = [:]
    /// 分片任务本次已写的字节数，只用于在界面上把「总进度」算准，不参与百分比
    private var segWritten: [Int: Int64] = [:]
    /// 每条 HLS 已经落盘的分片总字节
    private var hlsDoneBytes: [UUID: Int64] = [:]
    /// 每条 HLS 已经落盘的分片个数，用来估总大小
    private var hlsDoneCount: [UUID: Int] = [:]
    /// 哪些条已经按目录统计过落盘字节（重启后要恢复一次）
    private var hlsBytesPrimed: Set<UUID> = []
    /// 分片字节刷新的节流时间戳，避免每秒几十次刷新把主线程打满
    private var lastSegFlush: [UUID: Date] = [:]
    /// 连续几秒没接到数据，速度才真的归零
    private var idleTicks: [UUID: Int] = [:]
    /// 解析好的 HLS 任务（含密钥与分片清单），继续和重启恢复都靠它
    private var hlsJobs: [UUID: HLSJob] = [:]
    /// 正在拼文件的，避免重复进入
    private var hlsAssembling: Set<UUID> = []
    /// 速度采样：每秒算一次 received 的增量
    private var speedTimer: Timer?
    private var lastSample: [UUID: (bytes: Int64, at: Date)] = [:]
    /// 同时在下的分片数
    private let segmentWindow = 4
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
        // 先把上次还活着的后台任务认领回来，再按并发把排队的放出去
        DispatchQueue.main.async { [weak self] in
            self?.prepareSession()
        }
    }

    /// 系统在 App 被回收后仍可能继续跑后台任务，这里按地址把任务认回对应记录，
    /// 避免重复下载同一份文件
    private func prepareSession() {
        let session = backgroundSession
        session.getAllTasks { tasks in
            DispatchQueue.main.async {
                for task in tasks {
                    // 分片任务：按 taskDescription 里记的「哪一条 + 第几片」认回来
                    if let desc = task.taskDescription, desc.hasPrefix("seg:") {
                        let fields = desc.split(separator: ":")
                        if fields.count == 3,
                           let itemID = UUID(uuidString: String(fields[1])),
                           let index = Int(fields[2]),
                           let item = self.items.first(where: { $0.id == itemID }) {
                            self.linkSegment(taskID: task.taskIdentifier,
                                             itemID: itemID, index: index, item: item)
                            if item.state == .paused {
                                task.cancel()
                            } else {
                                item.state = .running
                            }
                        }
                        continue
                    }

                    guard let url = task.originalRequest?.url?.absoluteString else { continue }
                    guard let item = self.items.first(where: {
                        $0.source == url && !$0.isHLS && $0.state != .finished
                    }) else { continue }

                    item.taskID = task.taskIdentifier
                    item.state = .running
                    self.link(item, to: task.taskIdentifier)
                }

                self.refreshRunning()
                self.pump()
            }
        }
    }

    // MARK: 后台会话

    private var backgroundSession: URLSession {
        if let session = session { return session }

        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        // 后台会话在挂起时不会像前台那样持续重试，60 秒超时会让锁屏后的任务频繁失败
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 60 * 60 * 12
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 6

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility

        let created = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        session = created
        return created
    }

    // MARK: 索引读写（后台回调在别的线程，必须加锁）

    private func link(_ item: DownloadItem, to taskID: Int) {
        indexLock.lock()
        itemForTask[taskID] = item
        indexLock.unlock()
    }

    private func linkedItem(_ taskID: Int) -> DownloadItem? {
        indexLock.lock()
        defer { indexLock.unlock() }
        return itemForTask[taskID]
    }

    /// 取走并解绑（一个任务只处理一次）
    private func takeItem(_ taskID: Int) -> DownloadItem? {
        indexLock.lock()
        defer { indexLock.unlock() }
        return itemForTask.removeValue(forKey: taskID)
    }

    private func linkSegment(taskID: Int, itemID: UUID, index: Int, item: DownloadItem?) {
        indexLock.lock()
        segTasks[taskID] = (itemID, index)
        if let item = item { itemForTask[taskID] = item }
        indexLock.unlock()
    }

    private func takeSegment(_ taskID: Int) -> (itemID: UUID, index: Int)? {
        indexLock.lock()
        defer { indexLock.unlock() }
        segWritten.removeValue(forKey: taskID)
        return segTasks.removeValue(forKey: taskID)
    }

    /// 这个任务是不是「某一小片」，是的话它的字节数不能当成整条任务的进度
    private func segmentOwner(_ taskID: Int) -> UUID? {
        indexLock.lock()
        defer { indexLock.unlock() }
        return segTasks[taskID]?.itemID
    }

    private func setSegmentWritten(_ bytes: Int64, for taskID: Int) {
        indexLock.lock()
        segWritten[taskID] = bytes
        indexLock.unlock()
    }

    /// 某一条正在下的分片里，已经写进临时文件的字节数
    private func inFlightBytes(of itemID: UUID) -> Int64 {
        indexLock.lock()
        defer { indexLock.unlock() }
        var sum: Int64 = 0
        for (taskID, info) in segTasks where info.itemID == itemID {
            sum += segWritten[taskID] ?? 0
        }
        return sum
    }

    /// 清掉某一条在内存里的分片计数（暂停、删除、完成时都走这里）
    private func resetSegmentBytes(_ itemID: UUID) {
        indexLock.lock()
        let ids = segTasks.filter { $0.value.itemID == itemID }.map { $0.key }
        for id in ids { segWritten.removeValue(forKey: id) }
        indexLock.unlock()
        hlsDoneBytes.removeValue(forKey: itemID)
        hlsDoneCount.removeValue(forKey: itemID)
        hlsBytesPrimed.remove(itemID)
        lastSegFlush.removeValue(forKey: itemID)
        idleTicks.removeValue(forKey: itemID)
    }

    private func segmentCount(of itemID: UUID) -> Int {
        indexLock.lock()
        defer { indexLock.unlock() }
        return segTasks.values.filter { $0.itemID == itemID }.count
    }

    private func segmentIndexes(of itemID: UUID) -> Set<Int> {
        indexLock.lock()
        defer { indexLock.unlock() }
        return Set(segTasks.values.filter { $0.itemID == itemID }.map { $0.index })
    }

    /// 系统把 App 唤醒来处理后台下载事件时，AppDelegate 把 completion 交过来
    func handleBackgroundEvents(_ completion: @escaping () -> Void) {
        pendingCompletion = completion
        // 触发一次会话初始化，系统才会继续投递回调
        _ = backgroundSession
        prepareSession()
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
        if items.contains(where: { $0.state == .running }) {
            startSpeedTimer()
        }
    }

    private func beginDirect(_ item: DownloadItem) {
        guard let url = URL(string: item.source) else {
            item.state = .failed
            item.failReason = "链接格式不对"
            save()
            return
        }

        // 上一次的后台任务还活着就直接用它，别再派一个：
        // 两个任务同时往一条记录里报字节数，进度必然来回跳
        if item.taskID != 0, linkedItem(item.taskID) != nil {
            item.state = .running
            item.failReason = ""
            refreshRunning()
            return
        }

        item.state = .running
        item.note = ""
        item.failReason = ""
        item.speed = 0
        // 直链的总大小是服务端给的，不是估的
        item.estimatedTotal = false

        let hasResume = !(item.resumeData?.isEmpty ?? true)
        if hasResume {
            // 接着上次的位置显示，别一继续就跳回 0%
            item.baseOffset = Self.resumeOffset(item.resumeData ?? Data())
            if item.baseOffset == 0 { item.baseOffset = item.received }
            item.received = item.baseOffset
            item.note = "正在接着上次的位置…"
        } else {
            item.baseOffset = 0
            if item.received > 0 {
                // 服务器没给断点数据（不支持 Range），只能从头下，明说一句
                item.note = "服务器不支持断点，已从头开始"
            }
            item.progress = 0
            item.received = 0
            item.expected = 0
        }

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
            request.timeoutInterval = 300
            request.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
            if let referer = Self.referer(for: url) {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }
            task = backgroundSession.downloadTask(with: request)
        }

        item.resumeData = nil
        item.taskID = task.taskIdentifier
        link(item, to: task.taskIdentifier)
        task.resume()
        save()
        startSpeedTimer()
    }

    /// 从系统的断点数据里读出「已经下完了多少字节」，读不到就当 0
    private static func resumeOffset(_ data: Data) -> Int64 {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else { return 0 }
        for key in ["NSURLSessionResumeBytesReceived", "NSURLSessionResumeInfoBytesReceived"] {
            if let value = dict[key] as? NSNumber { return value.int64Value }
        }
        return 0
    }

    /// m3u8：解析清单 → 取密钥 → 分片交给后台下载任务 → 拼装 → 换封装
    private func beginHLS(_ item: DownloadItem) {
        guard let url = URL(string: item.source) else {
            fail(item, "链接格式不对")
            return
        }

        item.state = .running
        item.failReason = ""
        item.note = ""
        item.speed = 0
        // HLS 没有可信的总字节数，别显示一个会变的「/ 698 KB」
        item.expected = 0
        item.estimatedTotal = false

        // 之前解析过（暂停后继续、杀掉重开）：直接从缺的分片接着下，不再从头来
        if let job = loadJob(for: item.id) {
            hlsJobs[item.id] = job
            prepareDestination(item, ext: job.fileExtension)
            item.progress = max(item.progress, progress(of: item, job: job))
            pumpSegments(item, job: job)
            save()
            startSpeedTimer()
            return
        }

        item.note = "正在解析清单…"
        item.progress = 0
        item.received = 0

        let referer = Self.referer(for: url)
        let job = Task { [weak self] in
            guard let self = self else { return }
            do {
                let playlist = try await HLSDownloader.parse(playlistURL: url, referer: referer)
                let key = try await HLSDownloader.fetchKey(for: playlist, referer: referer)
                let record = HLSDownloader.makeJob(from: playlist, key: key)
                try Self.saveJob(record, for: item.id)

                await MainActor.run {
                    self.jobs.removeValue(forKey: item.id)
                    guard item.state != .paused else {
                        self.save()
                        self.pump()
                        return
                    }
                    self.hlsJobs[item.id] = record
                    self.prepareDestination(item, ext: record.fileExtension)
                    item.note = ""
                    self.pumpSegments(item, job: record)
                    self.save()
                }
            } catch {
                await MainActor.run {
                    self.jobs.removeValue(forKey: item.id)
                    if item.state == .paused {
                        self.save()
                        self.pump()
                        return
                    }
                    self.fail(item, (error as? HLSFailure)?.message ?? "清单解析失败，点重试会重新解析")
                }
            }
        }
        jobs[item.id] = job
        startSpeedTimer()
    }

    /// 目标文件在排队时就定好，重试不会再生成新名字
    private func prepareDestination(_ item: DownloadItem, ext: String) {
        if let existing = item.destURL, existing.pathExtension.lowercased() == ext { return }
        let baseName = (item.fileName as NSString).deletingPathExtension
        let target = Self.unique(in: Self.directory(), name: baseName + "." + ext)
        item.destURL = target
        item.fileName = target.lastPathComponent
    }

    private func progress(of item: DownloadItem, job: HLSJob) -> Double {
        guard job.total > 0 else { return 0 }
        let dir = Self.partsDirectory(item.id)
        var done = 0
        for index in 0..<job.total where
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("seg-\(index)").path) {
            done += 1
        }
        return min(0.99, Double(done) / Double(job.total))
    }

    /// 重启后先把「已经落盘多少字节」算出来，界面不会从 0 重新数
    private func primeSegmentBytes(_ itemID: UUID, job: HLSJob) {
        guard !hlsBytesPrimed.contains(itemID) else { return }
        hlsBytesPrimed.insert(itemID)

        let dir = Self.partsDirectory(itemID)
        var sum: Int64 = 0
        var count = 0
        if job.initSegment != nil {
            sum += Self.fileSize(dir.appendingPathComponent("init"))
        }
        for index in 0..<job.total {
            let size = Self.fileSize(dir.appendingPathComponent("seg-\(index)"))
            guard size > 0 else { continue }
            sum += size
            count += 1
        }
        hlsDoneBytes[itemID] = sum
        hlsDoneCount[itemID] = count
        if let item = items.first(where: { $0.id == itemID }) {
            item.received = max(item.received, sum)
        }
    }

    /// HLS 拿不到总字节数，用「已落盘分片的平均大小 × 总片数」估一个，边下边校准
    private func refreshHLSExpected(_ item: DownloadItem, job: HLSJob) {
        let count = hlsDoneCount[item.id] ?? 0
        guard count > 0, job.total > 0 else { return }

        let dir = Self.partsDirectory(item.id)
        let initBytes = job.initSegment == nil ? 0 : Self.fileSize(dir.appendingPathComponent("init"))
        let bodyBytes = max(0, (hlsDoneBytes[item.id] ?? 0) - initBytes)
        guard bodyBytes > 0 else { return }

        let estimated = Int64(Double(bodyBytes) / Double(count) * Double(job.total))
        guard estimated > 0 else { return }

        // 不同分片码率会有出入，做一次平滑，免得总量数字一路蹦
        let smoothed = item.expected > 0
            ? Int64(Double(item.expected) * 0.7 + Double(estimated) * 0.3)
            : estimated
        item.expected = max(smoothed, item.received)
        item.estimatedTotal = true
    }

    /// 把「已落盘 + 正在写」的字节数刷到界面，太频繁的刷新直接丢掉
    private func flushSegmentBytes(_ itemID: UUID) {
        DispatchQueue.main.async {
            guard let item = self.items.first(where: { $0.id == itemID }),
                  item.state == .running else { return }
            let now = Date()
            if let last = self.lastSegFlush[itemID], now.timeIntervalSince(last) < 0.3 { return }
            self.lastSegFlush[itemID] = now
            let total = (self.hlsDoneBytes[itemID] ?? 0) + self.inFlightBytes(of: itemID)
            item.received = max(item.received, total)
        }
    }

    /// 把缺的分片排进后台任务，窗口没满就补满
    private func pumpSegments(_ item: DownloadItem, job: HLSJob) {
        guard item.state == .running, !hlsAssembling.contains(item.id) else { return }

        primeSegmentBytes(item.id, job: job)

        let dir = Self.partsDirectory(item.id)
        Self.ensureDirectory(dir)

        // fMP4 的初始化段先拿
        if let initSegment = job.initSegment?.segment,
           !FileManager.default.fileExists(atPath: dir.appendingPathComponent("init").path),
           !segmentIndexes(of: item.id).contains(-1) {
            scheduleSegment(initSegment, index: -1, item: item)
        }

        var inFlight = segmentIndexes(of: item.id)
        var slots = max(0, segmentWindow - inFlight.count)
        var missing = 0

        for index in 0..<job.total {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("seg-\(index)").path) {
                continue
            }
            missing += 1
            guard slots > 0, !inFlight.contains(index),
                  let segment = job.segments[index].segment else { continue }
            scheduleSegment(segment, index: index, item: item)
            inFlight.insert(index)
            slots -= 1
        }

        if job.total > 0 {
            // 只增不减：某一片失败重排时，进度条不能往回掉
            let value = min(0.99, Double(job.total - missing) / Double(job.total))
            item.progress = max(item.progress, value)
        }

        if missing == 0, segmentIndexes(of: item.id).isEmpty {
            assemble(item, job: job)
        }
    }

    private func scheduleSegment(_ segment: HLSSegment, index: Int, item: DownloadItem) {
        let referer = Self.referer(for: URL(string: item.source) ?? segment.url)
        var request = segment.request(referer: referer, ua: Self.mobileUA)
        request.timeoutInterval = 300

        let task = backgroundSession.downloadTask(with: request)
        task.taskDescription = "seg:\(item.id.uuidString):\(index)"
        linkSegment(taskID: task.taskIdentifier, itemID: item.id, index: index, item: item)
        task.resume()
    }

    /// 一片落地：存进 parts 目录，补排下一片，全部到齐就拼装
    private func handleSegmentFinished(taskID: Int, location: URL) -> Bool {
        guard let info = takeSegment(taskID) else { return false }
        _ = takeItem(taskID)

        let dir = Self.partsDirectory(info.itemID)
        Self.ensureDirectory(dir)
        let name = info.index < 0 ? "init" : "seg-\(info.index)"
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: location, to: dest)

        let size = Self.fileSize(dest)

        DispatchQueue.main.async {
            guard let item = self.items.first(where: { $0.id == info.itemID }) else { return }
            // 这一片的字节数从「正在写」挪到「已落盘」，总数是连续的
            if self.hlsBytesPrimed.contains(info.itemID) {
                self.hlsDoneBytes[info.itemID, default: 0] += size
                if info.index >= 0 { self.hlsDoneCount[info.itemID, default: 0] += 1 }
            }
            if let job = self.hlsJobs[item.id] ?? self.loadJob(for: item.id) {
                self.hlsJobs[item.id] = job
                self.pumpSegments(item, job: job)
                self.refreshHLSExpected(item, job: job)
            }
            let total = (self.hlsDoneBytes[info.itemID] ?? 0) + self.inFlightBytes(of: info.itemID)
            item.received = max(item.received, total)
        }
        return true
    }

    private func assemble(_ item: DownloadItem, job: HLSJob) {
        guard !hlsAssembling.contains(item.id) else { return }
        hlsAssembling.insert(item.id)

        item.progress = 0.99
        item.note = "正在合并…"

        let dir = Self.partsDirectory(item.id)
        let target = item.destURL ?? Self.unique(
            in: Self.directory(),
            name: (item.fileName as NSString).deletingPathExtension + "." + job.fileExtension
        )

        Task.detached(priority: .utility) {
            // 结果用不可变值带回来，别把 var 捕获进并发闭包
            let outcome: Result<(url: URL, remuxFailed: Bool), Error>
            do {
                try DownloadManager.writeParts(dir: dir, job: job, to: target)

                // 拼出来的是裸流，换成 MP4 播放器才认
                var output = target
                var remuxFailed = false
                do {
                    output = try await MediaRemuxer.remuxIfNeeded(target)
                } catch {
                    remuxFailed = true
                }
                outcome = .success((output, remuxFailed))
            } catch {
                outcome = .failure(error)
            }

            await MainActor.run {
                self.hlsAssembling.remove(item.id)
                switch outcome {
                case .success(let value):
                    item.note = value.remuxFailed ? "已保存为 .ts，播放器可能不支持" : ""
                    item.fileName = value.url.lastPathComponent
                    item.localPath = value.url.path
                    item.destURL = value.url
                    item.progress = 1
                    item.state = .finished
                    item.speed = 0
                    self.hlsJobs.removeValue(forKey: item.id)
                    self.clearParts(item.id)
                    self.resetSegmentBytes(item.id)
                    self.save()
                    self.archive(item)
                    self.pump()
                case .failure:
                    self.fail(item, "合并失败，点重试会重新合一次")
                }
            }
        }
    }

    /// 按顺序写入：初始化段 → 每片解密 → 拼成一个文件
    private static func writeParts(dir: URL, job: HLSJob, to dest: URL) throws {
        try? FileManager.default.removeItem(at: dest)
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: dest) else {
            throw HLSFailure(message: "写文件失败，存储空间可能不够")
        }
        defer { try? handle.close() }

        if job.initSegment != nil,
           let initData = try? Data(contentsOf: dir.appendingPathComponent("init")) {
            try? handle.write(contentsOf: initData)
        }

        for index in 0..<job.total {
            let data = try Data(contentsOf: dir.appendingPathComponent("seg-\(index)"))
            guard let plain = HLSDownloader.decrypt(data, job: job, index: index) else {
                throw HLSFailure(message: "分片解密失败")
            }
            try handle.write(contentsOf: plain)
        }
    }

    /// 暂停时把这条的分片任务全停掉，已下好的分片留在盘上，继续时接着用
    private func cancelSegments(of itemID: UUID) {
        indexLock.lock()
        let ids = segTasks.filter { $0.value.itemID == itemID }.map { $0.key }
        for id in ids {
            segTasks.removeValue(forKey: id)
            segWritten.removeValue(forKey: id)
            itemForTask.removeValue(forKey: id)
        }
        indexLock.unlock()

        resetSegmentBytes(itemID)

        guard !ids.isEmpty else { return }
        backgroundSession.getAllTasks { tasks in
            for task in tasks where ids.contains(task.taskIdentifier) {
                task.cancel()
            }
        }
    }

    private func fail(_ item: DownloadItem, _ reason: String) {
        item.state = .failed
        item.failReason = reason
        item.note = ""
        item.speed = 0
        // 失败了就把还在飞的分片停掉，别让它们继续写字节数
        if item.isHLS { cancelSegments(of: item.id) }
        save()
        pump()
    }

    // MARK: 速度采样

    private func startSpeedTimer() {
        guard speedTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sampleSpeed()
        }
        RunLoop.main.add(timer, forMode: .common)
        speedTimer = timer
    }

    private func sampleSpeed() {
        let now = Date()
        var active = false
        for item in items {
            guard item.state == .running else {
                if item.speed != 0 { item.speed = 0 }
                lastSample.removeValue(forKey: item.id)
                idleTicks.removeValue(forKey: item.id)
                continue
            }
            active = true
            guard let last = lastSample[item.id] else {
                lastSample[item.id] = (item.received, now)
                continue
            }
            let seconds = now.timeIntervalSince(last.at)
            guard seconds > 0.2 else { continue }

            let delta = item.received - last.bytes
            if delta > 0 {
                let instant = Double(delta) / seconds
                // 慢速网络下这一秒可能只来一点点，做一次平滑，数字别乱蹦
                item.speed = item.speed > 0 ? item.speed * 0.45 + instant * 0.55 : instant
                idleTicks.removeValue(forKey: item.id)
            } else {
                // 一秒没数据不代表停了，连续四秒才归零，中间慢慢往下掉
                let ticks = (idleTicks[item.id] ?? 0) + 1
                idleTicks[item.id] = ticks
                item.speed = ticks >= 4 ? 0 : item.speed * 0.65
            }
            lastSample[item.id] = (item.received, now)
        }
        if !active {
            speedTimer?.invalidate()
            speedTimer = nil
        }
    }

    // MARK: 暂停 / 继续 / 重试

    func pause(_ item: DownloadItem) {
        guard item.state == .running || item.state == .queued else { return }
        item.state = .paused
        item.note = ""

        item.speed = 0

        if item.isHLS {
            jobs[item.id]?.cancel()
            jobs.removeValue(forKey: item.id)
            cancelSegments(of: item.id)
        } else if item.taskID != 0 {
            // 暂停时尽量把断点数据留下来，继续时能接着下
            backgroundSession.getAllTasks { tasks in
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

        var keepParts = false
        if item.isHLS {
            // 分片下到一半断的，已下的分片留着接着下；
            // 清单过期、密钥失效这类失败必须重新解析，留着旧分片反而会拼错
            keepParts = item.failReason.contains("中断") && loadJob(for: item.id) != nil
            if !keepParts {
                clearParts(item.id)
                hlsJobs.removeValue(forKey: item.id)
            }
        }

        item.state = .queued
        if !keepParts {
            item.progress = 0
            item.received = 0
            item.expected = 0
            item.baseOffset = 0
            item.estimatedTotal = false
        }
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
        let taskID = downloadTask.taskIdentifier

        // 分片任务报的是「这一小片」的字节数，几片并行时拿它当整条任务的进度，
        // 百分比就会在这几片之间来回跳。这里只记字节，进度交给「已落地几片」算。
        if let itemID = segmentOwner(taskID) {
            setSegmentWritten(totalBytesWritten, for: taskID)
            flushSegmentBytes(itemID)
            return
        }

        // 只认当前这条记录手上的任务，旧任务迟到的回调一律丢掉
        guard let item = linkedItem(taskID), item.taskID == taskID else { return }

        DispatchQueue.main.async {
            guard item.state == .running else { return }
            item.received = item.baseOffset + totalBytesWritten
            if totalBytesExpectedToWrite > 0 {
                // 断点续传时服务端可能只报剩余长度，总量只增不减
                item.expected = max(item.expected, item.baseOffset + totalBytesExpectedToWrite)
            }
            guard item.expected > 0 else { return }
            let value = Double(item.received) / Double(item.expected)
            // 只增不减：回调乱序或续传重算时，进度条不能往回跳
            item.progress = min(0.99, max(item.progress, value))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 分片任务：存进 parts 目录后继续排下一片
        if handleSegmentFinished(taskID: downloadTask.taskIdentifier, location: location) { return }

        guard let item = takeItem(downloadTask.taskIdentifier) else { return }

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
        // 分片任务：成功的那条已经在 didFinishDownloadingTo 处理过
        if takeSegment(task.taskIdentifier) != nil {
            guard error != nil else { return }
            let segItem = takeItem(task.taskIdentifier)
            DispatchQueue.main.async {
                guard let item = segItem else { return }
                if item.state == .paused || item.state == .queued {
                    self.save()
                    self.pump()
                    return
                }
                self.fail(item, "分片下载中断，点「继续」会接着下")
            }
            return
        }

        guard let item = takeItem(task.taskIdentifier) else { return }

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
        cancelSegments(of: item.id)
        hlsJobs.removeValue(forKey: item.id)
        clearParts(item.id)

        if !item.isHLS, item.taskID != 0 {
            session?.getAllTasks { tasks in
                for task in tasks where task.taskIdentifier == item.taskID {
                    task.cancel()
                }
            }
        }
        _ = takeItem(item.taskID)

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
            if item.isHLS { clearParts(item.id) }
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

    // MARK: HLS 分片缓存

    /// 分片放在 Caches 下，系统清理缓存也不会丢，退出重进还能接着拼
    static func partsDirectory(_ id: UUID) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HLSParts", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func ensureDirectory(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attr = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attr?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func saveJob(_ job: HLSJob, for id: UUID) throws {
        let dir = partsDirectory(id)
        ensureDirectory(dir)
        let data = try JSONEncoder().encode(job)
        try data.write(to: dir.appendingPathComponent("meta.json"))
    }

    func loadJob(for id: UUID) -> HLSJob? {
        let file = Self.partsDirectory(id).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(HLSJob.self, from: data)
    }

    func clearParts(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.partsDirectory(id))
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
