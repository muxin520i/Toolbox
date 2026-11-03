import SwiftUI
import Foundation
import UIKit

// MARK: - 网络诊断
//
// 卡顿、403、连不上时，先分清是网的问题还是源的问题：
// 这里只做本机能看到的部分——接口、地址、DNS 解析、到常用站点的延迟抖动、
// 以及一段真实下载的速度。不做端口扫描，也不上传任何信息。

final class NetworkDiagnostics: ObservableObject {

    struct Metric: Identifiable {
        let id = UUID()
        let name: String
        let value: String
        var detail: String = ""
    }

    @Published private(set) var metrics: [Metric] = []
    @Published private(set) var running = false
    @Published private(set) var finished = false
    @Published private(set) var status = ""

    func run() {
        guard !running else { return }
        running = true
        finished = false
        metrics = []

        Task {
            let info = Self.interfaceInfo()
            await self.update {
                self.metrics = [
                    .init(name: "网络类型", value: info.type),
                    .init(name: "本机地址", value: info.ip, detail: info.name)
                ]
            }

            await self.setStatus("解析域名…")
            let dns = await Self.measureDNS(host: "www.baidu.com")
            await self.update {
                if let dns {
                    self.metrics.append(.init(name: "DNS 解析", value: String(format: "%.0f ms", dns)))
                } else {
                    self.metrics.append(.init(name: "DNS 解析", value: "失败", detail: "域名解析不了，先检查网络"))
                }
            }

            await self.setStatus("测试延迟…")
            let latency = await Self.measureLatency(count: 5)
            await self.update {
                if let latency {
                    self.metrics.append(.init(
                        name: "延迟",
                        value: String(format: "%.0f ms", latency.average),
                        detail: String(format: "最快 %.0f / 最慢 %.0f / 抖动 %.0f ms",
                                       latency.min, latency.max, latency.jitter)
                    ))
                } else {
                    self.metrics.append(.init(name: "延迟", value: "失败", detail: "连不上测试地址"))
                }
            }

            await self.setStatus("测试下载速度…")
            let speed = await Self.measureSpeed()
            await self.update {
                if let speed {
                    self.metrics.append(.init(name: "下载速度", value: String(format: "%.1f Mbps", speed),
                                              detail: String(format: "约 %.1f MB/s，按 6 MB 样本估算", speed / 8)))
                } else {
                    self.metrics.append(.init(name: "下载速度", value: "失败", detail: "测速地址没响应，可能被网络限制"))
                }
                self.running = false
                self.finished = true
                self.status = ""
            }
        }
    }

    var summary: String {
        var lines = ["网络诊断"]
        for metric in metrics {
            var line = "\(metric.name)：\(metric.value)"
            if !metric.detail.isEmpty { line += "（\(metric.detail)）" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func update(_ block: @escaping () -> Void) async {
        await MainActor.run { block() }
    }

    private func setStatus(_ text: String) async {
        await MainActor.run { self.status = text }
    }

    // MARK: 接口与地址

    private static func interfaceInfo() -> (type: String, ip: String, name: String) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            return ("未知", "—", "")
        }
        defer { freeifaddrs(head) }

        var found: [String: String] = [:]
        var pointer = first
        while true {
            let flags = Int32(pointer.pointee.ifa_flags)
            if let addr = pointer.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) != 0,
               (flags & IFF_LOOPBACK) == 0 {

                let name = String(cString: pointer.pointee.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                               &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    found[name] = String(cString: host)
                }
            }

            guard let next = pointer.pointee.ifa_next else { break }
            pointer = next
        }

        let order = ["en0", "pdp_ip0", "en1", "utun0"]
        for name in order {
            guard let ip = found[name] else { continue }
            return (typeName(for: name), ip, name)
        }
        if let pair = found.first {
            return (typeName(for: pair.key), pair.value, pair.key)
        }
        return ("未连接", "—", "")
    }

    private static func typeName(for interface: String) -> String {
        if interface.hasPrefix("en") { return "Wi-Fi / 有线" }
        if interface.hasPrefix("pdp_ip") { return "蜂窝移动网络" }
        if interface.hasPrefix("utun") || interface.hasPrefix("ipsec") { return "VPN" }
        return interface
    }

    // MARK: DNS

    private static func measureDNS(host: String) async -> Double? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo(
                    ai_flags: 0,
                    ai_family: AF_UNSPEC,
                    ai_socktype: SOCK_STREAM,
                    ai_protocol: 0,
                    ai_addrlen: 0,
                    ai_canonname: nil,
                    ai_addr: nil,
                    ai_next: nil
                )
                var result: UnsafeMutablePointer<addrinfo>?
                let start = Date()
                let code = getaddrinfo(host, "443", &hints, &result)
                let elapsed = Date().timeIntervalSince(start) * 1000
                if let result { freeaddrinfo(result) }
                continuation.resume(returning: code == 0 ? elapsed : nil)
            }
        }
    }

    // MARK: 延迟

    private static func measureLatency(count: Int) async -> (average: Double, min: Double, max: Double, jitter: Double)? {
        guard let url = URL(string: "https://www.baidu.com") else { return nil }
        var samples: [Double] = []

        for _ in 0..<count {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 6
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Toolbox/1.0", forHTTPHeaderField: "User-Agent")

            let start = Date()
            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode < 500 {
                    samples.append(Date().timeIntervalSince(start) * 1000)
                }
            } catch {
                // 单次失败就跳过
            }
            session.invalidateAndCancel()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        guard samples.count >= 2 else {
            return samples.first.map { ($0, $0, $0, 0) }
        }

        let average = samples.reduce(0, +) / Double(samples.count)
        var jitterTotal: Double = 0
        for index in 1..<samples.count {
            jitterTotal += abs(samples[index] - samples[index - 1])
        }
        let jitter = jitterTotal / Double(samples.count - 1)
        return (average, samples.min() ?? average, samples.max() ?? average, jitter)
    }

    // MARK: 下载速度

    private static func measureSpeed() async -> Double? {
        let candidates = [
            "https://dldir1.qq.com/qqfile/qq/PCQQ9.7.17/QQ9.7.17.29225.exe",
            "https://speed.cloudflare.com/__down?bytes=10000000"
        ]

        for text in candidates {
            guard let url = URL(string: text) else { continue }
            let probe = SpeedProbe()
            if let speed = await probe.measure(url: url) {
                return speed
            }
        }
        return nil
    }

    /// 只收前 6 MB，收到或超时立刻断开，不把整个安装包下完
    private final class SpeedProbe: NSObject, URLSessionDataDelegate {
        private var continuation: CheckedContinuation<Double?, Never>?
        private var session: URLSession?
        private var bytes = 0
        private var start = Date()
        private var done = false
        private let limit = 6 * 1024 * 1024
        private let deadline: TimeInterval = 7

        func measure(url: URL) async -> Double? {
            await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
                self.continuation = continuation
                self.bytes = 0
                self.start = Date()
                self.done = false

                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = deadline
                config.timeoutIntervalForResource = deadline + 2
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session

                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("Toolbox/1.0", forHTTPHeaderField: "User-Agent")
                session.dataTask(with: request).resume()
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !done else { return }
            bytes += data.count
            if bytes >= limit || Date().timeIntervalSince(start) >= deadline {
                finish()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            finish()
        }

        private func finish() {
            guard !done else { return }
            done = true

            let elapsed = max(0.4, Date().timeIntervalSince(start))
            let mbps = Double(bytes) * 8 / elapsed / 1_000_000
            let result: Double? = bytes > 400_000 ? mbps : nil

            session?.invalidateAndCancel()
            session = nil
            continuation?.resume(returning: result)
            continuation = nil
        }
    }
}

// MARK: - 界面

struct NetworkDiagnosticsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model = NetworkDiagnostics()
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header

                    if !model.metrics.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(model.metrics.enumerated()), id: \.element.id) { index, metric in
                                row(metric)
                                if index != model.metrics.count - 1 {
                                    Divider().overlay(theme.cardStroke)
                                }
                            }
                        }
                        .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(theme.cardStroke, lineWidth: 1)
                        )
                    }

                    if model.finished {
                        Button {
                            UIPasteboard.general.string = model.summary
                            copied = true
                            Haptics.success()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                        } label: {
                            Label(copied ? "已复制" : "复制诊断结果", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.text)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    Text("延迟测的是到百度的往返时间，速度是真实下载 6 MB 的平均值。结果受当前网络和时段影响，多测两次更准。")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
            .background(theme.bg.ignoresSafeArea())
            .navigationTitle("网络诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                if !model.running && model.metrics.isEmpty {
                    model.run()
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            if model.running {
                ProgressView()
                    .tint(theme.accent)
                Text(model.status.isEmpty ? "正在诊断…" : model.status)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
            } else {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(theme.accent)
                Text(model.finished ? "诊断完成" : "点下面开始")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text)
            }

            Button {
                model.run()
            } label: {
                Text(model.running ? "诊断中…" : "重新诊断")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(theme.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .opacity(model.running ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .disabled(model.running)
        }
        .padding(.vertical, 10)
    }

    private func row(_ metric: NetworkDiagnostics.Metric) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(metric.name)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(metric.value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.text)
                if !metric.detail.isEmpty {
                    Text(metric.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
