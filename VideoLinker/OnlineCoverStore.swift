import Foundation
import SwiftUI
import UIKit

/// 在线视频的封面：抓网页里的 og:image / twitter:image，落盘缓存。
/// 视频直链（mp4 / m3u8）没有网页可抓，直接放弃，界面上回落到序号
final class OnlineCoverStore {
    static let shared = OnlineCoverStore()

    private let dir: URL
    private var memory: [String: UIImage] = [:]
    private var failed: Set<String> = []
    private var running: Set<String> = []
    private let lock = NSLock()

    /// 同时最多抓几张，别把网速和内存吃满
    private let maxConcurrent = 3

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("VideoCovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: 查询

    func cached(for pageURL: String) -> UIImage? {
        lock.lock()
        if let image = memory[pageURL] {
            lock.unlock()
            return image
        }
        lock.unlock()

        let file = dir.appendingPathComponent(Self.key(pageURL) + ".jpg")
        guard let data = try? Data(contentsOf: file), let image = UIImage(data: data) else { return nil }

        lock.lock()
        memory[pageURL] = image
        lock.unlock()
        return image
    }

    /// 异步取封面；拿不到就回调 nil（同一地址只试一次）
    func request(_ pageURL: String, completion: @escaping (UIImage?) -> Void) {
        if let image = cached(for: pageURL) {
            completion(image)
            return
        }

        lock.lock()
        if failed.contains(pageURL) {
            lock.unlock()
            completion(nil)
            return
        }
        if running.contains(pageURL) || running.count >= maxConcurrent {
            lock.unlock()
            completion(nil)
            return
        }
        running.insert(pageURL)
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let image = self.fetch(pageURL)

            if let image = image, let data = image.jpegData(compressionQuality: 0.8) {
                try? data.write(to: self.dir.appendingPathComponent(Self.key(pageURL) + ".jpg"))
            }

            self.lock.lock()
            self.running.remove(pageURL)
            if let image = image {
                self.memory[pageURL] = image
            } else {
                self.failed.insert(pageURL)
            }
            self.lock.unlock()

            DispatchQueue.main.async { completion(image) }
        }
    }

    // MARK: 抓取

    private func fetch(_ pageURL: String) -> UIImage? {
        guard let page = URL(string: pageURL),
              let scheme = page.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }

        // 直链视频没有 HTML 可解析
        let ext = page.pathExtension.lowercased()
        let videoExt: Set<String> = [
            "mp4", "m4v", "mov", "m3u8", "ts", "m2ts", "flv", "mkv", "webm",
            "avi", "wmv", "mp3", "m4a", "aac"
        ]
        if videoExt.contains(ext) { return nil }

        guard let html = Self.loadHTML(page) else { return nil }
        guard let imageURL = Self.ogImageURL(in: html, base: page) else { return nil }
        var imageRequest = URLRequest(url: imageURL, timeoutInterval: 10)
        HTTPHeaderStore.apply(to: &imageRequest, url: imageURL)
        guard let data = Self.loadData(imageRequest) else { return nil }
        return UIImage(data: data)
    }

    private static func loadHTML(_ url: URL) -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        HTTPHeaderStore.apply(to: &request, url: url)

        guard let data = loadData(request) else { return nil }
        let slice = data.prefix(600_000)
        return String(data: slice, encoding: .utf8) ?? String(decoding: slice, as: UTF8.self)
    }

    private static func loadData(_ request: URLRequest) -> Data? {
        final class Box: @unchecked Sendable {
            var data: Data?
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, _, _ in
            box.data = data
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 12)
        return box.data
    }

    /// 按优先级找 og:image / twitter:image，属性顺序两种都认
    private static func ogImageURL(in html: String, base: URL) -> URL? {
        let patterns = [
            "<meta[^>]+property=[\"']og:image[\"'][^>]*content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]*property=[\"']og:image[\"']",
            "<meta[^>]+name=[\"']twitter:image[\"'][^>]*content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]*name=[\"']twitter:image[\"']"
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: html) else { continue }

            var value = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            value = value
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&#x2F;", with: "/")
            if value.isEmpty { continue }
            if value.hasPrefix("//") { value = "https:" + value }

            if let url = URL(string: value, relativeTo: base)?.absoluteURL {
                return url
            }
        }
        return nil
    }

    /// 稳定的短文件名，重启后还能命中同一张图
    private static func key(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

/// 列表里在线条目的封面；没抓到就显示传入的占位文字（一般是序号）
struct OnlineCover: View {
    let url: String
    var placeholder: String = ""
    var width: CGFloat = 56
    var height: CGFloat = 34
    var corner: CGFloat = 6

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.gray.opacity(0.16))

            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Text(placeholder)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: url) {
            if let cached = OnlineCoverStore.shared.cached(for: url) {
                image = cached
                return
            }
            let loaded = await withCheckedContinuation { continuation in
                OnlineCoverStore.shared.request(url) { result in
                    continuation.resume(returning: result)
                }
            }
            image = loaded
        }
    }
}
