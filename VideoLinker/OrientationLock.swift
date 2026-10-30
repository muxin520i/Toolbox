import UIKit

/// 控制整个 App 允许的屏幕方向。
/// 平时锁竖屏，播放页进入全屏时锁横屏，退出时恢复。
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}

enum OrientationLock {
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
