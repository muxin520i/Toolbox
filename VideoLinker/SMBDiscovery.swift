import Foundation

/// 扫局域网里的 SMB 服务（Bonjour `_smb._tcp`）。
/// 只负责把设备名字和主机地址报出来，账号密码仍然走手动填写的添加流程。
final class SMBDiscovery: NSObject, ObservableObject {
    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
        let host: String
        let port: Int
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var scanning = false
    @Published private(set) var hint = ""

    private var browser: NetServiceBrowser?
    private var resolving: [NetService] = []
    private var finishWork: DispatchWorkItem?

    func start() {
        guard !scanning else { return }
        devices.removeAll()
        hint = ""
        scanning = true

        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: "_smb._tcp.", inDomain: "local.")
        self.browser = browser

        // 有些网络里 mDNS 迟迟不回，6 秒就收工，别让用户干等
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    func stop() {
        finishWork?.cancel()
        finishWork = nil
        browser?.stop()
        browser = nil
        resolving.forEach { $0.stop() }
        resolving.removeAll()
        scanning = false
    }

    private func finish() {
        finishWork?.cancel()
        finishWork = nil
        browser?.stop()
        browser = nil
        scanning = false
        if devices.isEmpty, hint.isEmpty {
            hint = "没扫到设备。确认手机和 NAS 在同一个 Wi-Fi，NAS 上开了 SMB 共享。"
        }
    }

    /// `NAS.local.` 末尾的点去掉，SMB 库认不带点的主机名
    private static func clean(_ host: String?) -> String {
        guard var host = host, !host.isEmpty else { return "" }
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// mDNS 名字有时解析不了，退回 IPv4 地址
    private static func ipv4(of service: NetService) -> String? {
        guard let addresses = service.addresses else { return nil }
        for data in addresses {
            guard data.count >= MemoryLayout<sockaddr_in>.size else { continue }
            let family = data.withUnsafeBytes { $0.load(as: sa_family_t.self) }
            guard family == sa_family_t(AF_INET) else { continue }

            var addr = sockaddr_in()
            let count = min(data.count, MemoryLayout<sockaddr_in>.size)
            withUnsafeMutableBytes(of: &addr) { buffer in
                guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
                data.copyBytes(to: base, count: count)
            }
            guard addr.sin_family == sa_family_t(AF_INET) else { continue }

            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sin = addr.sin_addr
            if inet_ntop(AF_INET, &sin, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                return String(cString: buffer)
            }
        }
        return nil
    }
}

extension SMBDiscovery: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool) {
        service.delegate = self
        service.resolve(withTimeout: 5)
        resolving.append(service)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didRemove service: NetService,
                           moreComing: Bool) {
        let name = service.name
        let host = Self.clean(service.hostName)
        devices.removeAll { $0.name == name && (host.isEmpty || $0.host == host) }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didNotSearch errorDict: [String: NSNumber]) {
        hint = "搜索失败，可以直接手动填主机地址"
        scanning = false
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        scanning = false
    }
}

extension SMBDiscovery: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        resolving.removeAll { $0 === sender }

        let host = Self.clean(sender.hostName)
        let address = host.isEmpty ? (Self.ipv4(of: sender) ?? "") : host
        guard !address.isEmpty else { return }

        let device = Device(id: "\(address)|\(sender.name)",
                            name: sender.name,
                            host: address,
                            port: max(sender.port, 445))

        if !devices.contains(where: { $0.id == device.id }) {
            devices.append(device)
            devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 === sender }
    }
}
