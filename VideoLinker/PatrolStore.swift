import Foundation
import Combine
import BackgroundTasks
import UIKit

// MARK: - 定时巡检
//
// 指定一个页面，App 定期去瞄一眼，发现新的视频地址就自动入队下载。
// 适合追更的站：不用天天手动开嗅探页翻一遍。
//
// 后台执行交给 BGAppRefreshTask，系统按使用习惯决定什么时候跑，
// 不保证准时，也不保证一定跑。前台点「立即运行」则立刻执行。

struct PatrolTask: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var pageURL: String
    var keyword: String = ""
    var intervalHours: Int = 12
    var enabled: Bool = true
    var lastRun: Date?
    var lastMessage: String?
    /// 已经见过的地址，避免重复下载。只留最近 600 条
    var seen: [String] = []

    var host: String {
        URL(string: pageURL)?.host ?? pageURL
    }

    var intervalText: String {
        if intervalHours < 24 { return "每 \(intervalHours) 小时" }
        let days = intervalHours / 24
        return days == 1 ? "每天" : "每 \(days) 天"
    }

    var statusText: String {
        if !enabled { return "已暂停" }
        guard let lastRun else { return "还没跑过" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.unitsStyle = .short
        return "上次 " + formatter.localizedString(for: lastRun, relativeTo: Date())
    }

    func isDue(now: Date = Date()) -> Bool {
        guard enabled else { return false }
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= Double(max(1, intervalHours)) * 3600
    }
}

final class PatrolStore: ObservableObject {
    static let shared = PatrolStore()
    static let backgroundIdentifier = "com.example.VideoLinker.patrol"

    @Published private(set) var tasks: [PatrolTask] = []
    @Published private(set) var running = false

    private let storeKey = "patrol.tasks.v1"
    private let maxSeen = 600
    private let maxLinksPerRun = 40

    private init() {
        load()
    }

    // MARK: 增删改

    func add(_ task: PatrolTask) {
        var next = tasks
        next.append(task)
        commit(next)
        scheduleBackground()
    }

    func update(_ task: PatrolTask) {
        var next = tasks
        guard let index = next.firstIndex(where: { $0.id == task.id }) else { return }
        next[index] = task
        commit(next)
        scheduleBackground()
    }

    func remove(_ task: PatrolTask) {
        commit(tasks.filter { $0.id != task.id })
        scheduleBackground()
    }

    func toggle(_ task: PatrolTask) {
        var copy = task
        copy.enabled.toggle()
        update(copy)
    }

    // MARK: 执行

    /// 手动跑一条，返回结果短句
    func run(_ task: PatrolTask) async -> String {
        running = true
        defer { running = false }

        let result = await perform(task)
        apply(result, to: task.id)
        return result.message
    }

    /// 跑所有到期的任务，返回入队总数
    @discardableResult
    func runDueTasks() async -> Int {
        let due = tasks.filter { $0.isDue() }
        guard !due.isEmpty else { return 0 }

        var total = 0
        for task in due {
            let result = await perform(task)
            apply(result, to: task.id)
            total += result.added
        }
        return total
    }

    private struct RunResult {
        var added: Int
        var message: String
        var newLinks: [String]
    }

    private func perform(_ task: PatrolTask) async -> RunResult {
        guard let pageURL = URL(string: task.pageURL),
              let scheme = pageURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return RunResult(added: 0, message: "地址格式不对", newLinks: [])
        }

        let html: String
        do {
            html = try await fetch(pageURL)
        } catch {
            return RunResult(added: 0, message: "抓取失败：\(error.localizedDescription)", newLinks: [])
        }

        let found = Self.extractLinks(from: html, base: pageURL)
        guard !found.isEmpty else {
            return RunResult(added: 0, message: "页面上没找到视频", newLinks: [])
        }

        let keyword = task.keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = keyword.isEmpty
            ? found
            : found.filter { $0.lowercased().contains(keyword) }

        let seen = Set(task.seen)
        let fresh = filtered.filter { !seen.contains($0) }.prefix(maxLinksPerRun)

        guard !fresh.isEmpty else {
            return RunResult(added: 0, message: "没有新的（共 \(filtered.count) 个）", newLinks: [])
        }

        for link in fresh {
            _ = DownloadManager.shared.start(from: link, title: task.name)
        }

        return RunResult(
            added: fresh.count,
            message: "新增 \(fresh.count) 个，已加入下载",
            newLinks: Array(fresh)
        )
    }

    private func apply(_ result: RunResult, to id: UUID) {
        var next = tasks
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].lastRun = Date()
        next[index].lastMessage = result.message

        if !result.newLinks.isEmpty {
            var seen = next[index].seen
            seen.append(contentsOf: result.newLinks)
            if seen.count > maxSeen {
                seen = Array(seen.suffix(maxSeen))
            }
            next[index].seen = seen
        }

        commit(next)
    }

    private func fetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw PatrolError.http(http.statusCode)
        }

        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        let gbk = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let text = String(data: data, encoding: gbk) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: 解析

    /// 从 HTML 里抠视频地址：绝对地址 + src / data-src 属性（可能是相对路径）
    static func extractLinks(from html: String, base: URL) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        func append(_ raw: String) {
            let text = raw
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("data:") else { return }

            let resolved: String
            if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") {
                resolved = text
            } else if let url = URL(string: text, relativeTo: base)?.absoluteURL.absoluteString {
                resolved = url
            } else {
                return
            }

            guard !seen.contains(resolved) else { return }
            seen.insert(resolved)
            result.append(resolved)
        }

        let absolute = try? NSRegularExpression(
            pattern: #"https?://[^\s"'<>\\]+?\.(?:mp4|m3u8|mov|mkv)(?:\?[^\s"'<>\\]*)?"#,
            options: [.caseInsensitive]
        )
        if let absolute {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in absolute.matches(in: html, options: [], range: range) {
                if let r = Range(match.range, in: html) {
                    append(String(html[r]))
                }
            }
        }

        let attributes = try? NSRegularExpression(
            pattern: #"(?:src|data-src|data-url|data-video)\s*=\s*["']([^"']+?\.(?:mp4|m3u8|mov|mkv)[^"']*)["']"#,
            options: [.caseInsensitive]
        )
        if let attributes {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in attributes.matches(in: html, options: [], range: range) {
                guard match.numberOfRanges > 1,
                      let r = Range(match.range(at: 1), in: html) else { continue }
                append(String(html[r]))
            }
        }

        return result
    }

    // MARK: 后台调度

    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundIdentifier,
            using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                PatrolStore.shared.handle(refresh)
            }
        }
    }

    func handle(_ task: BGAppRefreshTask) {
        scheduleBackground()

        let work = Task { @MainActor in
            let added = await self.runDueTasks()
            task.setTaskCompleted(success: true)
            print("[Patrol] 后台巡检完成，新增 \(added) 个")
        }

        task.expirationHandler = {
            work.cancel()
        }
    }

    func scheduleBackground() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundIdentifier)

        guard tasks.contains(where: { $0.enabled }) else { return }

        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundIdentifier)
        let soonest = tasks
            .filter { $0.enabled }
            .map { $0.intervalHours }
            .min() ?? 12
        request.earliestBeginDate = Date(timeIntervalSinceNow: Double(max(1, soonest)) * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: 存储

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([PatrolTask].self, from: data) else {
            tasks = []
            return
        }
        tasks = list
    }

    private func commit(_ next: [PatrolTask]) {
        tasks = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}

enum PatrolError: LocalizedError {
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "页面返回 \(code)"
        }
    }
}
