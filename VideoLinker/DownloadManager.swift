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
