import SwiftUI
import Foundation
import UIKit

// MARK: - Greasy Fork 数据

struct GreasyScript: Identifiable, Equatable {
    let id: String
    let name: String
    let summary: String
    let detailURL: String
    let codeURL: String
    let installs: Int

    var installsText: String {
        if installs >= 10000 {
            return String(format: "%.1f 万次安装", Double(installs) / 10000)
        }
        return "\(installs) 次安装"
    }
}

// MARK: - 网络

enum GreasyForkClient {
    static let host = "https://greasyfork.org"

    private static let agent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 搜索脚本。query 为空时取最新发布的一批
    static func search(_ query: String, completion: @escaping ([GreasyScript]?, String?) -> Void) {
        var comps = URLComponents(string: host + "/zh-CN/scripts.json")
        if !query.isEmpty {
            comps?.queryItems = [URLQueryItem(name: "q", value: query)]
        }
        guard let url = comps?.url else {
            completion(nil, "搜索地址无效")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                main { completion(nil, "网络不可用：\(error.localizedDescription)") }
                return
            }

            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data, !data.isEmpty else {
                main { completion(nil, "服务器没有返回内容（HTTP \(code)）") }
                return
            }

            if code == 403 || code == 503 {
                main { completion(nil, "Greasy Fork 暂时拒绝了请求（HTTP \(code)），用下面的「粘贴链接安装」会更稳") }
                return
            }

            do {
                let list = try parseSearch(data)
                main { completion(list, list.isEmpty ? "没有找到匹配的脚本" : nil) }
            } catch {
                main { completion(nil, "返回内容无法解析，站点可能调整了接口") }
            }
        }.resume()
    }

    static func parseSearch(_ data: Data) throws -> [GreasyScript] {
        let root = try JSONSerialization.jsonObject(with: data)

        let raw: [[String: Any]]
        if let array = root as? [[String: Any]] {
            raw = array
        } else if let dict = root as? [String: Any],
                  let array = (dict["scripts"] ?? dict["data"]) as? [[String: Any]] {
            raw = array
        } else {
            throw NSError(domain: "greasyfork", code: -1)
        }

        return raw.compactMap { item -> GreasyScript? in
            let name = (item["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return nil }

            let detail = absolute(item["url"] as? String)
            let code = absolute(item["code_url"] as? String ?? item["codeUrl"] as? String)
            let id = "\(item["id"] ?? detail)"

            let summary = (item["description"] as? String) ?? ""
            var installs = 0
            if let value = item["total_installs"] as? Int {
                installs = value
            } else if let value = item["total_installs"] as? Double {
                installs = Int(value)
            }

            return GreasyScript(
                id: id,
                name: name,
                summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                detailURL: detail,
                codeURL: code,
                installs: installs
            )
        }
    }

    // MARK: 安装

    static func install(_ script: GreasyScript, completion: @escaping (String?, String?) -> Void) {
        if !script.codeURL.isEmpty {
            download(script.codeURL, completion: completion)
            return
        }
        guard !script.detailURL.isEmpty else {
            completion(nil, "这个脚本没有提供下载地址")
            return
        }
        resolve(detailURL: script.detailURL, completion: completion)
    }

    /// 用户自己贴的地址：直链直接下，页面地址先找安装链接
    static func installFromURL(_ urlString: String, completion: @escaping (String?, String?) -> Void) {
        if urlString.contains(".user.js") {
            download(urlString, completion: completion)
        } else {
            resolve(detailURL: urlString, completion: completion)
        }
    }

    private static func resolve(detailURL: String, completion: @escaping (String?, String?) -> Void) {
        fetchText(detailURL) { html, error in
            guard let html = html else {
                completion(nil, error)
                return
            }
            guard let link = findInstallLink(in: html, base: detailURL) else {
                completion(nil, "页面里没找到安装链接，可以复制脚本的 .user.js 地址后用「粘贴脚本链接安装」")
                return
            }
            download(link, completion: completion)
        }
    }

    static func findInstallLink(in html: String, base: String = "") -> String? {
        let patterns = [
            #"https://update\.greasyfork\.org/scripts/[^"'\s]+\.user\.js"#,
            #"https://greasyfork\.org/scripts/[^"'\s]+\.user\.js"#,
            #"href="[^"]*\.user\.js[^"]*""#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else {
                continue
            }
            var found = (html as NSString).substring(with: match.range)
            if found.hasPrefix("href=\"") {
                found = String(found.dropFirst(6).dropLast())
            }
            found = found.replacingOccurrences(of: "&amp;", with: "&")
            if found.hasPrefix("/") {
                // 用详情页所在的域名拼，镜像站也能对上
                if let url = URL(string: base), let scheme = url.scheme, let h = url.host {
                    found = scheme + "://" + h + found
                } else {
                    found = host + found
                }
            }
            if found.contains(".user.js") { return found }
        }
        return nil
    }

    private static func fetchText(_ urlString: String, completion: @escaping (String?, String?) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(nil, "地址无效")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(agent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                main { completion(nil, "网络不可用：\(error.localizedDescription)") }
                return
            }
            guard let data = data, let text = String(data: data, encoding: .utf8) else {
                main { completion(nil, "页面读取失败") }
                return
            }
            main { completion(text, nil) }
        }.resume()
    }

    private static func download(_ urlString: String, completion: @escaping (String?, String?) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(nil, "下载地址无效")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(agent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                main { completion(nil, "下载失败：\(error.localizedDescription)") }
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data = data, let text = String(data: data, encoding: .utf8) else {
                main { completion(nil, "下载失败（HTTP \(code)）") }
                return
            }
            main { completion(text, nil) }
        }.resume()
    }

    private static func absolute(_ value: String?) -> String {
        guard let value = value, !value.isEmpty else { return "" }
        if value.hasPrefix("http") { return value }
        if value.hasPrefix("/") { return host + value }
        return value
    }

    private static func main(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }
}
