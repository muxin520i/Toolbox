import Foundation

// MARK: - 检查更新结果

struct UserscriptUpdateReport {
    /// 有新代码、已经换上的
    var updated: [Userscript] = []
    /// 拉下来比对过，没变化
    var upToDate: [Userscript] = []
    /// 没记来源地址，跳过的
    var skipped: [Userscript] = []
    /// 网络或地址问题
    var failed: [(name: String, reason: String)] = []

    var message: String {
        if updated.isEmpty, upToDate.isEmpty, failed.isEmpty, !skipped.isEmpty {
            return "这些脚本还没记录更新地址。重新装一次，或在编辑页填上脚本的 .user.js 地址，之后就能检查更新了。"
        }

        var parts: [String] = []
        if !updated.isEmpty { parts.append("\(updated.count) 个已更新") }
        if !upToDate.isEmpty { parts.append("\(upToDate.count) 个已是最新") }
        if !skipped.isEmpty { parts.append("\(skipped.count) 个缺更新地址") }
        if !failed.isEmpty { parts.append("\(failed.count) 个失败") }

        var text = parts.isEmpty ? "没有可检查的脚本" : parts.joined(separator: "，")
        if !updated.isEmpty {
            text += "。回到网页刷新一下，新代码才会生效。"
        }
        if let first = failed.first {
            text += "\n\n\(first.name)：\(first.reason)"
        }
        return text
    }
}

enum UserscriptUpdaterError: LocalizedError {
    case badContent

    var errorDescription: String? {
        switch self {
        case .badContent: return "返回的内容不是脚本代码"
        }
    }
}

// MARK: - 检查并换上最新代码

enum UserscriptUpdater {
    /// 逐个检查，progress 回调：(已完成, 总数, 当前脚本名)
    static func check(
        _ scripts: [Userscript],
        progress: @escaping (Int, Int, String) -> Void
    ) async -> UserscriptUpdateReport {
        var report = UserscriptUpdateReport()
        report.skipped = scripts.filter { !$0.hasUpdateSource }
        let targets = scripts.filter { $0.hasUpdateSource }
        guard !targets.isEmpty else { return report }

        for (index, script) in targets.enumerated() {
            progress(index, targets.count, script.displayName)

            // 依次尝试：安装地址 → @updateURL → @downloadURL，任一成功就停
            var latest: (code: String, url: String)?
            var lastError = "下载失败"
            for url in candidateURLs(for: script) {
                do {
                    let code = try await fetch(url)
                    latest = (code, url)
                    break
                } catch {
                    lastError = error.localizedDescription
                }
            }

            if let result = latest {
                if let updated = merge(code: result.code, url: result.url, into: script) {
                    report.updated.append(updated)
                } else {
                    report.upToDate.append(script)
                }
            } else {
                report.failed.append((script.displayName, lastError))
            }

            progress(index + 1, targets.count, script.displayName)
        }

        progress(targets.count, targets.count, "")
        return report
    }

    // MARK: 下载

    private static func fetch(_ url: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            GreasyForkClient.installFromURL(url) { code, _, error in
                if let code = code, code.lowercased().contains("==userscript==") {
                    continuation.resume(returning: code)
                } else if let error = error, !error.isEmpty {
                    continuation.resume(throwing: NSError(
                        domain: "userscript.update",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: error]
                    ))
                } else {
                    continuation.resume(throwing: UserscriptUpdaterError.badContent)
                }
            }
        }
    }

    private static func candidateURLs(for script: Userscript) -> [String] {
        var list: [String] = []

        func add(_ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, !list.contains(value) else { return }
            list.append(value)
        }

        add(script.sourceURL)
        let meta = UserscriptParser.parse(script.code)
        add(meta.updateURL)
        add(meta.downloadURL)
        return list
    }

    // MARK: 比对与合并

    /// 有变化返回新脚本，没变化返回 nil。
    /// 版本号能比就比版本号；版本号缺失时退回比对代码本身。
    private static func merge(code: String, url: String, into script: Userscript) -> Userscript? {
        let meta = UserscriptParser.parse(code)
        let remoteVersion = meta.version ?? ""
        let codeChanged = normalize(code) != normalize(script.code)

        if !remoteVersion.isEmpty, !script.version.isEmpty {
            let order = compareVersions(remoteVersion, script.version)
            if order < 0 { return nil }
            if order == 0 && !codeChanged { return nil }
        } else if !codeChanged {
            return nil
        }

        var copy = script
        if let name = meta.name, !name.isEmpty { copy.name = name }
        if !meta.matches.isEmpty { copy.matches = meta.matches }
        copy.documentStart = meta.documentStart
        copy.code = code
        if !remoteVersion.isEmpty { copy.version = remoteVersion }
        copy.sourceURL = url
        copy.updatedAt = Date()
        return copy
    }

    /// 逐段比较版本号，1.10 > 1.9；非数字段按字符串比
    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let a = versionParts(lhs)
        let b = versionParts(rhs)
        let count = max(a.count, b.count)

        for index in 0..<count {
            let x = index < a.count ? a[index] : "0"
            let y = index < b.count ? b[index] : "0"

            if let xi = Int(x), let yi = Int(y) {
                if xi != yi { return xi < yi ? -1 : 1 }
            } else {
                let result = x.compare(y, options: [.numeric, .caseInsensitive])
                if result != .orderedSame {
                    return result == .orderedAscending ? -1 : 1
                }
            }
        }
        return 0
    }

    private static func versionParts(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func normalize(_ code: String) -> String {
        code
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
