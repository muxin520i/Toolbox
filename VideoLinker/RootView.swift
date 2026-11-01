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
        case play, lists, checkin, points, travel, sniffer, settings

        var title: String {
            switch self {
            case .play: return "播放"
            case .lists: return "列表"
            case .checkin: return "签到"
            case .points: return "积分"
            case .travel: return "旅行"
            case .sniffer: return "嗅探"
            case .settings: return "设置"
            }
        }

        var icon: String {
            switch self {
            case .play: return "play.circle.fill"
            case .lists: return "list.bullet.rectangle.portrait.fill"
            case .checkin: return "checkmark.seal.fill"
            case .points: return "creditcard.fill"
            case .travel: return "pawprint.fill"
            case .sniffer: return "safari.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    @Environment(\.colorScheme) private var systemScheme
    @AppStorage(SettingsKey.theme) private var themeRaw = AppTheme.system.rawValue

    @State private var tab: Tab = .play
    /// 首次进入才创建页面，之后常驻，切 tab 不丢播放器和网页状态
    @State private var loaded: Set<Tab> = [.play]

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
        ZStack {
            theme.bg.ignoresSafeArea()

            ZStack {
                page(.play) { ContentView() }
                page(.lists) { PlaylistListView() }
                page(.checkin) { WBCheckinView(active: tab == .checkin) }
                page(.points) { WBPointsView(active: tab == .points) }
                page(.travel) { NavigationStack { WBTravelView(active: tab == .travel) } }
                page(.sniffer) { SnifferView() }
                page(.settings) { SettingsView() }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                tabBar
            }
        }
        .environment(\.theme, theme)
        .preferredColorScheme(appTheme.colorScheme)
        .task {
            // 每天首次打开 App 就补签，不用先点进签到页
            await WBCheckinStore.shared.autoCheckinIfNeeded()
        }
        .onChange(of: tab) { value in
            _ = loaded.insert(value)
        }
        .onOpenURL { url in
            Router.shared.handle(url)
            switchTo(.play)
        }
    }

    // MARK: 页面容器

    private func page<Content: View>(_ item: Tab, @ViewBuilder content: () -> Content) -> some View {
        ZStack {
            if loaded.contains(item) {
                content()
            }
        }
        .opacity(tab == item ? 1 : 0)
        .allowsHitTesting(tab == item)
        .accessibilityHidden(tab != item)
    }

    private func switchTo(_ item: Tab) {
        _ = loaded.insert(item)
        tab = item
        NotificationCenter.default.post(name: .appTabDidSelect, object: item.rawValue)
    }

    // MARK: 底部导航

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button {
                    switchTo(item)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon)
                            .font(.system(size: 19, weight: .medium))
                            .frame(height: 22)

                        Text(item.title)
                            .font(.system(size: 9.5, weight: .medium))
                    }
                    .foregroundStyle(tab == item ? theme.accent : theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 7)
        .padding(.bottom, 2)
        .background(theme.navBg.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                .frame(height: 0.5)
        }
    }
}

struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView()
    }
}
