import Foundation
import SwiftUI

// MARK: - 派猫猫旅行：模型

struct WBTravelLocation {
    var id: Any
    var name: String
}

struct WBTravelStatusResult {
    var ok: Bool
    var unauthorized: Bool
    var state: String
    var dailyLimit: Bool
    var recordID: Double
    var arriveAt: Double
    var locationName: String
    var rewardCredit: Double?
    var message: String

    static func failure(_ message: String, unauthorized: Bool = false) -> WBTravelStatusResult {
        WBTravelStatusResult(ok: false, unauthorized: unauthorized, state: "", dailyLimit: false,
                             recordID: 0, arriveAt: 0, locationName: "", rewardCredit: nil,
                             message: message)
    }
}

struct WBTravelConfigResult {
    var ok: Bool
    var unauthorized: Bool
    var enabled: Bool
    var locations: [WBTravelLocation]
    var message: String
}

struct WBTravelRawResult {
    var ok: Bool
    var unauthorized: Bool
    var code: Int
    var state: String
    var message: String
    var rewardCredit: Double?
}

struct WBTravelActionResult {
    var ok: Bool
    var already: Bool = false
    var claimed: Bool = false
    var skip: String?
    var state: String = ""
    var message: String = ""
    var locationName: String = ""
    var arriveAt: Double = 0
    var rewardCredit: Double?

    static func failure(_ message: String, skip: String? = nil) -> WBTravelActionResult {
        WBTravelActionResult(ok: false, skip: skip, message: message)
    }
}

// MARK: - 行状态

enum WBTravelKind {
    case querying
    case canDispatch
    case canClaim
    case traveling
    case dailyLimit
    case unsupported
    case failed

    var badge: String {
        switch self {
        case .querying: return "查询中"
        case .canDispatch: return "可派发"
        case .canClaim: return "可领奖"
        case .traveling: return "旅行中"
        case .dailyLimit: return "今日已派"
        case .unsupported: return "不适用"
        case .failed: return "失败"
        }
    }
}

struct WBTravelRow: Identifiable {
    var id: String
    var name: String
    var initial: String
    var international: Bool
    var querying = true
    var ok = true
    var state = ""
    var dailyLimit = false
    var recordID: Double = 0
    var arriveAt: Double = 0
    var locationName = ""
    var rewardCredit: Double?
    var skip = ""
    var message = ""

    var kind: WBTravelKind {
        if international { return .unsupported }
        if querying { return .querying }
        if !ok { return .failed }
        if skip == "unsupported" { return .unsupported }
        if state == "traveling" { return .traveling }
        if state == "arrived" { return .canClaim }
        if state == "idle" {
            return (dailyLimit || skip == "daily-limit") ? .dailyLimit : .canDispatch
        }
        return .failed
    }

    var arriveText: String? {
        guard arriveAt > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: arriveAt / 1000))
    }

    var subtitle: String {
        switch kind {
        case .querying:
            return "正在查询旅行状态…"
        case .canDispatch:
            return locationName.isEmpty ? "今天还没出门" : "上次旅行：\(locationName)"
        case .canClaim:
            return locationName.isEmpty ? "奖励已到达，点上面领取" : "\(locationName) · 等你领奖"
        case .traveling:
            var text = locationName.isEmpty ? "旅行中…" : locationName
            if let time = arriveText { text += " · 预计 \(time) 到达" }
            return text
        case .dailyLimit:
            return "今天已经派过了"
        case .unsupported:
            return "国际版账号，不参与这个活动"
        case .failed:
            return message.isEmpty ? "查询失败，稍后重试" : message
        }
    }
}

// MARK: - 旅行状态中枢

@MainActor
final class WBTravelStore: ObservableObject {
    static let shared = WBTravelStore()

    @Published private(set) var rows: [WBTravelRow] = []
    @Published private(set) var running = false
    @Published private(set) var loading = false
    @Published private(set) var lastUpdated: Date?
    @Published var toast: String?

    private init() {}

    // MARK: 汇总

    var canDispatch: Int { rows.filter { $0.kind == .canDispatch }.count }
    var canClaim: Int { rows.filter { $0.kind == .canClaim }.count }
    var traveling: Int { rows.filter { $0.kind == .traveling }.count }
    var actionable: Int { canDispatch + canClaim }

    var headline: String {
        if rows.isEmpty { return "先去添加一个账号" }
        if canClaim > 0 { return "猫猫带着礼物回来了" }
        if canDispatch > 0 { return "猫猫在家，等你派它出门" }
        if traveling > 0 { return "猫猫正在路上" }
        if rows.contains(where: { $0.kind == .dailyLimit }) { return "今天都安排好了" }
        return "暂时没有可安排的猫猫"
    }

    var modeText: String {
        if canClaim > 0 { return "领取奖励" }
        if canDispatch > 0 { return "立即派发" }
        if traveling > 0 { return "等待归来" }
        return "暂无可用"
    }

    var buttonEnabled: Bool {
        actionable > 0 && !running && !loading
    }

    var updateText: String {
        guard let lastUpdated else { return "页面停留期间每 60 秒自动刷新" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return "更新于 \(formatter.string(from: lastUpdated)) · 每 60 秒自动刷新"
    }

    // MARK: 账号同步

    /// 把账号列表同步到行（保留已有状态，新增的置为查询中）
    func syncAccounts() {
        let accounts = WBCheckinStore.shared.accounts
        var next: [WBTravelRow] = []
        for account in accounts {
            if var old = rows.first(where: { $0.id == account.id }) {
                old.name = account.displayName
                old.initial = account.initial
                old.international = account.isInternational
                next.append(old)
            } else {
                next.append(WBTravelRow(id: account.id,
                                        name: account.displayName,
                                        initial: account.initial,
                                        international: account.isInternational))
            }
        }
        rows = next
    }

    // MARK: 查询

    func load() async {
        syncAccounts()
        guard !running, !loading else { return }
        guard !rows.isEmpty else {
            lastUpdated = nil
            return
        }

        loading = true
        defer { loading = false }

        let accounts = WBCheckinStore.shared.accounts
        for account in accounts where !account.isInternational {
            if account.needsRelogin {
                apply(WBTravelActionResult.failure(account.reloginReason ?? "登录已失效，请重新登录"), for: account.id)
                continue
            }

            var current = account
            if WBApi.isTokenStale(current), current.refreshToken != nil,
               let refreshed = await WBApi.refresh(current) {
                current = refreshed
                WBCheckinStore.shared.update(refreshed)
            }

            let status = await WBApi.travelStatus(current)
            if status.unauthorized {
                apply(WBTravelActionResult.failure("登录凭证已失效，请重新登录"), for: account.id)
            } else if status.ok {
                apply(status, for: account.id)
            } else {
                apply(WBTravelActionResult.failure(status.message), for: account.id)
            }
        }

        lastUpdated = Date()
    }

    // MARK: 执行

    func runAll() async {
        syncAccounts()
        guard !running else { return }
        guard !rows.isEmpty else {
            toast = "先添加一个账号"
            return
        }

        running = true
        defer { running = false }
        toast = canClaim > 0 ? "正在领猫猫带回来的奖励…" : "正在派猫猫出门…"

        var dispatched = 0
        var claimed = 0
        var skipped = 0
        var failed = 0

        for account in WBCheckinStore.shared.accounts {
            if account.isInternational {
                skipped += 1
                continue
            }
            if account.needsRelogin {
                failed += 1
                apply(WBTravelActionResult.failure(account.reloginReason ?? "登录已失效，请重新登录"), for: account.id)
                continue
            }

            var current = account
            if WBApi.isTokenStale(current), current.refreshToken != nil,
               let refreshed = await WBApi.refresh(current) {
                current = refreshed
                WBCheckinStore.shared.update(refreshed)
            }

            let result = await syncOne(current)
            apply(result, for: account.id)

            if !result.ok {
                failed += 1
            } else if result.claimed {
                claimed += 1
            } else if result.already {
                skipped += 1
            } else {
                dispatched += 1
            }
        }

        lastUpdated = Date()

        var parts: [String] = []
        if dispatched > 0 { parts.append("派发 \(dispatched)") }
        if claimed > 0 { parts.append("领奖 \(claimed)") }
        if skipped > 0 { parts.append("跳过 \(skipped)") }
        if failed > 0 { parts.append("失败 \(failed)") }
        toast = parts.isEmpty ? "没有需要处理的账号" : "旅行完成：" + parts.joined(separator: " · ")
    }

    /// 单个账号走一遍：查状态 → 领奖 / 跳过 / 派发
    private func syncOne(_ account: WBAccount) async -> WBTravelActionResult {
        let status = await WBApi.travelStatus(account)
        if status.unauthorized {
            return .failure("登录凭证已失效，请重新登录")
        }
        guard status.ok else {
            return .failure(status.message.isEmpty ? "查询旅行状态失败" : status.message)
        }

        switch status.state {
        case "arrived":
            let claim = await WBApi.travelClaim(account, recordID: status.recordID)
            if claim.ok {
                return WBTravelActionResult(ok: true, claimed: true, state: "idle",
                                            message: "领取成功",
                                            locationName: status.locationName,
                                            arriveAt: status.arriveAt,
                                            rewardCredit: claim.rewardCredit ?? status.rewardCredit)
            }
            let lower = claim.message.lowercased()
            if lower.contains("no unclaimed travel") || lower.contains("daily_limit") {
                return WBTravelActionResult(ok: true, claimed: true, state: "idle",
                                            message: "已领取")
            }
            if lower.contains("not arrived yet") {
                return WBTravelActionResult(ok: true, already: true, state: "arrived",
                                            message: "尚未到达",
                                            locationName: status.locationName,
                                            arriveAt: status.arriveAt)
            }
            return .failure(claim.message.isEmpty ? "领取失败" : claim.message, skip: "claim-error")

        case "traveling":
            return WBTravelActionResult(ok: true, already: true, state: "traveling",
                                        message: "已在旅行中",
                                        locationName: status.locationName,
                                        arriveAt: status.arriveAt,
                                        rewardCredit: status.rewardCredit)

        default:
            if status.dailyLimit {
                return WBTravelActionResult(ok: true, already: true, skip: "daily-limit",
                                            state: "idle", message: "今日已派")
            }

            let config = await WBApi.travelConfig(account)
            guard config.ok else {
                return .failure(config.message.isEmpty ? "读取旅行配置失败" : config.message,
                                skip: "config-error")
            }
            guard config.enabled else {
                return .failure("当前没有可去的地方", skip: "no-location")
            }

            for location in config.locations {
                let depart = await WBApi.travelDepart(account, locationID: location.id)
                if depart.ok {
                    return WBTravelActionResult(ok: true,
                                                state: depart.state.isEmpty ? "traveling" : depart.state,
                                                locationName: location.name)
                }

                let lower = depart.message.lowercased()
                if lower.contains("already traveling") {
                    return WBTravelActionResult(ok: true, already: true, state: "traveling",
                                                message: "已在旅行中",
                                                locationName: location.name)
                }
                if lower.contains("daily limit") || lower.contains("daily_limit") {
                    return WBTravelActionResult(ok: true, already: true, skip: "daily-limit",
                                                state: "idle", message: "今日已派")
                }
                if lower.contains("no active buddy") {
                    return .failure("还没有猫猫，先去官网领养一只", skip: "no-buddy")
                }
                if !depart.message.isEmpty {
                    return .failure(depart.message, skip: "depart-error")
                }
            }
            return .failure("派发失败")
        }
    }

    // MARK: 回写

    private func apply(_ status: WBTravelStatusResult, for id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].querying = false
        rows[index].ok = true
        rows[index].state = status.state
        rows[index].dailyLimit = status.dailyLimit
        rows[index].recordID = status.recordID
        rows[index].arriveAt = status.arriveAt
        rows[index].locationName = status.locationName
        rows[index].rewardCredit = status.rewardCredit
        rows[index].skip = ""
        rows[index].message = ""
    }

    private func apply(_ result: WBTravelActionResult, for id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].querying = false
        rows[index].ok = result.ok
        rows[index].state = result.state
        rows[index].dailyLimit = result.skip == "daily-limit"
        rows[index].skip = result.skip ?? ""
        rows[index].message = result.message
        if !result.locationName.isEmpty { rows[index].locationName = result.locationName }
        if result.arriveAt > 0 { rows[index].arriveAt = result.arriveAt }
        if result.claimed { rows[index].arriveAt = 0 }
        if let credit = result.rewardCredit { rows[index].rewardCredit = credit }
    }
}
