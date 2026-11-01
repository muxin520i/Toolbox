import Foundation

// MARK: - WB 签到：账号与日志
//
// 协议来自开源项目 wb-checkin-android（MIT），它又是 workbuddy-switch 的移植。
// 这里只做 iOS 端需要的部分：账号、签到、积分、日志。
//
// 账号文件写在 Application Support 下，**不能放 Documents**——那边开了
// UIFileSharingEnabled，用户连电脑就能看到 token。

struct WBAccount: Codable, Identifiable, Equatable {
    var id: String
    var uid: String?
    var nickname: String?
    var email: String?
    var enterpriseId: String?
    var enterpriseName: String?
    var accessToken: String
    var refreshToken: String?
    var domain: String?
    /// "cn" 国内版（codebuddy.cn） / "ai" 国际版（workbuddy.ai）
    var variant: String
    /// 毫秒时间戳
    var expiresAt: Double?
    var refreshExpiresAt: Double?
    var createdAt: Double
    var needsRelogin: Bool
    var reloginReason: String?

    var isInternational: Bool { variant == "ai" }

    var displayName: String {
        let nick = (nickname ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !nick.isEmpty { return nick }
        let mail = (email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !mail.isEmpty { return mail }
        let u = (uid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return u.isEmpty ? "未命名账号" : u
    }

    var subtitle: String {
        let mail = (email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !mail.isEmpty, mail != displayName { return mail }
        let ent = (enterpriseName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !ent.isEmpty { return ent }
        return isInternational ? "国际版" : "国内版"
    }

    var initial: String {
        let name = displayName
        guard let first = name.first else { return "W" }
        return String(first).uppercased()
    }

    var tokenExpireText: String {
        guard let expiresAt else { return "有效期未知" }
        let date = Date(timeIntervalSince1970: expiresAt / 1000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return "登录有效期至 " + f.string(from: date)
    }
}

struct WBLogEntry: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    /// 毫秒时间戳
    var ts: Double
    var accountId: String
    var name: String
    /// success / already / error / skipped
    var result: String
    var message: String?

    var resultText: String {
        switch result {
        case "success": return "签到成功"
        case "already": return "今天已签过"
        case "skipped": return "已跳过"
        default: return "失败"
        }
    }

    var timeText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M/d HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts / 1000))
    }
}

// MARK: - 存储

enum WBStore {
    private static let folderName = "WBCheckin"

    static func folder() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static var accountsURL: URL { folder().appendingPathComponent("accounts.json") }
    private static var logsURL: URL { folder().appendingPathComponent("logs.json") }

    static func loadAccounts() -> [WBAccount] {
        guard let data = try? Data(contentsOf: accountsURL) else { return [] }
        return (try? JSONDecoder().decode([WBAccount].self, from: data)) ?? []
    }

    static func saveAccounts(_ accounts: [WBAccount]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        write(data, to: accountsURL)
    }

    static func loadLogs() -> [WBLogEntry] {
        guard let data = try? Data(contentsOf: logsURL) else { return [] }
        return (try? JSONDecoder().decode([WBLogEntry].self, from: data)) ?? []
    }

    static func saveLogs(_ logs: [WBLogEntry]) {
        guard let data = try? JSONEncoder().encode(logs) else { return }
        write(data, to: logsURL)
    }

    private static func write(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: [.atomic])
            // 设备解锁一次后可读，锁屏期间签到任务也能用
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            // 写不进去就保持内存态，下次再试
        }
    }
}

// MARK: - 设置项

enum WBDefaults {
    static let autoCheckin = "wb.autoCheckin"
    static let autoDay = "wb.autoDay"

    static var autoEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoCheckin) == nil { return true }
            return UserDefaults.standard.bool(forKey: autoCheckin)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckin) }
    }
}
