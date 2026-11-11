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
    @AppStorage(SettingsKey.theme) private var themeRaw = AppTheme.system.rawValue
    @AppStorage(SettingsKey.tint) private var tintRaw = AppTint.coral.rawValue
    @AppStorage(SettingsKey.motion) private var motion = true

    @State private var tab: Tab = .play

    @ObservedObject private var undo = UndoCenter.shared

    private var appTheme: AppTheme {
        AppTheme(rawValue: themeRaw) ?? .system
    }

    private var resolvedScheme: ColorScheme {
        appTheme.colorScheme ?? systemScheme
    }

    private var theme: Theme {
        Theme(resolvedScheme, tint: AppTint(rawValue: tintRaw) ?? .coral)
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
        .onChange(of: tintRaw) { _ in
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
        .overlay(alignment: .bottom) {
            if let pending = undo.pending {
                undoBar(pending)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 76)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - 删除撤销

    private func undoBar(_ pending: UndoCenter.Pending) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.textSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(pending.count == 1
                     ? "已从「\(pending.playlistName)」移除"
                     : "已从「\(pending.playlistName)」移除 \(pending.count) 个")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(pending.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Button {
                withAnimation(.easeOut(duration: 0.18)) { UndoCenter.shared.undo() }
            } label: {
                Text("撤销")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeOut(duration: 0.18)) { UndoCenter.shared.dismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.card)
                .shadow(color: Color.black.opacity(0.16), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 0.5)
        )
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
