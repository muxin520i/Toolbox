import UIKit

/// 控制整个 App 允许的屏幕方向。
/// 平时锁竖屏，播放页进入全屏时锁横屏，退出时恢复。
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    /// 后台巡检必须在启动完成前注册，晚于启动会直接崩
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CrashLog.install()
        PatrolStore.registerBackgroundTask()
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }

    /// 系统唤醒来处理后台下载事件：把 completion 交给下载器，等它把回调跑完再调用
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.shared.handleBackgroundEvents(completionHandler)
    }
}

/// 记下最近一次崩溃/异常，供「换机备份」页显示。
/// 崩溃发生在用户手机上，拿不到 Xcode 日志，只能自己留一份。
enum CrashLog {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("last-crash.log")
    }

    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            let text = """
            \(Date())
            异常：\(exception.name.rawValue)
            原因：\(exception.reason ?? "无")
            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            writeCrashLog(text)
        }

        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { code in
                let text = """
                \(Date())
                信号：\(code)
                \(Thread.callStackSymbols.joined(separator: "\n"))
                """
                writeCrashLog(text)
                // 写完恢复系统默认处理，保持真实的崩溃行为
                signal(code, SIG_DFL)
                raise(code)
            }
        }
    }

    static var last: String? {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty
        else { return nil }
        return text
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: stageURL)
    }

    private static var stageURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("last-stage.log")
    }

    /// 打一个阶段标记。崩溃日志可能是空的，阶段标记能说明崩在哪一步。
    static func mark(_ stage: String) {
        // 长期使用会累积，超过 32 KB 就重开一份
        if let attrs = try? FileManager.default.attributesOfItem(atPath: stageURL.path),
           let size = attrs[.size] as? NSNumber,
           size.intValue > 32 * 1024 {
            try? FileManager.default.removeItem(at: stageURL)
        }

        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(stage)\n"
        if let handle = try? FileHandle(forWritingTo: stageURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: stageURL, atomically: true, encoding: .utf8)
        }
    }

    static var lastStage: String? {
        guard let data = try? Data(contentsOf: stageURL),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let lines = text.split(separator: "\n").filter { !$0.isEmpty }
        return lines.suffix(3).joined(separator: "\n")
    }

    static var hasRecord: Bool {
        last != nil || lastStage != nil
    }

    static var report: String {
        var parts: [String] = []
        if let stage = lastStage {
            parts.append("【最后动作】\n" + stage)
        }
        if let crash = last {
            parts.append("【崩溃内容】\n" + crash)
        }
        return parts.isEmpty ? "没有记录" : parts.joined(separator: "\n\n")
    }
}

/// 信号处理器里只能调全局函数，不能碰类型元数据
private func writeCrashLog(_ text: String) {
    let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let url = base.appendingPathComponent("last-crash.log")
    guard let data = String(text.prefix(12000)).data(using: .utf8) else { return }
    try? data.write(to: url, options: .atomic)
}

enum OrientationLock {
    /// 当前界面方向对应的遮罩，用来「锁在当前方向」。
    static var current: UIInterfaceOrientationMask {
        guard let scene = activeScene() else { return .portrait }
        switch scene.interfaceOrientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .portrait
        }
    }

    /// 请求界面转向指定方向。
    /// iOS 16 起用 `requestGeometryUpdate` 这个公开接口，不需要私有 API。
    static func apply(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.orientationLock = mask

        DispatchQueue.main.async {
            guard let scene = activeScene() else { return }

            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()

            let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
            scene.requestGeometryUpdate(preferences) { _ in
                // 请求被系统拒绝时不做处理，画面保持当前方向，功能不受影响
            }
        }
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    }
}
