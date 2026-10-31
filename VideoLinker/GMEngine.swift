import Foundation
import GRDB
import WebKit

// MARK: - 油猴兼容层
//
// iOS 的 WKWebView 不能加载浏览器扩展，所以这里不做“装油猴”，
// 而是把油猴脚本运行时所依赖的那套 GM_* 接口补齐：
// 脚本存进来直接跑，写法与 Tampermonkey 一致。
//
// 已支持：GM_info、GM_addStyle、GM_log、GM_setValue/getValue/deleteValue/listValues、
//        GM_xmlhttpRequest（走原生请求，没有跨域限制）、GM_notification、GM_registerMenuCommand、
//        GM_openInTab、GM_download、unsafeWindow
// 未支持：@require / @resource 远程依赖（需要额外的抓取与执行顺序控制）

final class GMBridge {

    static let shared = GMBridge()

    private let storeKey = "userscript.values.v1"

    // MARK: 存储

    private struct ValueRow: Codable, FetchableRecord {
        var scriptID: String
        var key: String
        var value: String
    }

    private func loadAll() -> [String: [String: Any]] {
        guard let rows = AppDB.read({ db in
            try ValueRow.fetchAll(db, sql: "SELECT scriptID, key, value FROM scriptValue")
        }) else {
            return legacyLoadAll()
        }

        var map: [String: [String: Any]] = [:]
        for row in rows {
            guard let raw = Self.decodeValue(row.value) else { continue }
            map[row.scriptID, default: [:]][row.key] = raw
        }
        return map
    }

    private func saveAll(_ map: [String: [String: Any]]) {
        AppDB.write { db in
            try db.execute(sql: "DELETE FROM scriptValue")
            for (scope, values) in map {
                for (key, raw) in values {
                    guard let text = Self.encodeValue(raw) else { continue }
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO scriptValue (scriptID, key, value) VALUES (?, ?, ?)",
                        arguments: [scope, key, text]
                    )
                }
            }
        }

        if let data = try? JSONSerialization.data(withJSONObject: map) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    private func legacyLoadAll() -> [String: [String: Any]] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let object = try? JSONSerialization.jsonObject(with: data),
              let map = object as? [String: [String: Any]] else {
            return [:]
        }
        return map
    }

    /// GM_setValue 允许存字符串 / 数字 / 布尔 / 数组 / 字典，这里统一按 JSON 片段存
    static func encodeValue(_ raw: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func decodeValue(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// 某个脚本已经存下的值，注入时直接带给页面，这样 GM_getValue 可以同步返回
    func valuesJSON(for scope: String) -> String {
        valuesJSON(from: loadAll()[scope] ?? [:])
    }

    private func valuesJSON(from dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    // MARK: 消息处理

    func handle(_ body: Any, webView: WKWebView?) {
        guard let dict = body as? [String: Any],
              let id = dict["id"] as? Int,
              let action = dict["action"] as? String else { return }

        let scope = dict["scope"] as? String ?? "global"
        let payload = dict["payload"] as? [String: Any] ?? [:]

        switch action {
        case "set":
            let key = payload["key"] as? String ?? ""
            guard !key.isEmpty else { reply(id, true, NSNull(), to: webView); return }
            var all = loadAll()
            var mine = all[scope] ?? [:]
            let value = payload["value"]
            if value == nil || value is NSNull {
                mine.removeValue(forKey: key)
            } else {
                mine[key] = value
            }
            all[scope] = mine
            saveAll(all)
            reply(id, true, NSNull(), to: webView)

        case "delete":
            let key = payload["key"] as? String ?? ""
            var all = loadAll()
            var mine = all[scope] ?? [:]
            mine.removeValue(forKey: key)
            all[scope] = mine
            saveAll(all)
            reply(id, true, NSNull(), to: webView)

        case "list":
            reply(id, true, Array((loadAll()[scope] ?? [:]).keys), to: webView)

        case "fetch":
            fetch(id: id, payload: payload, webView: webView)

        default:
            reply(id, true, NSNull(), to: webView)
        }
    }

    private func fetch(id: Int, payload: [String: Any], webView: WKWebView?) {
        guard let urlString = payload["url"] as? String,
              let url = URL(string: urlString) else {
            reply(id, false, "网址无效", to: webView)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = (payload["method"] as? String) ?? "GET"

        if let headers = payload["headers"] as? [String: Any] {
            for (key, value) in headers {
                request.setValue("\(value)", forHTTPHeaderField: key)
            }
        }
        if let data = payload["data"] as? String {
            request.httpBody = data.data(using: .utf8)
        }
        if let timeout = payload["timeout"] as? Double, timeout > 0 {
            request.timeoutInterval = min(timeout / 1000.0, 120)
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                self.reply(id, false, error.localizedDescription, to: webView)
                return
            }

            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            http?.allHeaderFields.forEach { key, value in
                headers["\(key)"] = "\(value)"
            }

            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let result: [String: Any] = [
                "status": http?.statusCode ?? 0,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 0),
                "body": body,
                "headers": headers,
                "url": http?.url?.absoluteString ?? urlString
            ]
            self.reply(id, true, result, to: webView)
        }.resume()
    }

    /// 把结果送回页面：window.__vlGMResolve(id, ok, data)
    private func reply(_ id: Int, _ ok: Bool, _ data: Any, to webView: WKWebView?) {
        let json: String
        if let encoded = try? JSONSerialization.data(withJSONObject: data, options: .fragmentsAllowed),
           let text = String(data: encoded, encoding: .utf8) {
            json = text
        } else {
            json = "null"
        }

        let js = "window.__vlGMResolve && window.__vlGMResolve(\(id), \(ok ? "true" : "false"), \(json));"
        DispatchQueue.main.async {
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

// MARK: - 页面侧的 GM 垫片

enum GMShim {
    /// 在每个页面开头注入一次，向脚本暴露 GM_* 这一套接口
    static let source = #"""
    (function () {
      if (window.__vlGMFactory) { return; }

      var seq = 0;
      var pending = {};

      function post(action, scope, payload) {
        return new Promise(function (resolve, reject) {
          var id = ++seq;
          pending[id] = { resolve: resolve, reject: reject };
          try {
            window.webkit.messageHandlers.vlGM.postMessage({
              id: id,
              action: action,
              scope: scope,
              payload: payload || {}
            });
          } catch (e) {
            delete pending[id];
            reject(e);
          }
        });
      }

      window.__vlGMResolve = function (id, ok, data) {
        var p = pending[id];
        if (!p) { return; }
        delete pending[id];
        if (ok) { p.resolve(data); }
        else { p.reject(new Error(String(data || 'GM 调用失败'))); }
      };

      function toast(text) {
        try {
          var box = document.createElement('div');
          box.textContent = text;
          box.style.cssText = 'position:fixed;left:50%;bottom:64px;transform:translateX(-50%);'
            + 'background:rgba(22,22,26,.94);color:#fff;font-size:13px;line-height:1.5;'
            + 'padding:10px 16px;border-radius:12px;z-index:2147483647;max-width:78vw;'
            + 'box-shadow:0 6px 24px rgba(0,0,0,.35);font-family:-apple-system,sans-serif';
          (document.body || document.documentElement).appendChild(box);
          setTimeout(function () { box.remove(); }, 2600);
        } catch (e) {}
      }

      window.__vlGMFactory = function (scope, initialValues) {
        var values = initialValues || {};
        var menus = [];

        return {
          GM_info: {
            scriptHandler: 'VideoLinker',
            version: '1.4',
            script: { name: scope, version: '1.0' },
            sandboxMode: 'JavaScript'
          },
          unsafeWindow: window,

          GM_addStyle: function (css) {
            var el = document.createElement('style');
            el.textContent = css;
            (document.head || document.documentElement).appendChild(el);
            return el;
          },

          GM_log: function () {
            try {
              var args = [].slice.call(arguments);
              console.log.apply(console, ['[' + scope + ']'].concat(args));
            } catch (e) {}
          },

          GM_setValue: function (key, value) {
            values[key] = value;
            post('set', scope, { key: key, value: value });
          },

          GM_getValue: function (key, fallback) {
            return Object.prototype.hasOwnProperty.call(values, key) ? values[key] : fallback;
          },

          GM_deleteValue: function (key) {
            delete values[key];
            post('delete', scope, { key: key });
          },

          GM_listValues: function () {
            return Object.keys(values);
          },

          GM_xmlhttpRequest: function (opt) {
            opt = opt || {};
            post('fetch', scope, {
              method: opt.method || 'GET',
              url: opt.url,
              headers: opt.headers || {},
              data: opt.data || null,
              timeout: opt.timeout || 30000
            }).then(function (r) {
              if (!opt.onload) { return; }
              opt.onload({
                status: r.status,
                statusText: r.statusText,
                readyState: 4,
                responseText: r.body,
                response: r.body,
                responseHeaders: r.headers,
                finalUrl: r.url
              });
            }, function (e) {
              if (opt.onerror) { opt.onerror({ error: e.message }); }
            });
            return { abort: function () {} };
          },

          GM_notification: function (detail) {
            var text = typeof detail === 'string'
              ? detail
              : (detail && (detail.text || detail.title)) || '';
            if (text) { toast(text); }
          },

          GM_registerMenuCommand: function (name, fn) {
            menus.push({ name: name, run: fn });
            return menus.length;
          },

          GM_unregisterMenuCommand: function () {},

          GM_openInTab: function (url) {
            try { window.location.href = url; } catch (e) {}
          },

          GM_getResourceText: function () { return ''; },

          GM_download: function (opt) {
            var url = typeof opt === 'string' ? opt : (opt && opt.url);
            try { if (url) { window.location.href = url; } } catch (e) {}
          }
        };
      };
    })();
    """#
}
