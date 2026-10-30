import Foundation
import AppIntents

/// 用「快捷指令」或 Siri 直接把链接丢进来播放
struct PlayLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "播放视频链接"
    static var description = IntentDescription("把视频直链交给 VideoLinker 立即播放。")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "视频链接", description: "http 或 https 开头的视频直链")
    var link: String

    static var parameterSummary: some ParameterSummary {
        Summary("播放 \(\.$link)")
    }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            Router.shared.handleString(link)
        }
        return .result()
    }
}

struct VideoLinkerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayLinkIntent(),
            phrases: [
                "用 \(.applicationName) 播放视频",
                "在 \(.applicationName) 里打开链接"
            ],
            shortTitle: "播放链接",
            systemImageName: "play.rectangle.fill"
        )
    }
}
