import SwiftUI
import UIKit

struct RootView: View {
    enum Tab: Int {
        case play, lists, sniffer
    }

    @State private var tab: Tab = .play

    init() {
        Self.configureTabBar()
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

            SnifferView()
                .tabItem {
                    Label("嗅探", systemImage: "safari.fill")
                }
                .tag(Tab.sniffer)
        }
        .tint(Color(red: 1.0, green: 0.55, blue: 0.45))
        .preferredColorScheme(.dark)
    }

    private static func configureTabBar() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.055, green: 0.055, blue: 0.075, alpha: 1)
        appearance.shadowColor = UIColor.white.withAlphaComponent(0.08)

        let item = UITabBarItemAppearance()
        item.normal.iconColor = UIColor.white.withAlphaComponent(0.32)
        item.normal.titleTextAttributes = [
            .foregroundColor: UIColor.white.withAlphaComponent(0.32)
        ]
        item.selected.iconColor = UIColor(red: 1.0, green: 0.55, blue: 0.45, alpha: 1)
        item.selected.titleTextAttributes = [
            .foregroundColor: UIColor(red: 1.0, green: 0.55, blue: 0.45, alpha: 1)
        ]

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
