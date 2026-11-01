import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.theme) private var theme

    @State private var urlText = ""
    @State private var request: PlayRequest?
    @State private var items: [HistoryItem] = HistoryStore.load()
    @State private var favorites: Set<String> = ResumeStore.favorites()
    @State private var searchText = ""
    @State private var onlyFavorites = false
    @FocusState private var inputFocused: Bool

    @State private var playlists: [Playlist] = PlaylistStore.load()
    @State private var pendingHistoryItem: HistoryItem?
    @State private var showPlaylistPicker = false
    @State private var showNoPlaylistAlert = false

    @ObservedObject private var downloads = DownloadManager.shared
    @State private var showDownloads = false
    @State private var showLocalMedia = false
    @State private var downloadHint: String?

    var body: some View {
        ZStack {
            BackgroundView()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    inputCard
                    downloadEntry
                    localEntry
                    if !items.isEmpty { historySection }
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 44)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            items = HistoryStore.load()
            favorites = ResumeStore.favorites()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appTabDidSelect)) { note in
            guard (note.object as? Int) == RootView.Tab.play.rawValue else { return }
            items = HistoryStore.load()
            favorites = ResumeStore.favorites()
            playlists = PlaylistStore.load()
        }
        .confirmationDialog("加入哪个列表", isPresented: $showPlaylistPicker, titleVisibility: .visible) {
            ForEach(playlists) { playlist in
                Button(playlist.name) {
                    if let item = pendingHistoryItem {
                        PlaylistStore.add(
                            PlaylistItem(url: item.url, title: item.displayName),
                            to: playlist.id
                        )
                    }
                    pendingHistoryItem = nil
                }
            }
            Button("取消", role: .cancel) { pendingHistoryItem = nil }
        }
        .alert("还没有播放列表", isPresented: $showNoPlaylistAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("先到「列表」标签页新建一个播放列表，再回来添加。")
        }
        .fullScreenCover(item: $request) { req in
            PlayerScreen(request: req)
        }
        .sheet(isPresented: $showDownloads) {
            DownloadsView { url in
                showDownloads = false
                // 等弹窗收完再起全屏播放，避免两个呈现冲突被吞掉
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    request = PlayRequest(url: url)
                }
            }
        }
        .sheet(isPresented: $showLocalMedia) {
            LocalMediaView()
        }
        .alert("下载", isPresented: hintBinding) {
            Button("知道了", role: .cancel) { downloadHint = nil }
        } message: {
            Text(downloadHint ?? "")
        }
        .onReceive(Router.shared.$pending) { req in
            guard let req = req else { return }
            items = HistoryStore.load()
            request = req
            Router.shared.pending = nil
        }
    }

    // MARK: - 顶部标题

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(theme.gradientTopLeft,
                            in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .shadow(color: Color(red: 0.85, green: 0.25, blue: 0.45).opacity(theme.isDark ? 0.45 : 0.25),
                        radius: 18, x: 0, y: 10)

            Text("视频链接播放器")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(theme.text)

            Text("粘贴视频直链即可播放，支持在线流与 20+ 格式")
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.bottom, 2)
    }

    // MARK: - 输入区

    private var inputCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)

                TextField("", text: $urlText,
                          prompt: Text("https://… / xxx.mp4").foregroundColor(theme.textTertiary))
                    .focused($inputFocused)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.text)
                    .onSubmit(playCurrent)

                if !urlText.isEmpty {
                    Button {
                        urlText = ""
                        inputFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button("粘贴") { paste() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(theme.field, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(inputFocused ? theme.accent.opacity(0.6) : theme.cardStroke, lineWidth: 1)
            )

            HStack(spacing: 10) {
                Button(action: playCurrent) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill").font(.system(size: 14, weight: .bold))
                        Text("开始播放").font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(theme.gradient,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .opacity(resolvedURL == nil ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .disabled(resolvedURL == nil)

                Button(action: downloadCurrent) {
                    VStack(spacing: 3) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 17, weight: .semibold))
                        Text("下载")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(theme.accent)
                    .frame(width: 76, height: 52)
                    .background(theme.field, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1)
                    )
                    .opacity(resolvedURL == nil ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .disabled(resolvedURL == nil)
            }
        }
        .padding(16)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    // MARK: - 下载入口

    private var runningDownload: DownloadItem? {
        downloads.runningItem
    }

    private var downloadEntry: some View {
        Button {
            showDownloads = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(theme.accent)

                Text("下载管理")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)

                if !downloads.items.isEmpty {
                    Text("\(downloads.items.count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(theme.accent, in: Capsule())
                }

                Spacer()

                if let running = runningDownload {
                    DownloadRunningLabel(
                        item: running,
                        secondary: theme.textTertiary,
                        accent: theme.accent
                    )
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.cardStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var localEntry: some View {
        Button {
            showLocalMedia = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.accent)

                Text("本机视频")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)

                Spacer()

                Text("扫描 / 导入")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.cardStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var hintBinding: Binding<Bool> {
        Binding(
            get: { downloadHint != nil },
            set: { if !$0 { downloadHint = nil } }
        )
    }

    /// 直链直接下，m3u8 走分片下载
    private func downloadCurrent() {
        guard let url = resolvedURL else { return }
        inputFocused = false

        let raw = url.absoluteString
        switch downloads.start(from: raw) {
        case .started(let item):
            items = HistoryStore.add(HistoryItem(url: raw, date: Date()))
            downloadHint = "已开始下载「\(item.fileName)」，进度在「下载管理」里看。"
        case .failed(let reason):
            downloadHint = reason
        }
    }

    // MARK: - 历史记录

    private var filteredItems: [HistoryItem] {
        var list = items
        if onlyFavorites {
            list = list.filter { favorites.contains($0.url) }
        }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !keyword.isEmpty {
            list = list.filter {
                $0.url.lowercased().contains(keyword) || $0.displayName.lowercased().contains(keyword)
            }
        }
        return list
    }

    /// 首页只保留最近 3 条，新的把旧的顶下去
    private var recentItems: [HistoryItem] {
        Array(filteredItems.prefix(3))
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近播放")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text)

                Spacer()

                Button {
                    onlyFavorites.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: onlyFavorites ? "star.fill" : "star")
                        Text("收藏")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(onlyFavorites ? theme.accent : theme.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(onlyFavorites ? theme.accent.opacity(0.14) : theme.field, in: Capsule())
                }
                .buttonStyle(.plain)

                Button("清空") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        items = HistoryStore.clear()
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(theme.textTertiary)
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textTertiary)
                TextField("", text: $searchText,
                          prompt: Text("搜索链接或标题").foregroundColor(theme.textTertiary))
                    .font(.system(size: 14))
                    .foregroundStyle(theme.text)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(spacing: 8) {
                if recentItems.isEmpty {
                    Text(onlyFavorites ? "还没有收藏的视频" : "没有匹配的记录")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    ForEach(recentItems) { item in
                        historyRow(item)
                    }
                }
            }
        }
    }

    private func historyRow(_ item: HistoryItem) -> some View {
        Button {
            guard let u = URL(string: item.url) else { return }
            items = HistoryStore.add(item)
            request = PlayRequest(url: u)
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(theme.field)
                        .frame(width: 46, height: 46)

                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.textSecondary)
                }
                .overlay(alignment: .bottom) {
                    if let progress = ResumeStore.progress(for: item.url), progress > 0.02, progress < 0.98 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.18))
                                Capsule().fill(theme.accent)
                                    .frame(width: geo.size.width * progress)
                            }
                        }
                        .frame(height: 3)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 4)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if favorites.contains(item.url) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.accent)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(11)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                toggleFavorite(item)
            } label: {
                Label(favorites.contains(item.url) ? "取消收藏" : "收藏",
                      systemImage: favorites.contains(item.url) ? "star.slash" : "star")
            }

            Button {
                pendingHistoryItem = item
                playlists = PlaylistStore.load()
                if playlists.isEmpty {
                    showNoPlaylistAlert = true
                } else {
                    showPlaylistPicker = true
                }
            } label: {
                Label("加入播放列表", systemImage: "text.badge.plus")
            }

            Button {
                UIPasteboard.general.string = item.url
            } label: {
                Label("复制链接", systemImage: "doc.on.doc")
            }

            Button(role: .destructive) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    items = HistoryStore.remove(item)
                }
            } label: {
                Label("删除这条记录", systemImage: "trash")
            }
        }
    }

    // MARK: - 底部说明

    private func formatLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(theme.cardStroke)
            Text("支持的格式")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 5) {
                formatLine("系统播放器", "MP4 / M4V / MOV / HLS（.m3u8，含 AES-128 加密分片）")
                formatLine("VLC 兜底", "MKV / FLV / AVI / RMVB / WMV / WebM / TS / M2TS / MPG / OGV / 3GP / ASF / VOB / F4V")
                formatLine("音频", "M4A / MP3 / AAC / WAV / FLAC")
                formatLine("下载", "直链原样保存；m3u8 自动抓取全部分片并合并为 MP4")
            }
            .padding(.top, 2)

            Text("YouTube、B 站等网页链接不是视频直链，需要先取得真实播放地址。")
                .font(.system(size: 12))
                .foregroundStyle(theme.textTertiary)
                .lineSpacing(3)
                .padding(.top, 6)
        }
    }

    // MARK: - 逻辑

    /// 输入内容的规范化 URL：自动补 https://，过滤明显非法的输入
    private var resolvedURL: URL? {
        var s = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        guard let u = URL(string: s), let host = u.host, host.contains(".") else { return nil }
        return u
    }

    private func playCurrent() {
        guard let url = resolvedURL else { return }
        inputFocused = false
        items = HistoryStore.add(HistoryItem(url: url.absoluteString, date: Date()))
        request = PlayRequest(url: url)
    }

    private func paste() {
        if let s = UIPasteboard.general.string, !s.isEmpty {
            urlText = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func toggleFavorite(_ item: HistoryItem) {
        ResumeStore.toggleFavorite(item.url)
        favorites = ResumeStore.favorites()
    }

}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

/// 首页下载条右侧的进度。
/// 必须单独观察 DownloadItem：外层只观察 DownloadManager，
/// 数组没变时不会因为 item.progress 更新而重绘，进度就会一直停在 0%。
private struct DownloadRunningLabel: View {
    @ObservedObject var item: DownloadItem
    let secondary: Color
    let accent: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(item.fileName)
                .font(.system(size: 11))
                .foregroundStyle(secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(accent)
        }
    }

    private var statusText: String {
        if !item.note.isEmpty { return item.note }
        switch item.state {
        case .queued: return "排队中"
        case .paused: return "已暂停"
        case .failed: return "失败"
        default:
            let speed = item.speedText
            return speed.isEmpty ? "\(Int(item.progress * 100))%" : speed
        }
    }
}
