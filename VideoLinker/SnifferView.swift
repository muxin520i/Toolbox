import SwiftUI
import WebKit
import UIKit

// MARK: - 浏览器视觉规范（对齐 Firefox for iOS）

enum FirefoxStyle {
    /// Photon Blue 60，Firefox 主色
    static let accent = Color(red: 0.0, green: 0.376, blue: 0.875)
    static let privateAccent = Color(red: 0.545, green: 0.361, blue: 0.965)

    static func bg(_ dark: Bool) -> Color {
        dark ? Color(red: 0.110, green: 0.106, blue: 0.133)
             : Color(red: 0.992, green: 0.992, blue: 0.996)
    }

    static func bar(_ dark: Bool) -> Color {
        dark ? Color(red: 0.169, green: 0.165, blue: 0.200) : .white
    }

    static func field(_ dark: Bool) -> Color {
        dark ? Color(red: 0.259, green: 0.255, blue: 0.302)
             : Color(red: 0.945, green: 0.945, blue: 0.965)
    }

    static func card(_ dark: Bool) -> Color {
        dark ? Color(red: 0.169, green: 0.165, blue: 0.200) : .white
    }

    static func text(_ dark: Bool) -> Color {
        dark ? Color(red: 0.984, green: 0.980, blue: 0.988)
             : Color(red: 0.082, green: 0.078, blue: 0.102)
    }

    static func sub(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.52) : Color.black.opacity(0.48)
    }

    static func line(_ dark: Bool) -> Color {
        dark ? Color.white.opacity(0.10) : Color.black.opacity(0.09)
    }
}

// MARK: - 嗅探结果

struct SniffedVideo: Identifiable, Hashable {
    var id: String { url }
    let url: String
    let host: String
    let kind: String

    var displayName: String {
        guard let u = URL(string: url) else { return url }
        var name = u.lastPathComponent
        if name.isEmpty || name == "/" {
            name = u.host ?? url
        }
        if let decoded = name.removingPercentEncoding {
            name = decoded
        }
        if name.count > 42 {
            name = String(name.prefix(42)) + "…"
        }
        return name
    }

    static func kind(of url: String) -> String {
        let lower = url.lowercased()
        if lower.contains(".m3u8") { return "HLS" }
        if lower.contains(".mp4") { return "MP4" }
        if lower.contains(".m4v") || lower.contains(".mov") { return "MOV" }
        if lower.contains(".webm") { return "WEBM" }
        if lower.contains(".flv") { return "FLV" }
        return "VIDEO"
    }
}

// MARK: - 同片多清晰度归组

extension SniffedVideo {
    /// 同一部片的不同清晰度：同域名，文件名去掉 1080p / 720p 这类标记后一致。
    /// 名字太通用（index、master 之类）就不合并，宁可多显示几条，也别把不同片子揉一起。
    var groupKey: String? {
        guard let link = URL(string: url) else { return nil }
        var name = link.deletingPathExtension().lastPathComponent
        if let decoded = name.removingPercentEncoding { name = decoded }

        let tokens = ["2160p", "1440p", "1080p", "720p", "480p", "360p", "240p",
                      "8k", "4k", "2k", "uhd", "fhd", "qhd", "hd", "sd",
                      "hevc", "h264", "h265", "av1", "bluray", "webrip", "hdr"]
        for token in tokens {
            name = name.replacingOccurrences(of: token, with: "", options: .caseInsensitive)
        }
        name = name.replacingOccurrences(of: "[^a-zA-Z0-9\\p{Han}]+", with: "", options: .regularExpression)

        guard name.count >= 4 else { return nil }
        let generic: Set<String> = ["index", "master", "playlist", "video", "media",
                                    "main", "output", "hls", "stream", "manifest", "movie"]
        guard !generic.contains(name.lowercased()) else { return nil }
        return (link.host ?? "") + "|" + name.lowercased()
    }
}

/// 嗅探结果里的一组：可能只有一条，也可能把同片的 1080p / 720p 收在一起
struct SniffGroup: Identifiable {
    let key: String
    let videos: [SniffedVideo]

    var id: String { key }
    var primary: SniffedVideo { videos[0] }
    var isMerged: Bool { videos.count > 1 }

    /// 组里最清晰的一条，点播放和「加入列表」默认用它
    var best: SniffedVideo {
        videos.max { qualityRank($0.url) < qualityRank($1.url) } ?? videos[0]
    }

    /// 按清晰度从高到低排，给选择清晰度的弹窗用
    var sorted: [SniffedVideo] {
        videos.sorted { qualityRank($0.url) > qualityRank($1.url) }
    }

    private func qualityRank(_ url: String) -> Int {
        if let height = MediaProbeStore.shared.info(for: url)?.height, height > 0 {
            return height
        }
        let lower = url.lowercased()
        for (token, rank) in [("2160", 2160), ("4k", 2160), ("1440", 1440),
                              ("1080", 1080), ("720", 720), ("480", 480), ("360", 360)] {
            if lower.contains(token) { return rank }
        }
        return 0
    }

    static func build(from list: [SniffedVideo]) -> [SniffGroup] {
        var order: [String] = []
        var buckets: [String: [SniffedVideo]] = [:]

        for video in list {
            let key = video.groupKey ?? "single:\(video.url)"
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            if buckets[key]?.contains(where: { $0.url == video.url }) == false {
                buckets[key]?.append(video)
            }
        }

        return order.compactMap { key in
            guard let videos = buckets[key], !videos.isEmpty else { return nil }
            return SniffGroup(key: key, videos: videos)
        }
    }
}

// MARK: - 面板

private enum BrowserSheet: String, Identifiable {
    case tabs, menu, sniff, history, bookmarks, downloads, settings, scripts

    var id: String { rawValue }
}

// MARK: - 嗅探 / 浏览器页

struct SnifferView: View {
    var body: some View {
        BrowserView()
    }
}

struct BrowserView: View {
    @StateObject private var store = BrowserStore()
    @ObservedObject private var library = UserscriptLibrary.shared
    @ObservedObject private var bookmarks = BookmarkLibrary.shared

    @AppStorage(SettingsKey.uaMode) private var uaMode = UAMode.mobile.rawValue
    @AppStorage(SettingsKey.customUA) private var customUA = ""
    @AppStorage(SettingsKey.adBlock) private var adBlock = true
    @AppStorage(SettingsKey.searchEngine) private var engineRaw = SearchEngine.baidu.rawValue
    @AppStorage(SettingsKey.customSearch) private var customSearch = ""
    @AppStorage(SettingsKey.homePage) private var homePage = ""
    @AppStorage(SettingsKey.noImage) private var noImage = false

    @Environment(\.colorScheme) private var scheme

    /// 网页夜间效果直接跟随 App 外观（设置 → 外观），不再单独放开关
    private var night: Bool { scheme == .dark }

    @State private var address = ""
    @State private var editing = false
    @FocusState private var addressFocused: Bool

    @State private var sheet: BrowserSheet?
    /// 当前 sheet 里正在显示的内容。换面板时只改它，不再“先关再开”
    @State private var renderedSheet: BrowserSheet?
    @State private var pendingSheet: BrowserSheet?
    @State private var draft: ShortcutDraft?
    @State private var pendingDraft: ShortcutDraft?

    @State private var shareItems: [Any] = []
    @State private var showShare = false

    @State private var findText = ""
    @State private var showFind = false
    @State private var findFound = true

    @State private var toast: String?
    @State private var booted = false

    @State private var request: PlayRequest?
    @State private var playlists: [Playlist] = []
    @State private var pendingVideo: SniffedVideo?
    @State private var showPicker = false
    @State private var showNoPlaylist = false

    private var tab: BrowserTab? { store.current }
    private var isDark: Bool { scheme == .dark }

    private var effectiveUA: String? {
        switch UAMode(rawValue: uaMode) ?? .mobile {
        case .mobile:
            return nil
        case .desktop:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        case .custom:
            let trimmed = customUA.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private var currentBookmarked: Bool {
        guard let tab = tab, !tab.urlString.isEmpty else { return false }
        return bookmarks.contains(tab.urlString)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !(tab?.isHome ?? true) {
                topBar
            }

            ZStack(alignment: .top) {
                BrowserWebHost(store: store)

                if let tab = tab {
                    if tab.isHome {
                        homeView
                    }

                    if let error = tab.errorText {
                        errorPanel(tab, error)
                    }

                    if !tab.isHome {
                        FloatingSniffButton(count: tab.found.count + tab.images.count) {
                            // 点了就开嗅探结果页，挑哪条自己定，不再替用户盲下一条
                            addressFocused = false
                            editing = false
                            present(.sniff)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showFind {
                findBar
            }

            bottomBar
        }
        .background(FirefoxStyle.bg(isDark))
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .overlay(alignment: .center) {
            if let text = toast {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black.opacity(0.84))
                    )
                    .transition(.opacity)
            }
        }
        .onAppear {
            if !booted {
                booted = true
                store.bootstrap()
                syncStore()
            }
        }
        .onChange(of: uaMode) { _ in syncStore() }
        .onChange(of: customUA) { _ in syncStore() }
        .onChange(of: adBlock) { _ in syncStore() }
        .onChange(of: engineRaw) { _ in syncStore() }
        .onChange(of: customSearch) { _ in syncStore() }
        .onChange(of: scheme) { _ in syncStore() }
        .onChange(of: noImage) { _ in syncStore() }
        .onChange(of: tab?.id) { _ in
            editing = false
            showFind = false
            address = ""
        }
        .onReceive(library.$scripts) { _ in syncStore() }
        .onReceive(NotificationCenter.default.publisher(for: .browserAppearanceChanged)) { _ in
            syncStore()
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoSavedFromWeb)) { _ in
            showToast("已存进备忘录")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openInBrowser)) { note in
            guard let url = note.object as? String, !url.isEmpty else { return }
            openInBrowser(url)
        }
        .fullScreenCover(item: $request) { req in
            PlayerScreen(request: req)
        }
        .sheet(isPresented: sheetPresented, onDismiss: handleDismiss) {
            if let item = renderedSheet {
                if item == .menu {
                    sheetContent(item)
                        .id(item.rawValue)
                } else {
                    // 菜单是半屏，其余面板给足高度
                    sheetContent(item)
                        .id(item.rawValue)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
            }
        }
        .sheet(item: $draft) { item in
            ShortcutEditor(draft: item)
        }
        .sheet(isPresented: $showShare) {
            ActivityView(items: shareItems)
        }
        .confirmationDialog("加入哪个列表", isPresented: $showPicker, titleVisibility: .visible) {
            ForEach(playlists) { playlist in
                Button(playlist.name) {
                    if let video = pendingVideo {
                        PlaylistStore.add(
                            PlaylistItem(url: video.url, title: video.displayName),
                            to: playlist.id
                        )
                    }
                    pendingVideo = nil
                }
            }
            Button("取消", role: .cancel) { pendingVideo = nil }
        }
        .alert("还没有播放列表", isPresented: $showNoPlaylist) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("先去「列表」标签页新建一个播放列表。")
        }
    }

    // MARK: 顶部地址栏

    private var topBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if editing {
                    editField
                    Button("取消") { cancelEditing() }
                        .font(.system(size: 15))
                        .foregroundStyle(FirefoxStyle.accent)
                        .buttonStyle(.plain)
                } else {
                    browseField
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 2)

                if let tab = tab, tab.isLoading {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(FirefoxStyle.accent)
                            .frame(width: geo.size.width * max(0.02, tab.progress), height: 2)
                    }
                    .frame(height: 2)
                }
            }
        }
        .background(FirefoxStyle.bar(isDark))
    }

    private var editField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(FirefoxStyle.sub(isDark))

            TextField(
                "",
                text: $address,
                prompt: Text("搜索或输入网址").foregroundColor(FirefoxStyle.sub(isDark))
            )
            .focused($addressFocused)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .font(.system(size: 15))
            .foregroundStyle(FirefoxStyle.text(isDark))
            .onSubmit { submit() }

            if !address.isEmpty {
                Button {
                    address = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(FirefoxStyle.sub(isDark).opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(FirefoxStyle.field(isDark))
        )
    }

    private var browseField: some View {
        HStack(spacing: 6) {
            Image(systemName: (tab?.isSecure ?? false) ? "lock.fill" : "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FirefoxStyle.sub(isDark))
                .frame(width: 13)

            Text(displayAddress)
                .font(.system(size: 15))
                .foregroundStyle(FirefoxStyle.text(isDark))
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            Button {
                if tab?.isLoading == true {
                    tab?.stop()
                } else {
                    tab?.reload()
                }
            } label: {
                Image(systemName: tab?.isLoading == true ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FirefoxStyle.sub(isDark))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(FirefoxStyle.field(isDark))
        )
        .contentShape(Rectangle())
        .onTapGesture { beginEditing() }
    }

    private var displayAddress: String {
        guard let tab = tab, !tab.urlString.isEmpty else { return "搜索或输入网址" }
        let host = tab.hostText
        return host.isEmpty ? tab.urlString : host
    }

    // MARK: 主页

    private var homeView: some View {
        BrowserHomeView(
            query: $address,
            onSubmit: { submit() },
            onOpen: { url in
                address = url
                store.load(url)
            },
            onOpenHistory: { present(.history) },
            onOpenBookmarks: { present(.bookmarks) },
            onAddShortcut: {
                pendingDraft = ShortcutDraft(item: nil, prefillURL: nil, prefillTitle: nil)
                sheet = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                    if let item = pendingDraft {
                        pendingDraft = nil
                        draft = item
                    }
                }
            },
            onEditShortcut: { item in
                draft = ShortcutDraft(item: item, prefillURL: nil, prefillTitle: nil)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 底部工具栏（后退 / 前进 / 主页 / 标签 / 菜单）

    private var bottomBar: some View {
        HStack(spacing: 0) {
            toolButton("chevron.left", enabled: tab?.canGoBack ?? false) { tab?.goBack() }
            toolButton("chevron.right", enabled: tab?.canGoForward ?? false) { tab?.goForward() }
            toolButton("house", enabled: true) { goHome() }
            tabsButton
            toolButton("line.3.horizontal", enabled: true) { openMenu() }
        }
        .frame(height: 50)
        .background(FirefoxStyle.bar(isDark))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(FirefoxStyle.line(isDark))
                .frame(height: 0.5)
        }
    }

    private func toolButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(
                    enabled
                        ? FirefoxStyle.text(isDark).opacity(0.9)
                        : FirefoxStyle.text(isDark).opacity(0.22)
                )
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var tabsButton: some View {
        Button {
            addressFocused = false
            editing = false
            present(.tabs)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(FirefoxStyle.text(isDark).opacity(0.85), lineWidth: 1.6)
                Text("\(store.tabs.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FirefoxStyle.text(isDark))
            }
            .frame(width: 20, height: 20)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 错误页

    private func errorPanel(_ tab: BrowserTab, _ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(FirefoxStyle.sub(isDark))

            Text("网页打不开")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(FirefoxStyle.text(isDark))

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(FirefoxStyle.sub(isDark))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 34)

            HStack(spacing: 12) {
                Button("重新加载") {
                    tab.errorText = nil
                    tab.reload()
                }
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Capsule().fill(FirefoxStyle.field(isDark)))

                Button("桌面版网站") {
                    uaMode = UAMode(rawValue: uaMode) == .desktop
                        ? UAMode.mobile.rawValue
                        : UAMode.desktop.rawValue
                }
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Capsule().fill(FirefoxStyle.field(isDark)))
            }
            .foregroundStyle(FirefoxStyle.text(isDark))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FirefoxStyle.bg(isDark))
    }

    // MARK: 页内查找

    private var findBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(FirefoxStyle.sub(isDark))
                TextField("在页面中查找", text: $findText)
                    .font(.system(size: 14))
                    .foregroundStyle(FirefoxStyle.text(isDark))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { runFind(backwards: false) }
                    .onChange(of: findText) { _ in runFind(backwards: false) }
                if !findText.isEmpty {
                    Text(findFound ? "找到" : "无结果")
                        .font(.system(size: 10.5))
                        .foregroundStyle(findFound ? Color.green : FirefoxStyle.sub(isDark))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(FirefoxStyle.field(isDark))
            )

            Button { runFind(backwards: true) } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FirefoxStyle.sub(isDark))
            }
            .buttonStyle(.plain)

            Button { runFind(backwards: false) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FirefoxStyle.sub(isDark))
            }
            .buttonStyle(.plain)

            Button {
                showFind = false
                addressFocused = false
                findText = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FirefoxStyle.sub(isDark))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(FirefoxStyle.bar(isDark))
    }

    // MARK: 面板内容

    @ViewBuilder
    private func sheetContent(_ item: BrowserSheet) -> some View {
        switch item {
        case .tabs:
            TabSwitcherView(store: store)
        case .menu:
            BrowserMenuSheet(
                store: store,
                library: library,
                isBookmarked: currentBookmarked,
                foundCount: (tab?.found.count ?? 0) + (tab?.images.count ?? 0),
                onAction: { action in handle(action) }
            )
        case .sniff:
            if let tab = tab {
                SniffResultsPanel(
                    tab: tab,
                    onPlay: { play($0) },
                    onAddToPlaylist: { addToPlaylist($0) }
                )
            } else {
                EmptyView()
            }
        case .history:
            BrowserHistoryView { url in openFromPanel(url) }
        case .bookmarks:
            BookmarksView { url in openFromPanel(url) }
        case .downloads:
            DownloadsView { url in playFile(url) }
        case .settings:
            BrowserSettingsView(library: library)
        case .scripts:
            UserscriptListView(library: library)
        }
    }

    private func handleDismiss() {
        renderedSheet = nil
        if let item = pendingDraft {
            pendingDraft = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                draft = item
            }
            return
        }
        if let next = pendingSheet {
            pendingSheet = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                present(next)
            }
        }
    }

    private var sheetPresented: Binding<Bool> {
        Binding(get: { sheet != nil }, set: { if !$0 { sheet = nil } })
    }

    /// 在同一个 sheet 里换面板：菜单点书签/历史直接切内容，省掉关闭+重新弹出的 0.6 秒
    private func present(_ next: BrowserSheet) {
        renderedSheet = next
        sheet = next
    }

    private func openPanel(_ next: BrowserSheet) {
        present(next)
    }

    // MARK: 动作

    private func submit() {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            cancelEditing()
            return
        }
        addressFocused = false
        editing = false
        showFind = false
        store.openSmart(text)
    }

    private func beginEditing() {
        address = tab?.urlString ?? ""
        editing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            addressFocused = true
        }
    }

    private func cancelEditing() {
        addressFocused = false
        editing = false
        address = ""
    }

    private func goHome() {
        addressFocused = false
        cancelEditing()
        showFind = false
        let home = homePage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !home.isEmpty {
            store.load(home)
        } else {
            tab?.showHome()
        }
    }

    /// 从脚本页跳过来：先把弹窗收干净，再在内置浏览器里打开网址
    private func openInBrowser(_ url: String) {
        addressFocused = false
        editing = false
        showFind = false
        address = ""
        sheet = nil
        pendingSheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            store.load(url)
        }
    }

    private func openMenu() {
        addressFocused = false
        editing = false
        if tab == nil { return }
        present(.menu)
    }

    private func handle(_ action: BrowserMenuAction) {
        guard let tab = tab else { return }

        switch action {
        case .bookmark:
            sheet = nil
            toggleBookmark(tab)

        case .memo:
            sheet = nil
            savePageToMemo(tab)

        case .reload:
            sheet = nil
            tab.reload()

        case .share:
            let text = tab.urlString
            guard !text.isEmpty else {
                sheet = nil
                showToast("当前没有可分享的网址")
                return
            }
            sheet = nil
            shareLater([text])

        case .copyURL:
            sheet = nil
            UIPasteboard.general.string = tab.urlString
            showToast("链接已复制")

        case .addShortcut:
            let title = tab.title.isEmpty ? tab.hostText : tab.title
            pendingDraft = ShortcutDraft(item: nil, prefillURL: tab.urlString, prefillTitle: title)
            sheet = nil

        case .tabs:
            openPanel(.tabs)

        case .history:
            openPanel(.history)

        case .downloads:
            openPanel(.downloads)

        case .bookmarks:
            openPanel(.bookmarks)

        case .readingList:
            openPanel(.bookmarks)

        case .find:
            sheet = nil
            showFind = true
            addressFocused = false

        case .autoScroll:
            sheet = nil
            // 等菜单收完再执行，不然页面上的滚动会被转场打断
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                tab.toggleAutoScroll()
            }

        case .scripts:
            openPanel(.scripts)

        case .sniff:
            openPanel(.sniff)

        case .settings:
            openPanel(.settings)
        }
    }

    private func toggleBookmark(_ tab: BrowserTab) {
        guard !tab.urlString.isEmpty else {
            showToast("先打开一个网页")
            return
        }
        if bookmarks.contains(tab.urlString) {
            if let hit = bookmarks.items.first(where: { $0.url == tab.urlString }) {
                bookmarks.remove(hit)
                showToast("已取消收藏")
            }
        } else {
            let title = tab.title.isEmpty ? tab.hostText : tab.title
            bookmarks.add(title: title, url: tab.urlString)
            showToast("已收藏")
        }
    }

    /// 菜单里的兜底入口：优先存选中的文字，没选就存本页标题和地址
    private func savePageToMemo(_ tab: BrowserTab) {
        guard !tab.urlString.isEmpty else {
            showToast("先打开一个网页")
            return
        }
        tab.webView.evaluateJavaScript("window.getSelection ? window.getSelection().toString() : ''") { result, _ in
            let selection = (result as? String) ?? ""
            DispatchQueue.main.async {
                let memo = MemoStore.shared.addFromWeb(selection: selection,
                                                       pageTitle: tab.title,
                                                       pageURL: tab.urlString)
                if memo == nil {
                    showToast("没有可保存的内容")
                } else {
                    showToast(selection.isEmpty ? "已把本页存进备忘" : "已存进备忘录")
                }
            }
        }
    }

    private func runReader(_ tab: BrowserTab) {
        tab.webView.evaluateJavaScript(BrowserInject.readerRun) { result, _ in
            let ok = (result as? Bool) ?? false
            if !ok {
                showToast("这个页面没法进入阅读模式")
            } else {
                showToast("已进入阅读模式，刷新可退出")
            }
        }
    }

    private func runFind(backwards: Bool) {
        guard let tab = tab, !findText.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        config.caseSensitive = false
        tab.webView.find(findText, configuration: config) { result in
            findFound = result.matchFound
        }
    }

    private func shareLater(_ items: [Any]) {
        shareItems = items
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            showShare = true
        }
    }

    private func openFromPanel(_ url: String) {
        sheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            address = url
            store.load(url)
        }
    }

    private func playFile(_ url: URL) {
        sheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            request = PlayRequest(url: url)
        }
    }

    private func play(_ video: SniffedVideo) {
        guard let url = URL(string: video.url) else { return }
        sheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            request = PlayRequest(url: url)
        }
    }

    private func addToPlaylist(_ video: SniffedVideo) {
        playlists = PlaylistStore.visible()
        pendingVideo = video
        if playlists.isEmpty {
            showNoPlaylist = true
        } else {
            showPicker = true
        }
    }

    private func syncStore() {
        var options = BrowserOptions()
        options.userAgent = effectiveUA
        options.adBlock = adBlock
        options.night = night
        options.noImage = noImage
        options.userscripts = library.scripts
        options.engineRaw = engineRaw
        options.customSearch = customSearch

        store.apply(options)
        // 幂等，多调一次没有副作用；避免开关切了页面没反应
        store.applyAppearance()
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            toast = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
            if toast == text {
                withAnimation(.easeIn(duration: 0.2)) {
                    toast = nil
                }
            }
        }
    }
}

struct SnifferView_Previews: PreviewProvider {
    static var previews: some View {
        SnifferView()
    }
}
