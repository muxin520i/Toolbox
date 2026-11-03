import SwiftUI
import UIKit

// MARK: - 通知

extension Notification.Name {
    /// 自定义底部导航切换，object 为 RootView.Tab.rawValue
    static let appTabDidSelect = Notification.Name("video.appTabDidSelect")
}

// MARK: - 外部唤起（URL Scheme / 快捷指令）

final class Router: ObservableObject {
    static let shared = Router()

    @Published var pending: PlayRequest?

    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "videolinker" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        if let raw = items?.first(where: { $0.name == "url" })?.value {
            handleString(raw)
        }
    }

    func handleString(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return }
        if !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        guard let u = URL(string: s), let host = u.host, host.contains(".") else { return }
        pending = PlayRequest(url: u)
    }
}

// MARK: - 根视图

struct RootView: View {
    enum Tab: Int, CaseIterable {
        case play, lists, checkin, sniffer, settings
    }

    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.theme) private var themeRaw = AppTheme.system.rawValue
    /// 上次处理过的剪贴板版本号，避免同一条链接反复弹提示
    @AppStorage("share.clipboardChangeCount") private var handledClipboardCount = -1
    @AppStorage(SettingsKey.motion) private var motion = true

    @State private var tab: Tab = .play
    /// 剪贴板里有链接，顶部提示条是否显示
    @State private var clipboardHasLink = false

    private var appTheme: AppTheme {
        AppTheme(rawValue: themeRaw) ?? .system
    }

    private var resolvedScheme: ColorScheme {
        appTheme.colorScheme ?? systemScheme
    }

    private var theme: Theme {
        Theme(resolvedScheme)
    }

    var body: some View {
        TabView(selection: $tab) {
            ContentView()
                .tabItem {
                    Label("播放", systemImage: "play.circle.fill")
                }
                .tag(Tab.play)

            PlaylistListView()
                .tabItem {
                    Label("列表", systemImage: "list.bullet.rectangle.portrait.fill")
                }
                .tag(Tab.lists)

            WBHubView()
                .tabItem {
                    Label("签到", systemImage: "checkmark.seal.fill")
                }
                .tag(Tab.checkin)

            SnifferView()
                .tabItem {
                    Label("嗅探", systemImage: "safari.fill")
                }
                .tag(Tab.sniffer)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
                .tag(Tab.settings)
        }
        .tint(theme.accent)
        .environment(\.theme, theme)
        // 设置里关掉「界面动效」后，整个 App 的隐式动画直接不跑
        .transaction { transaction in
            if !motion {
                transaction.disablesAnimations = true
            }
        }
        .preferredColorScheme(appTheme.colorScheme)
        .onAppear { Self.configureTabBar(theme: theme) }
        .onChange(of: themeRaw) { _ in
            Self.configureTabBar(theme: theme)
        }
        .task {
            // 先刷新接口配置，再自动补签，保证这次用的就是最新路径
            await WBRemoteConfig.shared.refreshIfNeeded()
            await WBCheckinStore.shared.autoCheckinIfNeeded()
        }
        .onChange(of: tab) { value in
            NotificationCenter.default.post(name: .appTabDidSelect, object: value.rawValue)
        }
        .onOpenURL { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let action = items?.first(where: { $0.name == "action" })?.value

            // 分享扩展点「下载」：直接进下载队列，切到列表页能看见进度
            if action == "download",
               let raw = items?.first(where: { $0.name == "url" })?.value {
                _ = DownloadManager.shared.start(from: raw)
                tab = .lists
                return
            }

            Router.shared.handle(url)
            tab = .play
        }
        .onAppear { checkClipboardForLink() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { checkClipboardForLink() }
        }
        .overlay(alignment: .bottom) {
            if clipboardHasLink {
                clipboardBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 76)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - 分享扩展拿到的链接

    /// 分享扩展没法直接拉起 App（iOS 18 起系统彻底封了），
    /// 它能做的就是把链接放进剪贴板；这里回到前台时探一下剪贴板，
    /// 有链接就弹一条提示，点一下就能播，不用用户自己去粘贴框里粘。
    /// 用 hasURLs 判断不会触发系统的「允许粘贴」弹窗，只有真的点「播放」才读内容。
    private func checkClipboardForLink() {
        let board = UIPasteboard.general
        let hasLink = board.hasURLs && board.changeCount != handledClipboardCount
        guard hasLink != clipboardHasLink else { return }
        withAnimation(.easeOut(duration: 0.18)) { clipboardHasLink = hasLink }
    }

    private var clipboardBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 15))
                .foregroundStyle(theme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("剪贴板里有一条链接")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text("分享过来的话，点「播放」接着看")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer(minLength: 2)

            Button {
                useClipboardLink(download: false)
            } label: {
                Text("播放")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                useClipboardLink(download: true)
            } label: {
                Text("下载")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(theme.field, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                handledClipboardCount = UIPasteboard.general.changeCount
                withAnimation(.easeOut(duration: 0.16)) { clipboardHasLink = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(0.2), radius: 14, y: 5)
    }

    private func useClipboardLink(download: Bool) {
        let board = UIPasteboard.general
        var raw = board.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 有些 App 只写 URL 表示，不写纯文本
        if raw.isEmpty, let url = board.url { raw = url.absoluteString }
        handledClipboardCount = board.changeCount
        withAnimation(.easeOut(duration: 0.16)) { clipboardHasLink = false }
        guard let link = Self.firstLink(in: raw) else { return }
        if download {
            _ = DownloadManager.shared.start(from: link)
            tab = .lists
        } else {
            tab = .play
            Router.shared.handleString(link)
        }
    }

    private static func firstLink(in text: String) -> String? {
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return text
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.firstMatch(in: text, options: [], range: range)?.url?.absoluteString
    }

    private static func configureTabBar(theme: Theme) {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(theme.navBg)
        appearance.shadowColor = theme.isDark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.06)

        let item = UITabBarItemAppearance()
        item.normal.iconColor = UIColor(theme.textTertiary)
        item.normal.titleTextAttributes = [.foregroundColor: UIColor(theme.textTertiary)]
        item.selected.iconColor = UIColor(theme.accent)
        item.selected.titleTextAttributes = [.foregroundColor: UIColor(theme.accent)]

        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}

struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView()
    }
}
