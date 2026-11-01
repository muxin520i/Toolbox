import Foundation

// MARK: - 接口配置（可远程更新）

/// 签到、积分、派猫猫旅行都走官方私有接口。官方改路径后，旧版 App 会直接失败。
/// 这里把路径集中成一张表，App 启动时从仓库拉一份 JSON 覆盖内置默认值：
/// 改接口只需更新 JSON，用户重启 App 即可生效，不必重新装包。
final class WBRemoteConfig {
    static let shared = WBRemoteConfig()

    /// 镜像按顺序试，国内优先 jsDelivr
    private let mirrors = [
        "https://cdn.jsdelivr.net/gh/muxin520i/video-linker@main/wb-endpoints.json",
        "https://raw.githubusercontent.com/muxin520i/video-linker/main/wb-endpoints.json"
    ]

    private let cacheKey = "video.wb.endpoints.cache.v1"
    private let fetchedKey = "video.wb.endpoints.fetchedAt.v1"
    private let minInterval: TimeInterval = 6 * 3600

    private(set) var version = "内置"
    private(set) var updatedAt: Date?
    private(set) var extraHeaders: [String: String] = [:]
    private var override: [String: [String]] = [:]

    /// 内置默认值，同时充当远程配置的白名单（未知键直接忽略）
    static let defaults: [String: [String]] = [
        "auth.state": ["/v2/plugin/auth/state"],
        "auth.token": ["/v2/plugin/auth/token"],
        "auth.account": ["/v2/plugin/login/account"],
        "auth.refresh": ["/v2/plugin/auth/token/refresh"],
        "checkin.status": [
            "/v2/billing/meter/checkin-activity-status",
            "/v2/billing/meter/checkin-status"
        ],
        "checkin.submit": ["/v2/billing/meter/daily-checkin"],
        "credits.summary": ["/billing/meter/get-user-resource-summary"],
        "travel.status": ["/activity/growth/buddy/travel/status"],
        "travel.config": ["/activity/growth/buddy/travel/config"],
        "travel.depart": ["/activity/growth/buddy/travel/depart"],
        "travel.claim": ["/activity/growth/buddy/travel/claim"]
    ]

    private init() {
        loadCache()
    }

    var isRemote: Bool { !override.isEmpty }

    var statusText: String {
        guard let updatedAt else { return "内置路径" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return version + " · " + formatter.string(from: updatedAt)
    }

    func path(_ key: String) -> String {
        paths(key).first ?? ""
    }

    func paths(_ key: String) -> [String] {
        if let list = override[key], !list.isEmpty { return list }
        return Self.defaults[key] ?? []
    }

    func refreshIfNeeded() async {
        let last = UserDefaults.standard.double(forKey: fetchedKey)
        let now = Date().timeIntervalSince1970
        if last > 0, now - last < minInterval { return }
        await fetch()
    }

    func refreshNow() async {
        await fetch()
    }

    private func fetch() async {
        for mirror in mirrors {
            guard let url = URL(string: mirror) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            req.cachePolicy = .reloadIgnoringLocalCacheData

            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            apply(json)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: fetchedKey)
            return
        }
    }

    private func apply(_ json: [String: Any], persistCache: Bool = true) {
        guard let raw = json["paths"] as? [String: Any] else { return }

        var map: [String: [String]] = [:]
        for (key, value) in raw where Self.defaults[key] != nil {
            if let one = value as? String {
                let clean = normalize(one)
                if !clean.isEmpty { map[key] = [clean] }
            } else if let list = value as? [String] {
                let cleaned = list.map(normalize).filter { !$0.isEmpty }
                if !cleaned.isEmpty { map[key] = cleaned }
            }
        }
        guard !map.isEmpty else { return }

        override = map
        version = (json["version"] as? String) ?? "远端配置"
        updatedAt = Date()

        if let headers = json["headers"] as? [String: String] {
            extraHeaders = headers.filter { $0.key.lowercased() != "user-agent" }
        }

        if persistCache { persist() }
    }

    private func normalize(_ path: String) -> String {
        let text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return text.hasPrefix("/") ? text : "/" + text
    }

    private func persist() {
        let payload: [String: Any] = ["version": version, "paths": override, "headers": extraHeaders]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        apply(json, persistCache: false)
    }
}

// MARK: - WB 签到：协议层
//
// 对照 wb-checkin-android 的 Api.java / Checkin.java：
//   登录：POST /v2/plugin/auth/state → 网页授权 → 轮询 /v2/plugin/auth/token → GET /v2/plugin/login/account
//   签到：POST /v2/billing/meter/checkin-activity-status（404 回落 checkin-status）→ /daily-checkin
//   积分：POST /billing/meter/get-user-resource-summary
//
// 注意 User-Agent：网关按请求特征拦，UA 不能改。

struct WBResponse {
    var status: Int = 0
    var code: Int = -1
    var message: String = ""
    var json: [String: Any] = [:]

    var ok: Bool { code == 0 || code == 200 }

    /// 路由不存在（只有这种情况才回落到下一个候选路径）
    var routeMissing: Bool {
        if code == 404 { return true }
        if let data = json["data"] as? [String: Any], WBJson.int(data["code"]) == 404 { return true }
        return false
    }

    /// 凭证失效：10085 是 WAF 指纹拦截，刷新也没用，不要误判成要重新登录
    var unauthorized: Bool {
        if code == 10085 { return false }
        if code == 401 || code == 403 { return true }
        let lower = message.lowercased()
        for key in ["unauthorized", "401", "登录", "失效", "过期"] where lower.contains(key) {
            return true
        }
        return false
    }
}

struct WBStatusResult {
    var ok: Bool
    var checked: Bool
    var unsupported: Bool
    var unauthorized: Bool
    var message: String
}

struct WBCheckinResult {
    var ok: Bool
    var already: Bool
    var message: String
}

struct WBCredits {
    var remaining: Double
    var total: Double
    /// 毫秒
    var soonestExpire: Double?
    var expiringSoonRemaining: Double
    var packages: Int

    var remainingText: String { WBJson.amount(remaining) }
    var totalText: String { WBJson.amount(total) }

    var expireText: String? {
        guard let soonestExpire else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: Date(timeIntervalSince1970: soonestExpire / 1000)) + " 到期"
    }
}

enum WBApi {
    /// 桌面版同款 UA，别改
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"

    static let endpointCN = "https://www.codebuddy.cn"
    static let endpointAI = "https://www.workbuddy.ai"

    /// 惰性刷新阈值：距过期不足 24 小时就换新
    static let lazyRefreshMs: Double = 24 * 3600 * 1000

    static func endpoint(_ variant: String) -> String {
        variant == "ai" ? endpointAI : endpointCN
    }

    static func supportsCheckin(_ variant: String) -> Bool { variant != "ai" }

    /// 账号带了 domain=workbuddy.cn 时走 workbuddy.cn
    static func apiBase(_ account: WBAccount) -> String {
        if account.variant == "ai" { return endpointAI }
        let domain = (account.domain ?? "").lowercased()
        if domain == "workbuddy.cn" || domain == "www.workbuddy.cn" { return "https://www.workbuddy.cn" }
        return endpointCN
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    // MARK: - 基础请求

    static func request(
        _ urlString: String,
        method: String = "POST",
        body: [String: Any]? = nil,
        headers: [String: String] = [:]
    ) async -> WBResponse {
        guard let url = URL(string: urlString) else {
            return WBResponse(status: 0, code: -1, message: "地址不合法", json: [:])
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // 远端配置里的附加头先铺一层，调用方显式传入的优先
        for (key, value) in WBRemoteConfig.shared.extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if method != "GET" {
            let payload = body ?? [:]
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        }

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return parse(data: data, status: status)
        } catch {
            return WBResponse(status: 0, code: -1, message: "网络异常：" + error.localizedDescription, json: [:])
        }
    }

    private static func parse(data: Data, status: Int) -> WBResponse {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let json = object as? [String: Any] {
            let code = WBJson.int(json["code"]) ?? (status >= 400 ? status : 200)
            var message = WBJson.string(json["message"])
            if message.isEmpty { message = WBJson.string(json["msg"]) }
            if message.isEmpty, let nested = json["data"] as? [String: Any] {
                message = WBJson.string(nested["message"])
            }
            return WBResponse(status: status, code: code, message: message, json: json)
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        var message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.hasPrefix("<") {
            if let start = message.range(of: "<title>"), let end = message.range(of: "</title>"),
               start.upperBound < end.lowerBound {
                let title = message[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                message = "服务端返回 HTML 错误页：" + title
            } else {
                message = "服务端返回 HTML 错误页"
            }
        }
        if message.count > 500 { message = String(message.prefix(500)) }
        if message.isEmpty { message = "code=\(status)" }
        return WBResponse(status: status, code: status >= 400 ? status : -1, message: message, json: [:])
    }

    // MARK: - 请求头

    static func authHeaders(_ account: WBAccount) -> [String: String] {
        var headers: [String: String] = [
            "Authorization": "Bearer " + account.accessToken,
            "Accept": "application/json"
        ]
        if let uid = account.uid, !uid.isEmpty { headers["X-User-Id"] = uid }
        if let eid = account.enterpriseId, !eid.isEmpty {
            headers["X-Enterprise-Id"] = eid
            headers["X-Tenant-Id"] = eid
        }
        if let domain = account.domain, !domain.isEmpty { headers["X-Domain"] = domain }
        return headers
    }

    // MARK: - 登录

    /// 申请 state，返回授权页地址
    static func oauthStart(variant: String) async -> (state: String, authUrl: String)? {
        let platform = variant == "ai" ? "workbuddy-ai" : "workbuddy"
        let url = endpoint(variant) + WBRemoteConfig.shared.path("auth.state") + "?platform=" + platform
        let resp = await request(url, method: "POST", body: [:])
        guard resp.ok, let data = resp.json["data"] as? [String: Any] else { return nil }
        let state = WBJson.string(data["state"])
        guard !state.isEmpty else { return nil }
        var authUrl = WBJson.string(data["authUrl"])
        if authUrl.isEmpty { authUrl = WBJson.string(data["auth_url"]) }
        if authUrl.isEmpty { authUrl = WBJson.string(data["url"]) }
        if authUrl.isEmpty { authUrl = endpoint(variant) + "/login?state=" + state }
        return (state, authUrl)
    }

    /// 轮询 token，未完成返回 nil
    static func oauthPollToken(variant: String, state: String) async -> [String: Any]? {
        let url = endpoint(variant) + WBRemoteConfig.shared.path("auth.token") + "?state=" + state
        let resp = await request(url, method: "GET")
        guard resp.ok, let data = resp.json["data"] as? [String: Any] else { return nil }
        var token = WBJson.string(data["accessToken"])
        if token.isEmpty { token = WBJson.string(data["access_token"]) }
        guard !token.isEmpty else { return nil }
        return data
    }

    static func fetchProfile(variant: String, state: String, token: String, domain: String) async -> [String: Any]? {
        let url = endpoint(variant) + WBRemoteConfig.shared.path("auth.account") + "?state=" + state
        var headers = ["Authorization": "Bearer " + token]
        if !domain.isEmpty { headers["X-Domain"] = domain }
        let resp = await request(url, method: "GET", headers: headers)
        guard resp.ok else { return nil }
        return resp.json["data"] as? [String: Any]
    }

    /// 用 token 响应 + 账号资料拼出本地账号
    static func makeAccount(
        variant: String,
        tokenData: [String: Any],
        profile: [String: Any]?
    ) -> WBAccount? {
        var token = WBJson.string(tokenData["accessToken"])
        if token.isEmpty { token = WBJson.string(tokenData["access_token"]) }
        guard !token.isEmpty else { return nil }

        var refresh = WBJson.string(tokenData["refreshToken"])
        if refresh.isEmpty { refresh = WBJson.string(tokenData["refresh_token"]) }

        let now = WBJson.nowMs
        var expires: Double?
        if let direct = WBJson.timestamp(tokenData["expiresAt"] ?? tokenData["expires_at"]) {
            expires = direct
        } else if let seconds = WBJson.double(tokenData["expiresIn"]), seconds > 0 {
            expires = now + seconds * 1000
        }

        var refreshExpires: Double?
        if let direct = WBJson.timestamp(tokenData["refreshExpiresAt"] ?? tokenData["refresh_expires_at"]) {
            refreshExpires = direct
        } else if let seconds = WBJson.double(tokenData["refreshExpiresIn"]), seconds > 0 {
            refreshExpires = now + seconds * 1000
        }

        return WBAccount(
            id: UUID().uuidString,
            uid: profile.map { WBJson.string($0["uid"]) },
            nickname: profile.map { WBJson.string($0["nickname"]) },
            email: profile.map { WBJson.string($0["email"]) },
            enterpriseId: profile.map { WBJson.string($0["enterpriseId"]) },
            enterpriseName: profile.map { WBJson.string($0["enterpriseName"]) },
            accessToken: token,
            refreshToken: refresh.isEmpty ? nil : refresh,
            domain: WBJson.string(tokenData["domain"]),
            variant: variant,
            expiresAt: expires,
            refreshExpiresAt: refreshExpires,
            createdAt: now,
            needsRelogin: false,
            reloginReason: nil
        )
    }

    // MARK: - 刷新

    static func isTokenStale(_ account: WBAccount) -> Bool {
        guard let expires = account.expiresAt else { return true }
        return WBJson.nowMs >= expires || expires - WBJson.nowMs < lazyRefreshMs
    }

    static func refresh(_ account: WBAccount) async -> WBAccount? {
        guard let refreshToken = account.refreshToken, !refreshToken.isEmpty else { return nil }

        var headers = authHeaders(account)
        headers["X-Refresh-Token"] = refreshToken
        headers["X-Auth-Refresh-Source"] = "plugin"

        let url = endpoint(account.variant) + WBRemoteConfig.shared.path("auth.refresh")
        let resp = await request(url, method: "POST", body: [:], headers: headers)
        guard resp.ok, let data = resp.json["data"] as? [String: Any] else { return nil }

        var token = WBJson.string(data["accessToken"])
        if token.isEmpty { token = WBJson.string(data["access_token"]) }
        guard !token.isEmpty else { return nil }

        var updated = account
        updated.accessToken = token
        let newRefresh = WBJson.string(data["refreshToken"]).isEmpty
            ? WBJson.string(data["refresh_token"]) : WBJson.string(data["refreshToken"])
        if !newRefresh.isEmpty { updated.refreshToken = newRefresh }
        if let expires = WBJson.timestamp(data["expiresAt"] ?? data["expires_at"]) {
            updated.expiresAt = expires
        } else if let seconds = WBJson.double(data["expiresIn"]), seconds > 0 {
            updated.expiresAt = WBJson.nowMs + seconds * 1000
        }
        updated.needsRelogin = false
        updated.reloginReason = nil
        return updated
    }

    // MARK: - 签到

    static func checkinStatus(_ account: WBAccount) async -> WBStatusResult {
        let base = apiBase(account)
        var lastMessage = ""

        for suffix in WBRemoteConfig.shared.paths("checkin.status") {
            let url = base + suffix
            let resp = await request(url, method: "POST", body: [:], headers: authHeaders(account))

            if resp.unauthorized {
                return WBStatusResult(ok: false, checked: false, unsupported: false,
                                      unauthorized: true, message: resp.message)
            }
            if resp.ok {
                var checked = false
                if let data = resp.json["data"] as? [String: Any] {
                    checked = WBJson.bool(data["today_checked_in"]) || WBJson.bool(data["todayCheckedIn"])
                }
                return WBStatusResult(ok: true, checked: checked, unsupported: false,
                                      unauthorized: false, message: "")
            }
            if resp.routeMissing {
                lastMessage = resp.message
                continue
            }
            return WBStatusResult(ok: false, checked: false, unsupported: false,
                                  unauthorized: false, message: resp.message)
        }

        // 两条路径都是 404：这档没有状态接口，直接签
        return WBStatusResult(ok: false, checked: false, unsupported: true,
                              unauthorized: false, message: lastMessage)
    }

    static func performCheckin(_ account: WBAccount) async -> WBCheckinResult {
        let url = apiBase(account) + WBRemoteConfig.shared.path("checkin.submit")
        let resp = await request(url, method: "POST", body: [:], headers: authHeaders(account))
        if resp.ok { return WBCheckinResult(ok: true, already: false, message: "") }

        let message = resp.message
        if message.contains("已签到") || message.lowercased().contains("repeat") {
            return WBCheckinResult(ok: true, already: true, message: message)
        }
        return WBCheckinResult(ok: false, already: false, message: message.isEmpty ? "签到失败" : message)
    }

    // MARK: - 积分

    static func credits(_ account: WBAccount) async -> WBCredits? {
        let base = apiBase(account)
        var headers = authHeaders(account)
        headers["X-Client-Platform"] = "web"
        headers["Accept"] = "application/json, text/plain, */*"
        headers["Origin"] = base
        headers["Referer"] = base + "/profile/plans-usage"

        var resp = WBResponse()
        for suffix in WBRemoteConfig.shared.paths("credits.summary") {
            resp = await request(base + suffix, method: "POST", body: [:], headers: headers)
            if resp.ok || !resp.routeMissing { break }
        }
        guard resp.ok else { return nil }
        guard let rows = packages(in: resp.json) else { return nil }

        let now = WBJson.nowMs
        var remaining = 0.0
        var total = 0.0
        var soonest: Double?
        var expiringSoon = 0.0
        var counted = 0

        for row in rows {
            let rowTotal = firstNumber(row, [
                "CycleCapacitySizePrecise", "CycleCapacitySize", "CycleTotalCapacity",
                "CapacitySizePrecise", "CapacitySize",
                "SlicePeriodCapacitySizePrecise", "SlicePeriodCapacitySize"
            ]) ?? 0
            let rowRemaining = firstNumber(row, [
                "CycleCapacityRemainPrecise", "CycleCapacityRemain", "CycleRemainCapacity",
                "CapacityRemainPrecise", "CapacityRemain",
                "SlicePeriodCapacityRemainPrecise", "SlicePeriodCapacityRemain"
            ]) ?? 0

            let expire = WBJson.timestamp(
                row["DeductionEndTime"] ?? row["deductionEndTime"]
                    ?? row["ExpiredTime"] ?? row["expiredTime"]
                    ?? row["CycleEndTime"] ?? row["cycleEndTime"]
            )

            // 过期包不计入（官网也不展示），否则会把总额撑大
            if let expire, expire <= now { continue }

            remaining += rowRemaining
            total += max(rowTotal, rowRemaining)
            counted += 1
            if rowRemaining > 0, let expire {
                if soonest == nil || expire < soonest! { soonest = expire }
                if expire - now <= 7 * 24 * 3600 * 1000 { expiringSoon += rowRemaining }
            }
        }

        guard counted > 0 else { return nil }
        return WBCredits(remaining: remaining, total: total, soonestExpire: soonest,
                         expiringSoonRemaining: expiringSoon, packages: counted)
    }

    private static func packages(in json: [String: Any]) -> [[String: Any]]? {
        let paths: [[String]] = [
            ["data", "Packages"], ["data", "data", "Packages"],
            ["data", "Response", "Data", "Packages"], ["data", "data", "Response", "Data", "Packages"],
            ["data", "packages"], ["data", "data", "packages"]
        ]
        for path in paths {
            if let rows = WBJson.dig(json, path) as? [[String: Any]] { return rows }
        }
        return nil
    }

    private static func firstNumber(_ row: [String: Any], _ keys: [String]) -> Double? {
        for key in keys {
            if let value = WBJson.double(row[key]) { return value }
        }
        return nil
    }

    // MARK: - 派猫猫旅行
    //
    // 对照 Travel.java：只有国内版参与，前缀 /activity/growth/buddy/travel
    //   status → arrived 领奖 / idle 派发 / traveling 跳过
    // 请求头比签到多带 web 平台标识，服务端按这个认「成长中心」来源。

    private static var travelOrigin: String { endpointCN }

    private static func travelURL(_ key: String) -> String {
        travelOrigin + WBRemoteConfig.shared.path(key)
    }

    private static func travelHeaders(_ account: WBAccount) -> [String: String] {
        var headers = authHeaders(account)
        headers["X-Client-Platform"] = "web"
        headers["Origin"] = travelOrigin
        headers["Referer"] = travelOrigin + "/profile/growth-center"
        return headers
    }

    static func travelStatus(_ account: WBAccount) async -> WBTravelStatusResult {
        let resp = await request(travelURL("travel.status"), method: "GET", headers: travelHeaders(account))
        if resp.unauthorized {
            return WBTravelStatusResult.failure(resp.message, unauthorized: true)
        }
        guard resp.ok else {
            return WBTravelStatusResult.failure(resp.message.isEmpty ? "查询旅行状态失败" : resp.message)
        }
        guard let data = resp.json["data"] as? [String: Any] else {
            return WBTravelStatusResult.failure("查询旅行状态失败")
        }
        let state = WBJson.string(data["state"]).lowercased()
        guard ["idle", "traveling", "arrived"].contains(state) else {
            return WBTravelStatusResult.failure(state.isEmpty ? "缺少旅行状态" : "未知旅行状态：\(state)")
        }
        let location = data["location"] as? [String: Any]
        return WBTravelStatusResult(
            ok: true,
            unauthorized: false,
            state: state,
            dailyLimit: WBJson.bool(data["daily_limit_reached"] ?? data["dailyLimitReached"]),
            recordID: WBJson.double(data["record_id"] ?? data["recordId"]) ?? 0,
            arriveAt: WBJson.timestamp(data["arrive_at"] ?? data["arriveAt"]) ?? 0,
            locationName: WBJson.string(location?["name"]),
            rewardCredit: WBJson.double(data["reward_credit"] ?? data["rewardCredit"]),
            message: ""
        )
    }

    static func travelConfig(_ account: WBAccount) async -> WBTravelConfigResult {
        let resp = await request(travelURL("travel.config"), method: "GET", headers: travelHeaders(account))
        if resp.unauthorized {
            return WBTravelConfigResult(ok: false, unauthorized: true, enabled: false,
                                        locations: [], message: resp.message)
        }
        guard resp.ok, let data = resp.json["data"] as? [String: Any] else {
            return WBTravelConfigResult(ok: false, unauthorized: false, enabled: false,
                                        locations: [],
                                        message: resp.message.isEmpty ? "读取旅行配置失败" : resp.message)
        }
        var locations: [WBTravelLocation] = []
        for item in (data["locations"] as? [[String: Any]] ?? []) {
            guard let id = item["id"], !(id is NSNull) else { continue }
            locations.append(WBTravelLocation(id: id, name: WBJson.string(item["name"])))
        }
        let enabled = (data["enabled"] == nil ? true : WBJson.bool(data["enabled"])) && !locations.isEmpty
        return WBTravelConfigResult(ok: true, unauthorized: false, enabled: enabled,
                                    locations: locations, message: "")
    }

    static func travelDepart(_ account: WBAccount, locationID: Any) async -> WBTravelRawResult {
        let resp = await request(travelURL("travel.depart"), method: "POST",
                                 body: ["location_id": locationID],
                                 headers: travelHeaders(account))
        return rawResult(resp)
    }

    static func travelClaim(_ account: WBAccount, recordID: Double) async -> WBTravelRawResult {
        var body: [String: Any] = [:]
        if recordID > 0 { body["record_id"] = recordID }
        let resp = await request(travelURL("travel.claim"), method: "POST", body: body,
                                 headers: travelHeaders(account))
        return rawResult(resp)
    }

    private static func rawResult(_ resp: WBResponse) -> WBTravelRawResult {
        let data = resp.json["data"] as? [String: Any]
        return WBTravelRawResult(
            ok: resp.ok,
            unauthorized: resp.unauthorized,
            code: resp.code,
            state: WBJson.string(data?["state"]).lowercased(),
            message: resp.message,
            rewardCredit: WBJson.double(data?["reward_credit"] ?? data?["rewardCredit"])
        )
    }
}

// MARK: - JSON 小工具

enum WBJson {
    static var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func string(_ value: Any?) -> String {
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    static func bool(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            let lower = text.lowercased()
            return lower == "true" || lower == "1"
        }
        return false
    }

    /// 秒 / 毫秒 / 日期字符串 → 毫秒
    static func timestamp(_ value: Any?) -> Double? {
        if let number = double(value) {
            guard number > 0 else { return nil }
            return number < 10_000_000_000 ? number * 1000 : number
        }
        guard let text = value as? String, !text.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        for pattern in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: text) {
                var stamp = date.timeIntervalSince1970 * 1000
                if pattern == "yyyy-MM-dd" { stamp += 86_399_000 }
                return stamp
            }
        }
        return nil
    }

    static func dig(_ json: [String: Any], _ path: [String]) -> Any? {
        var current: Any = json
        for key in path {
            guard let dict = current as? [String: Any] else { return nil }
            guard let next = dict[key] else { return nil }
            current = next
        }
        return current
    }

    static func amount(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 1
        return formatter.string(from: NSNumber(value: value)) ?? String(Int(value))
    }
}
