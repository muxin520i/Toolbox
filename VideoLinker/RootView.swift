import SwiftUI
import UIKit

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
    enum Tab: Int {
        case play, lists, checkin, sniffer, settings
    }

    @Environment(\.colorScheme) private var systemScheme
    @AppStorage(SettingsKey.theme) private var themeRaw = AppTheme.system.rawValue

    @State private var tab: Tab = .play

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

            WBCheckinView()
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
        .preferredColorScheme(appTheme.colorScheme)
        .onAppear { Self.configureTabBar(theme: theme) }
        .task {
            // 每天首次打开 App 就补签，不用先点进签到页
            await WBCheckinStore.shared.autoCheckinIfNeeded()
        }
        .onChange(of: themeRaw) { _ in
            Self.configureTabBar(theme: theme)
        }
        .onOpenURL { url in
            Router.shared.handle(url)
            tab = .play
        }
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
