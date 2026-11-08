import Foundation
import AppIntents

// MARK: - 用「Siri / 快捷指令」控制播放
//
// 三条入口：
//   播放链接 —— 把直链丢进来
//   继续看上次的视频 —— 读播放进度里最近的一条
//   播放指定视频 —— 按名字在本机视频里找

/// 用「快捷指令」或 Siri 直接把链接丢进来播放
struct PlayLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "播放视频链接"
    static var description = IntentDescription("把视频直链交给工具箱立即播放。")
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

/// 「继续看上次那个」：从观看进度里挑更新时间最近、还值得续播的一条
struct ResumeLastVideoIntent: AppIntent {
    static var title: LocalizedStringResource = "继续看上次的视频"
    static var description = IntentDescription("打开工具箱，接着上次看到的位置继续播放。")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = await MainActor.run { () -> URL? in
            let table = ResumeStore.all()
            let sorted = table.sorted { $0.value.updated > $1.value.updated }

            for (raw, entry) in sorted {
                // 太短、快看完的不算「上次没看完」
                guard entry.duration > 30, entry.duration - entry.position > 15 else { continue }

                if let url = URL(string: raw), url.scheme != nil {
                    if url.isFileURL {
                        if FileManager.default.fileExists(atPath: url.path) { return url }
                    } else {
                        return url
                    }
                }
                if FileManager.default.fileExists(atPath: raw) {
                    return URL(fileURLWithPath: raw)
                }
            }
            return nil
        }

        guard let url = target else {
            return .result(dialog: "还没有没看完的视频，先在工具箱里看一个吧。")
        }
        await MainActor.run {
            Router.shared.pending = PlayRequest(url: url)
        }
        return .result(dialog: "好，接着上次的继续。")
    }
}

/// 「播放某某」：在本机视频里按名字找
struct PlayNamedVideoIntent: AppIntent {
    static var title: LocalizedStringResource = "播放指定视频"
    static var description = IntentDescription("按名字在工具箱的本机视频里找一部并播放。")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "视频名字", description: "片子名字的一部分就行")
    var keyword: String

    static var parameterSummary: some ParameterSummary {
        Summary("播放 \(\.$keyword)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return .result(dialog: "没听清要看哪一部。")
        }

        let files = await LocalMedia.scan(limit: 400, probeDuration: false)
        let matches = files.filter { $0.title.localizedCaseInsensitiveContains(key) }
        guard let first = matches.first else {
            return .result(dialog: "本机视频里没找到「\(key)」。")
        }

        await MainActor.run {
            Router.shared.pending = PlayRequest(url: first.url)
        }
        if matches.count > 1 {
            return .result(dialog: "找到 \(matches.count) 部，先播《\(first.title)》。")
        }
        return .result(dialog: "正在播放《\(first.title)》。")
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
        AppShortcut(
            intent: ResumeLastVideoIntent(),
            phrases: [
                "用 \(.applicationName) 继续看",
                "在 \(.applicationName) 接着上次看"
            ],
            shortTitle: "继续看",
            systemImageName: "play.circle.fill"
        )
        AppShortcut(
            intent: PlayNamedVideoIntent(),
            phrases: [
                "用 \(.applicationName) 播放 \(\.$keyword)"
            ],
            shortTitle: "播放视频",
            systemImageName: "text.magnifyingglass"
        )
    }
}
