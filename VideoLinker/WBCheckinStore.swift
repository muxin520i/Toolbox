import Foundation
import SwiftUI

// MARK: - 签到状态中枢

@MainActor
final class WBCheckinStore: ObservableObject {
    static let shared = WBCheckinStore()

    enum AccountState: Equatable {
        case unknown
        case unchecked
        case checked
        case relogin
        case unsupported
        case failed(String)

        var text: String {
            switch self {
            case .unknown: return "未检测"
            case .unchecked: return "未签到"
            case .checked: return "已签到"
            case .relogin: return "需重新登录"
            case .unsupported: return "不支持签到"
            case .failed: return "查询失败"
            }
        }
    }

    @Published private(set) var accounts: [WBAccount] = []
    @Published private(set) var logs: [WBLogEntry] = []
    @Published private(set) var states: [String: AccountState] = [:]
    @Published private(set) var credits: [String: WBCredits] = [:]
    @Published private(set) var running: Set<String> = []
    @Published private(set) var runningAll = false
    @Published var toast: String?

    private var lastAppear: TimeInterval = 0

    private init() {
        accounts = WBStore.loadAccounts()
        logs = WBStore.loadLogs()
    }

    // MARK: 统计

    var checkedCount: Int {
        accounts.reduce(0) { $0 + (states[$1.id] == .checked ? 1 : 0) }
    }

    var hasPendingAccount: Bool {
        accounts.contains { $0.needsRelogin }
    }

    // MARK: 生命周期

    /// 进页面时调用：拉状态 → 需要时自动补签，60 秒内不重复
    func onAppear() async {
        let now = Date().timeIntervalSince1970
        guard now - lastAppear > 60 else { return }
        lastAppear = now

        await refreshStates()
        await autoCheckinIfNeeded()
        await loadAllCredits()
    }

    func refreshAll() async {
        await refreshStates()
        await loadAllCredits()
    }

    // MARK: 账号

    func add(_ account: WBAccount) {
        var stored = account
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            stored.id = accounts[index].id
            accounts[index] = stored
        } else if let index = accounts.firstIndex(where: { same($0, account) }) {
            // 同一个 uid 重复登录：覆盖凭证，不新增一条
            stored.id = accounts[index].id
            accounts[index] = stored
        } else {
            accounts.append(stored)
        }
        persist()
        states[stored.id] = .unknown
        credits[stored.id] = nil
        toast = "已添加「\(stored.displayName)」"
    }

    func delete(_ id: String) {
        accounts.removeAll { $0.id == id }
        states[id] = nil
        credits[id] = nil
        clearCheckedToday(id)
        persist()
    }

    func update(_ account: WBAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        persist()
    }

    private func same(_ a: WBAccount, _ b: WBAccount) -> Bool {
        guard let ua = a.uid, let ub = b.uid, !ua.isEmpty else { return false }
        return ua == ub
    }

    private func persist() {
        WBStore.saveAccounts(accounts)
    }

    // MARK: 状态

    func refreshStates() async {
        for account in accounts {
            await refreshState(account.id)
        }
    }

    func refreshState(_ id: String) async {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        if account.isInternational {
            states[id] = .unsupported
            return
        }
        if account.needsRelogin {
            states[id] = .relogin
            return
        }

        var current = account
        if WBApi.isTokenStale(current), current.refreshToken != nil {
            if let refreshed = await WBApi.refresh(current) {
                current = refreshed
                update(refreshed)
            }
        }

        let status = await WBApi.checkinStatus(current)
        if status.unauthorized {
            markRelogin(current, reason: "登录凭证已失效，请重新登录")
            return
        }
        if status.unsupported {
            states[id] = .unknown
            return
        }
        guard status.ok else {
            states[id] = .failed(status.message)
            return
        }
        // 服务端状态可能比签到结果晚一步，本机今天签过的算已签到，避免刷新后回退
        states[id] = (status.checked || isCheckedToday(id)) ? .checked : .unchecked
    }

    // MARK: 签到

    func checkin(_ id: String, silent: Bool = false) async {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        guard !running.contains(id) else { return }

        if account.isInternational {
            states[id] = .unsupported
            return
        }
        if account.needsRelogin {
            states[id] = .relogin
            if !silent { toast = "「\(account.displayName)」需要重新登录" }
            return
        }
        // 已经明确签到过的不用再打一次接口
        if states[id] == .checked {
            if !silent { toast = "「\(account.displayName)」今天已经签过了" }
            return
        }

        running.insert(id)
        defer { running.remove(id) }

        var current = account
        if WBApi.isTokenStale(current), current.refreshToken != nil {
            if let refreshed = await WBApi.refresh(current) {
                current = refreshed
                update(refreshed)
            }
        }

        let status = await WBApi.checkinStatus(current)
        if status.unauthorized {
            markRelogin(current, reason: "登录凭证已失效，请重新登录")
            return
        }
        if status.ok, status.checked {
            states[id] = .checked
            markCheckedToday(id)
            appendLog(current, result: "already", message: nil)
            if !silent { toast = "「\(current.displayName)」今天已经签过了" }
            return
        }
        if !status.ok, !status.unsupported {
            states[id] = .failed(status.message)
            appendLog(current, result: "error", message: status.message)
            if !silent { toast = "签到失败：\(status.message)" }
            return
        }

        let result = await WBApi.performCheckin(current)
        if result.ok {
            states[id] = .checked
            markCheckedToday(id)
            appendLog(current, result: result.already ? "already" : "success", message: nil)
            // 签完积分会变，顺手刷一次
            if !result.already { await loadCredits(current.id) }
            if !silent {
                toast = result.already
                    ? "「\(current.displayName)」今天已经签过了"
                    : "「\(current.displayName)」签到成功"
            }
        } else {
            states[id] = .failed(result.message)
            appendLog(current, result: "error", message: result.message)
            if !silent { toast = "签到失败：\(result.message)" }
        }
    }

    func checkinAll(silent: Bool = false) async {
        guard !runningAll else { return }
        guard !accounts.isEmpty else {
            if !silent { toast = "先添加一个账号" }
            return
        }
        runningAll = true
        for account in accounts {
            await checkin(account.id, silent: true)
        }
        runningAll = false

        if !silent {
            toast = "完成：\(checkedCount)/\(accounts.count) 已签到"
        }
    }

    func autoCheckinIfNeeded() async {
        guard WBDefaults.autoEnabled, !accounts.isEmpty else { return }
        let today = Self.dayKey()
        if UserDefaults.standard.string(forKey: WBDefaults.autoDay) == today { return }
        UserDefaults.standard.set(today, forKey: WBDefaults.autoDay)
        await checkinAll(silent: true)
    }

    // MARK: 积分

    func loadAllCredits() async {
        for account in accounts {
            if account.needsRelogin { continue }
            if let result = await WBApi.credits(account) {
                credits[account.id] = result
            }
        }
    }

    func loadCredits(_ id: String) async {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        if let result = await WBApi.credits(account) {
            credits[id] = result
        }
    }

    // MARK: 私有

    // MARK: 今日已签到（本地兜底）

    private static let checkedDayKey = "video.wb.checkedDay.v1"

    private func markCheckedToday(_ id: String) {
        var map = UserDefaults.standard.dictionary(forKey: Self.checkedDayKey) as? [String: String] ?? [:]
        map[id] = Self.dayKey()
        UserDefaults.standard.set(map, forKey: Self.checkedDayKey)
    }

    private func isCheckedToday(_ id: String) -> Bool {
        let map = UserDefaults.standard.dictionary(forKey: Self.checkedDayKey) as? [String: String] ?? [:]
        return map[id] == Self.dayKey()
    }

    private func clearCheckedToday(_ id: String) {
        var map = UserDefaults.standard.dictionary(forKey: Self.checkedDayKey) as? [String: String] ?? [:]
        guard map[id] != nil else { return }
        map[id] = nil
        UserDefaults.standard.set(map, forKey: Self.checkedDayKey)
    }

    private func markRelogin(_ account: WBAccount, reason: String) {
        var updated = account
        updated.needsRelogin = true
        updated.reloginReason = reason
        update(updated)
        states[account.id] = .relogin
    }

    private func appendLog(_ account: WBAccount, result: String, message: String?) {
        let entry = WBLogEntry(
            ts: WBJson.nowMs,
            accountId: account.id,
            name: account.displayName,
            result: result,
            message: message
        )
        logs.insert(entry, at: 0)
        if logs.count > 100 { logs = Array(logs.prefix(100)) }
        WBStore.saveLogs(logs)
    }

    static func dayKey() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
