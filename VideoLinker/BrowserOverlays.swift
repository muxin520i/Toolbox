import SwiftUI
import UIKit

// MARK: - 标签页切换

struct TabSwitcherView: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 148), spacing: 12)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.tabs) { tab in
                        card(tab)
                    }
                }
                .padding(14)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 14) {
                    Button {
                        store.newTab()
                        dismiss()
                    } label: {
                        Label("新建标签", systemImage: "plus")
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.16))
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        store.privateMode.toggle()
                        store.newTab()
                        dismiss()
                    } label: {
                        Label("无痕", systemImage: "eyeglasses")
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.purple.opacity(0.14))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .background(.ultraThinMaterial)
            }
            .navigationTitle("标签页 \(store.tabs.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func card(_ tab: BrowserTab) -> some View {
        let isCurrent = store.current?.id == tab.id

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: tab.isPrivate ? "eyeglasses" : (tab.isSecure ? "lock.fill" : "globe"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(tab.hostText.isEmpty ? "新标签页" : tab.hostText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Text(tab.displayTitle)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button {
                    store.close(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(height: 118)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(isCurrent ? Color.accentColor : Color.clear, lineWidth: 1.6)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.select(tab)
            dismiss()
        }
    }
}

// MARK: - 菜单（对齐 Firefox for iOS）

enum BrowserMenuAction {
    case bookmarks
    case readingList
    case history
    case downloads
    case scripts
    case sniff
    case find
    case settings
    case bookmark
    case reload
    case share
    case copyURL
    case addShortcut
    case tabs
}

struct BrowserMenuSheet: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var library: UserscriptLibrary
    var isBookmarked: Bool
    var foundCount: Int
    var onAction: (BrowserMenuAction) -> Void

    @AppStorage(SettingsKey.uaMode) private var ua = UAMode.mobile.rawValue

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var isDark: Bool { scheme == .dark }
    private var desktop: Bool { UAMode(rawValue: ua) == .desktop }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    group {
                        row("书签", "book", detail: "\(BookmarkLibrary.shared.items.count)") { onAction(.bookmarks) }
                        row("历史记录", "clock", detail: "\(BrowserHistory.shared.items.count)") { onAction(.history) }
                        row("下载", "arrow.down.circle", detail: "\(DownloadManager.shared.items.count)") { onAction(.downloads) }
                    }

                    group {
                        row("嗅探结果", "dot.radiowaves.left.and.right",
                            detail: foundCount > 0 ? "\(foundCount) 个" : "暂无") { onAction(.sniff) }
                        row("油猴脚本", "curlybraces", detail: library.statusText) { onAction(.scripts) }
                    }

                    group {
                        row("在页面中查找", "magnifyingglass") { onAction(.find) }
                        toggleRow("桌面版网站", "desktopcomputer", isOn: desktop) {
                            ua = desktop ? UAMode.mobile.rawValue : UAMode.desktop.rawValue
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                store.current?.reload()
                            }
                        }
                    }

                    group {
                        row(isBookmarked ? "取消收藏" : "收藏本页",
                            isBookmarked ? "heart.fill" : "heart") { onAction(.bookmark) }
                        row("分享", "square.and.arrow.up") { onAction(.share) }
                        row("复制链接", "link") { onAction(.copyURL) }
                        row("添加到主页", "plus.app") { onAction(.addShortcut) }
                    }

                    group {
                        row("设置", "gearshape") { onAction(.settings) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 34)
            }
        }
        .background(FirefoxStyle.bg(isDark))
        .presentationDetents([.height(640), .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: 行

    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(FirefoxStyle.card(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(FirefoxStyle.line(isDark), lineWidth: 0.5)
        )
    }

    private func row(_ title: String, _ symbol: String, detail: String? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(FirefoxStyle.text(isDark).opacity(0.85))
                    .frame(width: 24)

                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(FirefoxStyle.text(isDark))

                Spacer(minLength: 6)

                if let detail = detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(FirefoxStyle.sub(isDark))
                        .lineLimit(1)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FirefoxStyle.sub(isDark).opacity(0.7))
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomLeading) {
            Rectangle()
                .fill(FirefoxStyle.line(isDark))
                .frame(height: 0.5)
                .padding(.leading, 50)
        }
    }

    private func toggleRow(_ title: String, _ symbol: String, isOn: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(FirefoxStyle.text(isDark).opacity(0.85))
                    .frame(width: 24)

                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(FirefoxStyle.text(isDark))

                Spacer(minLength: 6)

                Toggle("", isOn: .constant(isOn))
                    .labelsHidden()
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomLeading) {
            Rectangle()
                .fill(FirefoxStyle.line(isDark))
                .frame(height: 0.5)
                .padding(.leading, 50)
        }
    }
}

// MARK: - 悬浮嗅探球（可任意拖动）

struct FloatingSniffButton: View {
    var count: Int
    var onTap: () -> Void

    @AppStorage(SettingsKey.fabX) private var storedX = -1.0
    @AppStorage(SettingsKey.fabY) private var storedY = -1.0

    @State private var dragOffset: CGSize = .zero
    @State private var dragging = false
    @State private var suppressTap = false

    private let diameter: CGFloat = 56

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let edge = diameter / 2 + 8
            let maxX = max(edge, size.width - edge)
            let maxY = max(edge, size.height - edge)
            let bx = clamp((storedX < 0 ? 0.86 : storedX) * size.width, edge, maxX)
            let by = clamp((storedY < 0 ? 0.72 : storedY) * size.height, edge, maxY)

            knob
                .scaleEffect(dragging ? 1.1 : 1)
                .shadow(color: Color.black.opacity(dragging ? 0.45 : 0.3), radius: dragging ? 14 : 9, y: 4)
                .position(
                    x: clamp(bx + dragOffset.width, edge, maxX),
                    y: clamp(by + dragOffset.height, edge, maxY)
                )
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { value in
                            if !dragging {
                                dragging = true
                                suppressTap = true
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            dragOffset = value.translation
                        }
                        .onEnded { _ in
                            let nx = clamp(bx + dragOffset.width, edge, maxX)
                            let ny = clamp(by + dragOffset.height, edge, maxY)
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                storedX = Double(nx / max(size.width, 1))
                                storedY = Double(ny / max(size.height, 1))
                                dragOffset = .zero
                            }
                            dragging = false
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                suppressTap = false
                            }
                        }
                )
                .onTapGesture {
                    guard !suppressTap else { return }
                    onTap()
                }
        }
    }

    private var knob: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 1.0, green: 0.47, blue: 0.34),
                                 Color(red: 0.91, green: 0.23, blue: 0.33)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                )

            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if count > 0 {
                Text("\(min(count, 99))")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(red: 0.13, green: 0.13, blue: 0.16)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
                    .offset(x: 3, y: -3)
            }
        }
        .frame(width: diameter, height: diameter)
        .opacity(count > 0 ? 1 : (dragging ? 0.95 : 0.72))
        .contentShape(Circle())
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), high)
    }
}

// MARK: - 嗅探结果

struct SniffResultsPanel: View {
    @ObservedObject var tab: BrowserTab
    var onPlay: (SniffedVideo) -> Void
    var onAddToPlaylist: (SniffedVideo) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if tab.found.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("还没有抓到视频")
                            .font(.system(size: 15, weight: .semibold))
                        Text("播放一下页面里的视频，地址就会被捕获。\n很多站点把源藏在混淆脚本里，可以试试切到桌面版 UA。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(tab.found) { video in
                                Button {
                                    onPlay(video)
                                } label: {
                                    row(video)
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        UIPasteboard.general.string = video.url
                                    } label: {
                                        Label("复制", systemImage: "doc.on.doc")
                                    }
                                    .tint(.gray)

                                    Button {
                                        onAddToPlaylist(video)
                                    } label: {
                                        Label("加入列表", systemImage: "text.badge.plus")
                                    }
                                    .tint(.blue)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        tab.found.removeAll { $0.url == video.url }
                                    } label: {
                                        Label("移除", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            Text("共 \(tab.found.count) 个，点一下直接播放")
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("嗅探结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("清空") { tab.found.removeAll() }
                        .disabled(tab.found.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ video: SniffedVideo) -> some View {
        HStack(spacing: 10) {
            Text(video.kind)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color(red: 1.0, green: 0.42, blue: 0.31).opacity(0.9)))

            VStack(alignment: .leading, spacing: 2) {
                Text(video.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(video.host)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Image(systemName: "play.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color(red: 1.0, green: 0.5, blue: 0.4))
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

// MARK: - 快捷方式编辑

struct ShortcutDraft: Identifiable {
    let id = UUID()
    var item: Shortcut?
    var prefillURL: String?
    var prefillTitle: String?
}

struct ShortcutEditor: View {
    let draft: ShortcutDraft

    @State private var title = ""
    @State private var url = ""
    @State private var colorIndex = 0

    @Environment(\.dismiss) private var dismiss

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称（可以不填）", text: $title)
                    TextField("网址，例如 bilibili.com", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("网站")
                } footer: {
                    Text("不写 https:// 也可以。图标会自动取站点自己的 favicon。")
                }

                Section {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(0..<8, id: \.self) { index in
                            Button {
                                colorIndex = index
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(BrowserHomeView.color(index))
                                        .frame(width: 34, height: 34)
                                    if colorIndex == index {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("图标颜色")
                }
            }
            .navigationTitle(draft.item == nil ? "添加快捷方式" : "编辑快捷方式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(trimmedURL.isEmpty)
                }
            }
            .onAppear(perform: prefill)
        }
    }

    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func prefill() {
        if let item = draft.item {
            title = item.title
            url = item.url
            colorIndex = item.colorIndex
            return
        }
        url = draft.prefillURL ?? ""
        title = draft.prefillTitle ?? ""
        colorIndex = abs(url.count * 3 + 1) % 8
    }

    private func save() {
        let clean = trimmedURL
        guard !clean.isEmpty else { return }

        if var item = draft.item {
            item.title = title
            item.url = clean
            item.colorIndex = colorIndex
            ShortcutLibrary.shared.update(item)
        } else {
            ShortcutLibrary.shared.add(title: title, url: clean, colorIndex: colorIndex)
        }
        dismiss()
    }
}

// MARK: - 系统分享

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
