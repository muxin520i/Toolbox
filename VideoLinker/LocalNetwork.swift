import Foundation
import Network

// MARK: - 本地网络授权
//
// iOS 14 起，App 想和同一 Wi-Fi 下的其他设备通信，需要用户授权「本地网络」。
// 坑在于：**系统只在特定动作时才弹窗** —— Bonjour 浏览 / 广播、组播广播，
// 或者主动连接一个局域网地址。只开一个 TCP 监听端口是**不会**弹的。
//
// 所以之前的表现就是：服务起得来，地址也显示，但电脑连不上；
// 系统设置里也没有「本地网络」这个开关 —— 因为从来没请求过，权限一直是「未决」。
//
// 这里用一次 Bonjour 浏览来触发弹窗，并判断当前状态。

enum LocalNetworkPermission {

    /// 必须和 Info.plist 里的 NSBonjourServices 一致，
    /// 否则系统会直接拒绝这次浏览
    static let serviceType = "_videolinker._tcp"

    enum Status: Equatable {
        case unknown    // 还没测过
        case checking   // 正在等用户点弹窗
        case granted
        case denied
        case timeout    // 没有回应，多半也是被拦了

        var text: String {
            switch self {
            case .unknown: return "还没检测"
            case .checking: return "等待授权"
            case .granted: return "已允许"
            case .denied: return "被拒绝"
            case .timeout: return "没有响应"
            }
        }

        var isOK: Bool { self == .granted }
    }

    /// 只让第一次的结果生效（浏览器的回调可能来好几次）
    private final class Flag {
        private let lock = NSLock()
        private var taken = false

        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }

    /// 触发一次 Bonjour 浏览。
    /// 第一次调用会弹系统弹窗；已经授权 / 拒绝过的不会再弹，直接返回结果。
    static func probe(timeout: TimeInterval = 20, completion: @escaping (Status) -> Void) {
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)
        let flag = Flag()

        let finish: (Status) -> Void = { status in
            guard flag.take() else { return }
            // 断开 回调 → finish → browser 的循环引用
            browser.stateUpdateHandler = nil
            browser.cancel()
            DispatchQueue.main.async { completion(status) }
        }

        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(.granted)
            case .failed(let error):
                finish(LocalNetworkPermission.isPolicyDenied(error) ? .denied : .timeout)
            case .waiting(let error):
                // 权限被拒时通常停在 waiting，不会走到 failed
                if LocalNetworkPermission.isPolicyDenied(error) { finish(.denied) }
            default:
                break
            }
        }

        browser.start(queue: DispatchQueue(label: "com.example.VideoLinker.localnetwork", qos: .userInitiated))

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            finish(.timeout)
        }
    }

    /// -65555 = kDNSServiceErr_PolicyDenied，权限被用户拒绝时系统给的就是这个
    static func isPolicyDenied(_ error: Error) -> Bool {
        guard let nwError = error as? NWError else { return false }
        switch nwError {
        case .dns(let code) where code == -65555:
            return true
        case .posix(let code) where code == .EPERM || code == .EACCES:
            return true
        default:
            return false
        }
    }
}
