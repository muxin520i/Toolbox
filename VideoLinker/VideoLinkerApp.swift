import SwiftUI

@main
struct VideoLinkerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // 数据库首次打开要建表、跑迁移、搬旧数据，别让它卡在第一屏或第一次点菜单上
        DispatchQueue.global(qos: .userInitiated).async {
            _ = AppDB.queue
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
