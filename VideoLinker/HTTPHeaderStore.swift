import Foundation
import Combine

// MARK: - 自定义请求头
//
// 很多站点的 mp4 / m3u8 直链挂在 CDN 上，必须带 Referer 才肯给数据，
// 否则一律 403。这里把「按域名配 Referer / Cookie / UA」做成一张规则表，
// 播放、下载、嗅探取到地址后统一走 headers(for:) 取值。
//
// 存储用 UserDefaults：规则通常就几条，没必要进 SQLite。

struct HeaderRule: Codable, Identifiable, Hashable {
    var id = UUID()
    /// 域名，支持 bilibili.com 与 *.bilibili.com；留空表示所有站点（优先级最低）
    var host = ""
    var referer = ""
    var cookie = ""
    var userAgent = ""
    var enabled = true

    var displayHost: String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "所有站点" : trimmed
    }

    var summary: String {
        var parts: [String] = []
        if !referer.isEmpty { parts.append("Referer") }
        if !cookie.isEmpty { parts.append("Cookie") }
        if !userAgent.isEmpty { parts.append("UA") }
        return parts.isEmpty ? "未设置内容" : parts.joined(separator: " · ")
    }
}

final class HTTPHeaderStore: ObservableObject {

    static let shared = HTTPHeaderStore()

    private static let rulesKey = "http.header.rules.v1"
    private static let autoRefererKey = "http.header.autoReferer"
    private static let userAgentKey = "http.header.userAgent"

    /// 内置 UA：iPhone Safari 的常见值，绝大多数站点不会拦
    static var fallbackUserAgent: String { HLSDownloader.userAgent }

    @Published var rules: [HeaderRule]

    /// 没配规则时，自动用「视频地址的域名」当 Referer。默认开，能救大部分防盗链
    @Published var autoReferer: Bool

    /// 全局 User-Agent，留空用内置
    @Published var userAgent: String

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.rulesKey),
           let decoded = try? JSONDecoder().decode([HeaderRule].self, from: data) {
            rules = decoded
        } else {
            rules = []
        }
        if defaults.object(forKey: Self.autoRefererKey) == nil {
            autoReferer = true
        } else {
            autoReferer = defaults.bool(forKey: Self.autoRefererKey)
        }
        userAgent = defaults.string(forKey: Self.userAgentKey) ?? ""

        // 属性包装器上不能挂 didSet，改成订阅变化后落盘
        $rules.dropFirst().sink { [weak self] value in
            guard let data = try? JSONEncoder().encode(value) else { return }
            UserDefaults.standard.set(data, forKey: Self.rulesKey)
        }.store(in: &cancellables)

        $autoReferer.dropFirst().sink { value in
            UserDefaults.standard.set(value, forKey: Self.autoRefererKey)
        }.store(in: &cancellables)

        $userAgent.dropFirst().sink { value in
            UserDefaults.standard.set(value, forKey: Self.userAgentKey)
        }.store(in: &cancellables)
    }

    // MARK: 取值

    /// 给一条地址算出该带的请求头。extra 里的键会覆盖规则（例如 Authorization）
    static func headers(for url: URL, extra: [String: String] = [:]) -> [String: String] {
        shared.resolve(url: url, extra: extra)
    }

    static func apply(to request: inout URLRequest, url: URL, extra: [String: String] = [:]) {
        for (key, value) in headers(for: url, extra: extra) where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    private func resolve(url: URL, extra: [String: String]) -> [String: String] {
        var result: [String: String] = [:]

        let configuredUA = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        result["User-Agent"] = configuredUA.isEmpty ? Self.fallbackUserAgent : configuredUA

        // 自动 Referer：只给域名，够应付大多数防盗链，也不会把路径里的隐私带出去
        if autoReferer, let scheme = url.scheme, let host = url.host, !host.isEmpty {
            result["Referer"] = "\(scheme)://\(host)/"
        }

        if let rule = match(url) {
            let referer = rule.referer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !referer.isEmpty { result["Referer"] = referer }
            let ua = rule.userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ua.isEmpty { result["User-Agent"] = ua }
            let cookie = rule.cookie.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cookie.isEmpty { result["Cookie"] = cookie }
        }

        for (key, value) in extra where !value.isEmpty {
            result[key] = value
        }
        return result
    }

    /// 最长后缀优先：同时配了 bilibili.com 和 api.bilibili.com 时，后者生效
    private func match(_ url: URL) -> HeaderRule? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        var best: HeaderRule?
        var bestLength = -1

        for rule in rules where rule.enabled {
            let pattern = Self.normalize(rule.host)
            if pattern.isEmpty {
                // 通配规则：只有没有更具体的规则时才用
                if best == nil { best = rule; bestLength = 0 }
                continue
            }
            let hit = host == pattern || host.hasSuffix("." + pattern)
            guard hit, pattern.count > bestLength else { continue }
            best = rule
            bestLength = pattern.count
        }
        return best
    }

    /// 允许用户直接粘一整条地址或带 * 的写法
    private static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return "" }
        if let range = text.range(of: "://") {
            text = String(text[range.upperBound...])
        }
        text = text.split(separator: "/").first.map(String.init) ?? text
        if text.hasPrefix("*.") { text = String(text.dropFirst(2)) }
        if text.hasPrefix(".") { text = String(text.dropFirst()) }
        // 去掉端口
        if let colon = text.firstIndex(of: ":") { text = String(text[text.startIndex..<colon]) }
        return text
    }

    // MARK: 编辑

    func add(_ rule: HeaderRule) {
        rules.append(rule)
    }

    func update(_ rule: HeaderRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
    }

    func delete(_ rule: HeaderRule) {
        rules.removeAll { $0.id == rule.id }
    }

    func move(from source: IndexSet, to destination: Int) {
        // SwiftUI 的 onMove 语义：先取出再插入
        var copy = rules
        copy.move(fromOffsets: source, toOffset: destination)
        rules = copy
    }
}
