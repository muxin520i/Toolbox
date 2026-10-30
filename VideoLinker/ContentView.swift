import SwiftUI
import UIKit

/// 一次播放请求（用 Identifiable 驱动 fullScreenCover）
struct PlayRequest: Identifiable {
    let id = UUID()
    let url: URL
}

struct ContentView: View {
    @State private var urlText = ""
    @State private var request: PlayRequest?
    @State private var items: [HistoryItem] = HistoryStore.load()
    @FocusState private var inputFocused: Bool

    @State private var playlists: [Playlist] = PlaylistStore.load()
    @State private var pendingHistoryItem: HistoryItem?
    @State private var showPlaylistPicker = false
    @State private var showNoPlaylistAlert = false

    /// Apple 官方公开测试流，用来快速验证播放器是否正常
    private let sampleURL = "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"

    var body: some View {
        ZStack {
            BackgroundView()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    inputCard
                    quickAction
                    if !items.isEmpty { historySection }
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 44)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
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
    }

    // MARK: - 顶部标题

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(
                    LinearGradient(
                        colors: [Color(red: 1.00, green: 0.42, blue: 0.31),
                                 Color(red: 0.72, green: 0.20, blue: 0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                )
                .shadow(color: Color(red: 0.85, green: 0.25, blue: 0.45).opacity(0.45),
                        radius: 18, x: 0, y: 10)

            Text("视频链接播放器")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)

            Text("粘贴视频直链即可播放，支持在线流")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.bottom, 2)
    }

    // MARK: - 输入区

    private var inputCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))

                TextField("", text: $urlText, prompt: Text("https://… / xxx.mp4").foregroundColor(.white.opacity(0.3)))
                    .focused($inputFocused)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .onSubmit(playCurrent)

                if !urlText.isEmpty {
                    Button {
                        urlText = ""
                        inputFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button("粘贴") { paste() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.45))
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(inputFocused ? Color.white.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1)
            )

            Button(action: playCurrent) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill").font(.system(size: 14, weight: .bold))
                    Text("开始播放").font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    LinearGradient(
                        colors: [Color(red: 1.00, green: 0.42, blue: 0.31),
                                 Color(red: 0.72, green: 0.20, blue: 0.85)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .opacity(resolvedURL == nil ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(resolvedURL == nil)
        }
        .padding(16)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: - 快捷操作

    private var quickAction: some View {
        HStack(spacing: 10) {
            Button {
                urlText = sampleURL
                playCurrent()
            } label: {
                Label("播放示例", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)

            Text("不确定格式？先用示例确认播放正常")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.35))
                .lineLimit(1)
        }
    }

    // MARK: - 历史记录

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近播放")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Button("清空") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        items = HistoryStore.clear()
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
                .buttonStyle(.plain)
            }

            VStack(spacing: 8) {
                ForEach(items) { item in
                    historyRow(item)
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
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.22))
            }
            .padding(11)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Color.white.opacity(0.08))
            Text("支持的格式")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 8)
            Text("MP4 / MOV / M4V 直链，以及 HLS 直播流（.m3u8）。\nYouTube、B 站等网页链接不是视频直链，需要先取得真实播放地址。")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.3))
                .lineSpacing(3)
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
}

// MARK: - 背景

struct BackgroundView: View {
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.08)

            Circle()
                .fill(Color(red: 0.85, green: 0.22, blue: 0.35).opacity(0.35))
                .frame(width: 320, height: 320)
                .blur(radius: 110)
                .offset(x: -120, y: -300)

            Circle()
                .fill(Color(red: 0.35, green: 0.20, blue: 0.95).opacity(0.30))
                .frame(width: 300, height: 300)
                .blur(radius: 120)
                .offset(x: 140, y: 120)

            Color.black.opacity(0.25)
        }
        .ignoresSafeArea()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
