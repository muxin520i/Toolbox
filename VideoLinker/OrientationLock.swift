import UIKit

/// 控制整个 App 允许的屏幕方向。
/// 平时锁竖屏，播放页进入全屏时锁横屏，退出时恢复。
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    /// 后台巡检必须在启动完成前注册，晚于启动会直接崩
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
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
