import Foundation
import AVFoundation

// MARK: - 扫描到的本机视频

struct LocalMediaFile: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let size: Int64
    var duration: Double?
    let modified: Date

    var url: URL { URL(fileURLWithPath: path) }
    var title: String { (name as NSString).deletingPathExtension }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var durationText: String? {
        guard let duration, duration.isFinite, duration >= 1 else { return nil }
        return Fmt.time(duration)
    }

    /// 「12:34 · 320.5 MB」
    var summary: String {
        [durationText, sizeText].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - 本机视频

enum LocalMedia {
    /// 能当视频看的后缀，和下载器保持一套
    static let extensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "flv", "avi", "rmvb", "rm", "wmv",
        "ts", "m2ts", "mts", "mpg", "mpeg", "ogv", "3gp", "asf", "vob", "f4v",
        "mp3", "m4a", "aac", "wav", "flac"
    ]

    /// App 自己的文档目录，「文件」App 里显示为「我的 iPhone → 工具箱」
    static func root() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: 扫描

    static func scan(limit: Int = 300, probeDuration: Bool = true) async -> [LocalMediaFile] {
        let found = await Task.detached(priority: .userInitiated) {
            walk(limit: limit)
        }.value

        guard probeDuration else { return found }

        // 时长一条条读太慢，只补前 80 条（列表按修改时间倒序，靠前的就是最可能看的）
        var result = found
        let probeCount = min(result.count, 80)
        for index in 0..<probeCount {
            if let seconds = await duration(of: result[index].url) {
                result[index].duration = seconds
            }
        }
        return result
    }

    private static func walk(limit: Int) -> [LocalMediaFile] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]

        guard let enumerator = manager.enumerator(
            at: root(),
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [LocalMediaFile] = []
        for case let url as URL in enumerator {
            guard result.count < limit else { break }
            let ext = url.pathExtension.lowercased()
            guard extensions.contains(ext) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }

            result.append(
                LocalMediaFile(
                    path: url.path,
                    name: url.lastPathComponent,
                    size: Int64(values.fileSize ?? 0),
                    duration: nil,
                    modified: values.contentModificationDate ?? .distantPast
                )
            )
        }

        return result.sorted { $0.modified > $1.modified }
    }

    private static func duration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let time = try? await asset.load(.duration),
              time.isNumeric, time.seconds.isFinite, time.seconds > 0 else { return nil }
        return time.seconds
    }

    // MARK: 导入

    struct ImportOutcome {
        var added = 0
        /// 已经在播放列表里，没有重复加
        var skipped = 0
        /// 读不出来 / 不是视频 / iCloud 没下下来
        var failed = 0

        var isEmpty: Bool { added == 0 && skipped == 0 && failed == 0 }
    }

    /// 从「文件」里选的视频复制进 App 的 Downloads 目录，
    /// 只登记进播放列表。下载管理只放网络下载的东西，
    /// 导入的文件混进去的话，用户在下载管理一删就会连源文件一起删掉
    @MainActor
    static func importFiles(_ urls: [URL]) async -> ImportOutcome {
        var outcome = ImportOutcome()

        for source in urls {
            // 列表里已经有同名文件了，别再复制一份出来
            if existingPath(named: source.lastPathComponent) != nil {
                outcome.skipped += 1
                continue
            }

            let result = await Task.detached(priority: .userInitiated) {
                copyIntoLibrary(source)
            }.value

            guard case .success(let dest) = result else {
                outcome.failed += 1
                continue
            }

            // 选择器是以 asCopy 弹的，系统会先复制一份到临时目录，这里用完清掉
            cleanupTemporaryCopy(source, kept: dest)

            let already = PlaylistStore.load().contains { list in
                list.items.contains { $0.localPath == dest.path }
            }
            if already {
                outcome.skipped += 1
                if dest.path != source.path {
                    try? FileManager.default.removeItem(at: dest)
                }
                continue
            }

            PlaylistStore.attachDownload(
                path: dest.path,
                title: (dest.lastPathComponent as NSString).deletingPathExtension
            )
            outcome.added += 1
        }

        return outcome
    }

    private enum ImportFailure: Error {
        case unsupported
        case unreadable
    }

    /// 播放列表里已经有同名、且文件还在的条目，返回它的路径
    private static func existingPath(named name: String) -> String? {
        let paths = PlaylistStore.load().flatMap { $0.items.compactMap { $0.localPath } }
        guard let path = paths.first(where: { ($0 as NSString).lastPathComponent == name }) else {
            return nil
        }
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// asCopy 选择器会在 tmp 或 Documents/Inbox 留一份副本，导入完删掉，别白占空间
    private static func cleanupTemporaryCopy(_ source: URL, kept dest: URL) {
        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path
        guard sourcePath != dest.standardizedFileURL.resolvingSymlinksInPath().path else { return }

        let tmpPath = FileManager.default.temporaryDirectory
            .standardizedFileURL.resolvingSymlinksInPath().path
        let inboxPath = root().appendingPathComponent("Inbox")
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard sourcePath.hasPrefix(tmpPath + "/") || sourcePath.hasPrefix(inboxPath + "/") else {
            return
        }
        try? FileManager.default.removeItem(at: source)
    }

    private static func copyIntoLibrary(_ source: URL) -> Result<URL, ImportFailure> {
        let ext = source.pathExtension.lowercased()
        guard !ext.isEmpty, extensions.contains(ext) else { return .failure(.unsupported) }

        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let dir = DownloadManager.directory()
        DownloadManager.ensureDirectory(dir)

        // 已经在 Downloads 里了，不用再动
        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path
        let dirPath = dir.standardizedFileURL.resolvingSymlinksInPath().path
        if sourcePath.hasPrefix(dirPath + "/") {
            guard FileManager.default.fileExists(atPath: sourcePath) else { return .failure(.unreadable) }
            return .success(URL(fileURLWithPath: sourcePath))
        }

        // iCloud 里还没下载到本机的，先等它下下来，否则 copyItem 直接失败
        waitForDownload(source)

        let dest = DownloadManager.unique(in: dir, name: source.lastPathComponent)
        var copied: URL?
        var coordinationError: NSError?

        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readURL in
            do {
                let readPath = readURL.standardizedFileURL.resolvingSymlinksInPath().path
                let rootPath = root().standardizedFileURL.resolvingSymlinksInPath().path
                // 本来就在 App 的文档目录里（用户直接拖进文件夹的）：挪过去，别留两份
                if readPath.hasPrefix(rootPath + "/") {
                    try FileManager.default.moveItem(at: readURL, to: dest)
                } else {
                    try FileManager.default.copyItem(at: readURL, to: dest)
                }
                copied = dest
            } catch {
                copied = nil
            }
        }

        if let copied = copied { return .success(copied) }
        return .failure(.unreadable)
    }

    /// iCloud Drive 上的文件常常只有占位，等它真正落盘（最多 45 秒）
    private static func waitForDownload(_ url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]),
              values.isUbiquitousItem == true else { return }

        func status() -> URLUbiquitousItemDownloadingStatus? {
            try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                .ubiquitousItemDownloadingStatus
        }

        if status() == .current { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if status() == .current { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}
