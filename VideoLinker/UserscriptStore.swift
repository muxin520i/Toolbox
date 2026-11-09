import Foundation
import Combine
import GRDB

// MARK: - 用户脚本模型

/// 一条用户脚本，字段对应 Tampermonkey 的元数据头
struct Userscript: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// @match / @include，为空时视为全站
    var matches: [String]
    var code: String
    var enabled: Bool
    /// 对应 @run-at document-start
    var documentStart: Bool
    var updatedAt: Date
    /// 安装时实际下载到脚本代码的地址，检查更新就用它
    var sourceURL: String
    /// 脚本头里的 @version
    var version: String

    init(
        id: UUID = UUID(),
        name: String = "",
        matches: [String] = ["*://*/*"],
        code: String = "",
        enabled: Bool = true,
        documentStart: Bool = false,
        updatedAt: Date = Date(),
        sourceURL: String = "",
        version: String = ""
    ) {
        self.id = id
        self.name = name
        self.matches = matches
        self.code = code
        self.enabled = enabled
        self.documentStart = documentStart
        self.updatedAt = updatedAt
        self.sourceURL = sourceURL
        self.version = version
    }

    // 老版本把脚本以 JSON 存在 UserDefaults 里，没有后加的两个字段。
    // 这里全部用 decodeIfPresent，保证升级后旧数据照样读得出来。
    enum CodingKeys: String, CodingKey {
        case id, name, matches, code, enabled, documentStart, updatedAt, sourceURL, version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        matches = try container.decode([String].self, forKey: .matches)
        code = try container.decode(String.self, forKey: .code)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        documentStart = try container.decode(Bool.self, forKey: .documentStart)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
    }

    var displayName: String {
        name.isEmpty ? "未命名脚本" : name
    }

    var matchSummary: String {
        matches.isEmpty ? "没有匹配规则（不会运行）" : matches.joined(separator: "  ")
    }

    var versionText: String {
        version.isEmpty ? "" : "v\(version)"
    }

    /// 没有来源地址的脚本没法检查更新
    var hasUpdateSource: Bool {
        !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 用于判断是否需要重新注入
    var signature: String {
        "\(id.uuidString)-\(updatedAt.timeIntervalSince1970)-\(enabled)"
    }
}

// MARK: - 解析 Tampermonkey 脚本头

enum UserscriptParser {
    struct Meta {
        var name: String?
        var matches: [String] = []
        var documentStart = false
        var version: String?
        var downloadURL: String?
        var updateURL: String?
        var isEmpty: Bool { name == nil && matches.isEmpty }
    }

    /// 从脚本源码里读出 @name / @match / @include / @run-at
    static func parse(_ text: String) -> Meta {
        var meta = Meta()
        let lines = text.components(separatedBy: .newlines)

        for raw in lines.prefix(60) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // 支持 // @key value 以及块注释里的 @key value
            var body: String
            if line.hasPrefix("//") {
                body = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("*") {
                body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("/") {
                // 块注释的起始行：去掉开头的斜杠和星号，以及行尾的星号斜杠
                var text = String(line.dropFirst())
                while text.hasPrefix("*") { text = String(text.dropFirst()) }
                while text.hasSuffix("*") || text.hasSuffix("/") { text = String(text.dropLast()) }
                body = text.trimmingCharacters(in: .whitespaces)
            } else {
                // 元数据块在文件开头，遇到真正的代码就停
                break
            }

            guard body.hasPrefix("@") else { continue }
            body = String(body.dropFirst())

            let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let key = parts.first?.lowercased() else { continue }
            let value = parts.count > 1
                ? String(parts[1]).trimmingCharacters(in: .whitespaces)
                : ""

            switch key {
            case "name":
                if meta.name == nil, !value.isEmpty { meta.name = value }
            case "match", "include":
                if !value.isEmpty { meta.matches.append(value) }
            case "run-at":
                if value.contains("document-start") { meta.documentStart = true }
            case "version":
                if meta.version == nil, !value.isEmpty { meta.version = value }
            case "downloadurl":
                if meta.downloadURL == nil, !value.isEmpty { meta.downloadURL = value }
            case "updateurl":
                if meta.updateURL == nil, !value.isEmpty { meta.updateURL = value }
            default:
                break
            }
        }

        return meta
    }
}

// MARK: - 持久化

enum UserscriptStore {
    private static let key = "userscripts.v1"

    private struct Row: Codable, FetchableRecord {
        var id: String
        var name: String
        var matches: String
        var code: String
        var enabled: Int
        var documentStart: Int
        var updatedAt: Double
        var sourceURL: String
        var version: String
    }

    static func load() -> [Userscript] {
        if let rows = AppDB.read({ db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, matches, code, enabled, documentStart, updatedAt,
                           sourceURL, version
                    FROM script ORDER BY position ASC
                    """
            )
        }) {
            return rows.compactMap { row -> Userscript? in
                guard let scriptID = UUID(uuidString: row.id) else { return nil }
                let patterns = (try? JSONDecoder().decode([String].self, from: Data(row.matches.utf8))) ?? []
                return Userscript(
                    id: scriptID,
                    name: row.name,
                    matches: patterns,
                    code: row.code,
                    enabled: row.enabled != 0,
                    documentStart: row.documentStart != 0,
                    updatedAt: Date(timeIntervalSince1970: row.updatedAt),
                    sourceURL: row.sourceURL,
                    version: row.version
                )
            }
        }
        return legacyLoad()
    }

    static func save(_ scripts: [Userscript]) {
        AppDB.write { db in
            try db.execute(sql: "DELETE FROM script")
            for (index, script) in scripts.enumerated() {
                let patterns = (try? JSONEncoder().encode(script.matches))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO script
                        (id, name, matches, code, enabled, documentStart, updatedAt,
                         sourceURL, version, position)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        script.id.uuidString, script.name, patterns, script.code,
                        script.enabled ? 1 : 0, script.documentStart ? 1 : 0,
                        script.updatedAt.timeIntervalSince1970,
                        script.sourceURL, script.version, index
                    ]
                )
            }
        }

        if let data = try? JSONEncoder().encode(scripts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 老脚本（这个版本之前装的）没有来源地址，但代码头里通常带着
    /// @downloadURL / @updateURL，用它们补上，升级完就能直接检查更新。
    static func backfill(_ scripts: [Userscript]) -> [Userscript] {
        scripts.map { script in
            guard script.sourceURL.isEmpty || script.version.isEmpty else { return script }
            let meta = UserscriptParser.parse(script.code)
            var copy = script
            if copy.sourceURL.isEmpty {
                copy.sourceURL = meta.updateURL ?? meta.downloadURL ?? ""
            }
            if copy.version.isEmpty, let value = meta.version {
                copy.version = value
            }
            return copy
        }
    }

    private static func legacyLoad() -> [Userscript] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Userscript].self, from: data)) ?? []
    }
}

// MARK: - 共享的脚本库

/// 全局唯一的数据源。设置页、脚本列表、注入逻辑都读这一份，
/// 避免各自持有副本导致“装了脚本还显示未安装”。
final class UserscriptLibrary: ObservableObject {
    static let shared = UserscriptLibrary()

    @Published private(set) var scripts: [Userscript]

    private init() {
        let loaded = UserscriptStore.load()
        let filled = UserscriptStore.backfill(loaded)
        scripts = filled
        if filled != loaded {
            UserscriptStore.save(filled)
        }
    }

    /// 真正会被注入执行的脚本数量
    var activeCount: Int {
        scripts.filter { $0.enabled && !$0.code.isEmpty }.count
    }

    /// 装了但全关掉的情况，用于给出更准确的提示
    var statusText: String {
        if scripts.isEmpty { return "未安装" }
        if activeCount == 0 { return "已装 \(scripts.count) 个，全部关闭" }
        return "\(activeCount) 个运行中"
    }

    func upsert(_ script: Userscript) {
        var copy = scripts
        if let index = copy.firstIndex(where: { $0.id == script.id }) {
            copy[index] = script
        } else {
            copy.append(script)
        }
        commit(copy)
    }

    func remove(_ script: Userscript) {
        commit(scripts.filter { $0.id != script.id })
    }

    func setEnabled(_ enabled: Bool, for script: Userscript) {
        var copy = scripts
        guard let index = copy.firstIndex(where: { $0.id == script.id }) else { return }
        copy[index].enabled = enabled
        commit(copy)
    }

    /// 检查更新时批量写回，一次落库，不逐条提交
    func apply(_ updated: [Userscript]) {
        guard !updated.isEmpty else { return }
        var copy = scripts
        for script in updated {
            if let index = copy.firstIndex(where: { $0.id == script.id }) {
                copy[index] = script
            } else {
                copy.append(script)
            }
        }
        commit(copy)
    }

    private func commit(_ next: [Userscript]) {
        scripts = next
        UserscriptStore.save(next)
    }
}

// MARK: - 注入代码生成

enum UserscriptEngine {
    /// 参数名，用户脚本里直接用这些名字就能调
    private static let apiNames = [
        "GM_info",
        "GM_addStyle",
        "GM_log",
        "GM_setValue",
        "GM_getValue",
        "GM_deleteValue",
        "GM_listValues",
        "GM_xmlhttpRequest",
        "GM_notification",
        "GM_registerMenuCommand",
        "GM_unregisterMenuCommand",
        "GM_openInTab",
        "GM_getResourceText",
        "GM_download"
    ]

    /// 把一条脚本编译成可以交给 WKUserScript 的 JS。
    /// 结构：匹配网址 → 取到 GM 接口 → 在函数作用域里执行脚本代码。
    /// 用函数参数注入 GM_*，脚本里就能像油猴一样直接调用。
    static func injectionJS(for script: Userscript) -> String {
        let patterns = script.matches.isEmpty ? ["*://*/*"] : script.matches
        let json = encodeArray(patterns)
        let name = escape(script.displayName)
        let scope = script.id.uuidString
        let values = GMBridge.shared.valuesJSON(for: scope)

        var js = ""
        js += "(function(){"
        js += "var href=location.href;var pats=\(json);"
        js += "function m(p){"
        js += "if(p.length>2&&p.charAt(0)==='/'&&p.charAt(p.length-1)==='/'){"
        js += "try{return new RegExp(p.slice(1,-1)).test(href);}catch(e){return false;}"
        js += "}"
        js += "var r=p.replace(/[.+?^${}()|[\\]\\\\]/g,'\\\\$&').replace(/\\*/g,'.*');"
        js += "try{return new RegExp('^'+r+'$').test(href);}catch(e){return false;}"
        js += "}"
        js += "var ok=false;"
        js += "for(var i=0;i<pats.length;i++){if(m(pats[i])){ok=true;break;}}"
        js += "if(!ok){return;}"

        js += "var __G=(typeof window.__vlGMFactory==='function')"
        js += "?window.__vlGMFactory('\(scope)',\(values)):{};"

        js += "function __vlrun(){try{"
        js += "(function(\(apiNames.joined(separator: ",")),unsafeWindow){"
        js += script.code
        js += "})("
        js += apiNames.map { "__G.\($0)" }.joined(separator: ",")
        js += ",__G.unsafeWindow||window);"
        js += "}catch(e){console.error('[油猴脚本] \(name)',e);}}"

        if script.documentStart {
            js += "__vlrun();"
        } else {
            js += "if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',__vlrun);}else{__vlrun();}"
        }
        js += "})();"
        return js
    }

    private static func encodeArray(_ items: [String]) -> String {
        guard let data = try? JSONEncoder().encode(items),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
