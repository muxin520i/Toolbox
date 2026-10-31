import SwiftUI

@main
struct VideoLinkerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // 后台下载会话必须在启动阶段就建好，否则 App 被唤醒来收后台事件时找不到代理
        _ = DownloadManager.shared

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
