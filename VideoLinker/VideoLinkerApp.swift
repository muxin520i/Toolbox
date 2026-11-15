import SwiftUI

@main
struct VideoLinkerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // 必须赶在任何 WKWebView 建立之前把网站数据换好。
        // 这一步只是目录改名，很快；放晚了 WebKit 已经抓着自己的库，会打架。
        TransferStore.applyPendingWebDataIfNeeded()

        // 后台下载会话必须在启动阶段就建好，否则 App 被唤醒来收后台事件时找不到代理
        _ = DownloadManager.shared

        // 数据库首次打开要建表、跑迁移、搬旧数据，别让它卡在第一屏或第一次点菜单上
        DispatchQueue.global(qos: .userInitiated).async {
            _ = AppDB.queue
        }
    }

    var body: some Scene {
        WindowGroup {
            PrivacyGate {
                RootView()
            }
        }
    }
}
