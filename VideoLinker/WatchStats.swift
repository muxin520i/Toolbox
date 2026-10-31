import Foundation
import GRDB

// MARK: - 观看统计
//
// 播放器每退出一次（或切下一集）就写一条 watchSession：
// url / 标题 / 本次实际看了多少秒 / 结束时间。
// 只存明细，不做累加，所有口径（今天、本周、Top 站点）都在读的时候算，
// 这样以后想加「按月」「按小时」也不用改表。

enum WatchStats {

    struct Item: Identifiable {
        let id: String
        let title: String
        let url: String
        let seconds: Double
        let count: Int
    }

    struct Summary {
        var today: Double = 0
        var week: Double = 0
        var total: Double = 0
        var sessions: Int = 0
        /// 最近 7 天，从早到晚
        var daily: [(day: Date, seconds: Double)] = []
        var topSites: [Item] = []
        var topItems: [Item] = []
        var neverOpened: [(name: String, size: Int64)] = []
        var isEmpty: Bool { total <= 0 }
    }

    private static let minSession: Double = 5      // 少于 5 秒当作误触，不记
    private static let maxSession: Double = 8 * 3600

    // MARK: 记录

    static func record(url: String, title: String, seconds: Double) {
        guard !url.isEmpty else { return }
        let clamped = min(seconds, maxSession)
        guard clamped >= minSession else { return }

        let now = Date().timeIntervalSince1970
        AppDB.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO watchSession (id, url, title, seconds, endedAt)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, url, title, clamped, now]
            )
            // 只留最近一年，避免表无限长
            try db.execute(
                sql: "DELETE FROM watchSession WHERE endedAt < ?",
                arguments: [now - 365 * 24 * 3600]
            )
        }
    }

    // MARK: 读取

    private struct SessionRow: FetchableRecord {
        var url: String
        var title: String
        var seconds: Double
        var endedAt: Double

        init(row: GRDB.Row) {
            url = row["url"]
            title = row["title"]
            seconds = row["seconds"]
            endedAt = row["endedAt"]
        }
    }

    static func summary() -> Summary {
        var result = Summary()

        let rows: [SessionRow] = AppDB.read { db in
            try SessionRow.fetchAll(db, sql: "SELECT url, title, seconds, endedAt FROM watchSession ORDER BY endedAt DESC")
        } ?? []

        guard !rows.isEmpty else {
            result.neverOpened = unopenedDownloads(playedURLs: [])
            return result
        }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfWeek = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday

        result.sessions = rows.count

        var siteSeconds: [String: Double] = [:]
        var siteCount: [String: Int] = [:]
        var itemSeconds: [String: Double] = [:]
        var itemCount: [String: Int] = [:]
        var itemTitle: [String: String] = [:]
        var dayBucket: [Int: Double] = [:]

        for row in rows {
            let date = Date(timeIntervalSince1970: row.endedAt)
            result.total += row.seconds
            if date >= startOfToday { result.today += row.seconds }
            if date >= startOfWeek { result.week += row.seconds }

            let host = (URL(string: row.url)?.host ?? "").lowercased()
            let site = host.isEmpty ? "本地 / 其他" : host
            siteSeconds[site, default: 0] += row.seconds
            siteCount[site, default: 0] += 1

            itemSeconds[row.url, default: 0] += row.seconds
            itemCount[row.url, default: 0] += 1
            if itemTitle[row.url] == nil, !row.title.isEmpty {
                itemTitle[row.url] = row.title
            }

            let key = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
            dayBucket[key, default: 0] += row.seconds
        }

        // 最近 7 天逐日
        for offset in (0..<7).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday) else { continue }
            let key = Int(day.timeIntervalSince1970)
            result.daily.append((day: day, seconds: dayBucket[key] ?? 0))
        }

        result.topSites = siteSeconds
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { Item(id: $0.key, title: $0.key, url: "", seconds: $0.value, count: siteCount[$0.key] ?? 0) }

        result.topItems = itemSeconds
            .sorted { $0.value > $1.value }
            .prefix(6)
            .map {
                Item(
                    id: $0.key,
                    title: itemTitle[$0.key] ?? (URL(string: $0.key)?.lastPathComponent ?? $0.key),
                    url: $0.key,
                    seconds: $0.value,
                    count: itemCount[$0.key] ?? 0
                )
            }

        // 下载了但从没打开过的
        var played = Set<String>()
        for row in rows { played.insert(row.url) }
        result.neverOpened = unopenedDownloads(playedURLs: played)

        return result
    }

    /// 下载记录里有、但播放时长表里找不到的
    private static func unopenedDownloads(playedURLs: Set<String>) -> [(name: String, size: Int64)] {
        struct DownloadRow: FetchableRecord {
            var fileName: String
            var localPath: String
            init(row: GRDB.Row) {
                fileName = row["fileName"]
                localPath = row["localPath"]
            }
        }

        let downloads: [DownloadRow] = AppDB.read { db in
            try DownloadRow.fetchAll(
                db,
                sql: "SELECT fileName, localPath FROM download ORDER BY createdAt DESC LIMIT 300"
            )
        } ?? []

        var result: [(name: String, size: Int64)] = []
        for row in downloads where !row.localPath.isEmpty {
            let path = row.localPath.hasPrefix("file://")
                ? (URL(string: row.localPath)?.path ?? row.localPath)
                : row.localPath
            let matched = playedURLs.contains { $0.contains(path) }
                || ResumeStore.all().keys.contains { $0.contains(path) }
            guard !matched else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            result.append((name: row.fileName, size: size))
        }
        return Array(result.prefix(6))
    }

    static func clear() {
        AppDB.write { db in
            try db.execute(sql: "DELETE FROM watchSession")
        }
    }

    // MARK: 文案

    /// 12 秒 → "12 秒"；3800 秒 → "1 小时 3 分"
    static func span(_ seconds: Double) -> String {
        let value = Int(seconds.rounded())
        guard value > 0 else { return "0 分" }
        if value < 60 { return "\(value) 秒" }
        let minutes = value / 60
        if minutes < 60 { return "\(minutes) 分" }
        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 { return "\(hours) 小时" }
        return "\(hours) 小时 \(rest) 分"
    }

    /// 柱状图上的短标签：3.4 小时 → "3.4h"
    static func shortSpan(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return String(format: "%.1fh", seconds / 3600)
    }
}
