import Foundation
import Combine
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

    private var timers: [UUID: Timer] = [:]
    private var live: [ObjectIdentifier: DownloadItem] = [:]
    private var sessions: [UUID: URLSessionDownloadTask] = [:]

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

    // MARK: 直接下载（首页 / 播放页）

    private static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// m3u8/mpd 这类是播放列表，不是一个整文件，下载下来也放不了
    static func isStream(_ urlString: String) -> Bool {
        let lower = urlString.lowercased()
        if lower.hasPrefix("blob:") || lower.hasPrefix("data:") { return true }
        guard let url = URL(string: urlString) else { return true }
        return ["m3u8", "m3u", "mpd", "ism", "ts"].contains(url.pathExtension.lowercased())
    }

    /// 直接按链接下一个文件，返回这一条记录（失败返回 nil）
    @discardableResult
    func start(from urlString: String, title: String? = nil) -> DownloadItem? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !Self.isStream(trimmed), let url = URL(string: trimmed) else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }

        var name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = url.lastPathComponent.removingPercentEncoding ?? ""
        }
        if name.isEmpty { name = "video" }
        if (name as NSString).pathExtension.isEmpty { name += ".mp4" }

        let dest = Self.unique(in: Self.directory(), name: name)

        let item = DownloadItem(fileName: dest.lastPathComponent, source: trimmed)
        item.localPath = dest.path

        items.insert(item, at: 0)
        items = Array(items.prefix(60))

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        if let host = url.host {
            request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }

        let task = URLSession.shared.downloadTask(with: request) { tempURL, _, error in
            DispatchQueue.main.async {
                self.stopTimer(item.id)
                self.sessions.removeValue(forKey: item.id)

                guard let tempURL = tempURL, error == nil else {
                    item.state = .failed
                    self.save()
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    item.progress = 1
                    item.state = .finished
                } catch {
                    item.state = .failed
                }
                self.save()
            }
        }

        sessions[item.id] = task
        startTimer(task: task, item: item)
        task.resume()
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

    // MARK: 增删

    func remove(_ item: DownloadItem) {
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

    private func save() {
        let records = items
            .filter { $0.state == .finished && !$0.localPath.isEmpty }
            .map { Record(fileName: $0.fileName, source: $0.source, localPath: $0.localPath, date: $0.createdAt) }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return }
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
