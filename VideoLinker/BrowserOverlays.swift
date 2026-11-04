import SwiftUI
import UIKit
import Photos
import Combine

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
    case autoScroll
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
                        row("自动滚动收集", "arrow.down.to.line") { onAction(.autoScroll) }
                        toggleRow("桌面版网站", "desktopcomputer", isOn: desktop) {
                            ua = desktop ? UAMode.mobile.rawValue : UAMode.desktop.rawValue
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                store.current?.reload()
                            }
                        }
                        toggleRow("清爽模式", "sparkles", isOn: store.current?.cleanMode ?? false) {
                            store.current?.toggleCleanMode()
                            dismiss()
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
    /// 点击：打开嗅探结果页
    var onTap: () -> Void

    @AppStorage(SettingsKey.fabX) private var storedX = -1.0
    @AppStorage(SettingsKey.fabY) private var storedY = -1.0

    @State private var dragOffset: CGSize = .zero
    @State private var dragging = false
    @State private var suppressTap = false

    private let diameter: CGFloat = 50

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
                                Haptics.light()
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
                            Haptics.soft()
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
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if count > 0 {
                Text("\(min(count, 99))")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color(red: 0.13, green: 0.13, blue: 0.16)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
                    .offset(x: 2, y: -2)
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
    /// 时长 / 分辨率的探测结果，按地址缓存，翻列表不会重复问
    @ObservedObject private var probe = MediaProbeStore.shared
    @State private var hint: String?
    @State private var filter = "全部"
    @State private var selecting = false
    @State private var selected: Set<String> = []
    /// 视频还是图片；页面只有图片时自动切到图片
    @State private var mode: Mode = .video

    private enum Mode: Hashable {
        case video, image
    }

    private let filters = ["全部", "HLS", "MP4", "其他"]

    private var filtered: [SniffedVideo] {
        switch filter {
        case "HLS":
            return tab.found.filter { $0.kind == "HLS" }
        case "MP4":
            return tab.found.filter { $0.kind == "MP4" || $0.kind == "MOV" }
        case "其他":
            return tab.found.filter { $0.kind != "HLS" && $0.kind != "MP4" && $0.kind != "MOV" }
        default:
            return tab.found
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if tab.found.isEmpty && tab.images.isEmpty {
                    emptyView
                } else {
                    VStack(spacing: 0) {
                        if !tab.images.isEmpty {
                            modeBar
                        }
                        if mode == .image {
                            imageContent
                        } else {
                            content
                        }
                    }
                }
            }
            .navigationTitle("嗅探结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if selecting && mode == .video {
                        Button("取消") {
                            selecting = false
                            selected.removeAll()
                        }
                    } else {
                        Button("关闭") { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if mode == .image {
                        Button(selected.count == tab.images.count && !tab.images.isEmpty ? "取消全选" : "全选") {
                            if selected.count == tab.images.count && !tab.images.isEmpty {
                                selected.removeAll()
                            } else {
                                selected = Set(tab.images.map { $0.url })
                            }
                        }
                        .disabled(tab.images.isEmpty)
                    } else if selecting {
                        Button(selected.count == filtered.count && !filtered.isEmpty ? "取消全选" : "全选") {
                            if selected.count == filtered.count && !filtered.isEmpty {
                                selected.removeAll()
                            } else {
                                selected = Set(filtered.map { $0.url })
                            }
                        }
                    } else {
                        Menu {
                            Button {
                                selecting = true
                            } label: {
                                Label("多选", systemImage: "checkmark.circle")
                            }

                            Button(role: .destructive) {
                                tab.found.removeAll()
                                tab.images.removeAll()
                                selected.removeAll()
                            } label: {
                                Label("清空", systemImage: "trash")
                            }
                        } label: {
                            Text("操作")
                        }
                        .disabled(tab.found.isEmpty && tab.images.isEmpty)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if mode == .image {
                    imageBatchBar
                } else if selecting {
                    batchBar
                }
            }
            .onAppear {
                if tab.found.isEmpty && !tab.images.isEmpty {
                    mode = .image
                }
            }
            .onChange(of: tab.images.count) { _ in
                // 图片是边扫边来的，晚到也要自动切过去
                if tab.found.isEmpty && !tab.images.isEmpty {
                    mode = .image
                }
            }
            .onChange(of: mode) { _ in
                selected.removeAll()
                selecting = false
                if mode == .image {
                    filter = "全部"
                }
            }
        }
        .presentationDetents([.medium, .large])
        .overlay(alignment: .bottom) {
            if let hint = hint {
                Text(hint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .padding(.bottom, selecting ? 70 : 22)
                    .transition(.opacity)
            }
        }
    }

    // MARK: 主体

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("还没有抓到视频或图片")
                .font(.system(size: 15, weight: .semibold))
            Text("播放一下页面里的视频，地址就会被捕获。\n很多站点把源藏在混淆脚本里，可以试试切到桌面版 UA。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        VStack(spacing: 0) {
            chipBar

            List {
                Section {
                    ForEach(filtered) { video in
                        row(video)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    UIPasteboard.general.string = video.url
                                    showHint("链接已复制")
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
                                    selected.remove(video.url)
                                } label: {
                                    Label("移除", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text(selecting
                         ? "已选 \(selected.count) 个"
                         : "共 \(filtered.count) 个，点一下播放，右边可下载")
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: 图片

    private var modeBar: some View {
        Picker("", selection: $mode) {
            Text("视频 \(tab.found.count)").tag(Mode.video)
            Text("图片 \(tab.images.count)").tag(Mode.image)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var imageContent: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3),
                spacing: 4
            ) {
                ForEach(tab.images) { image in
                    Button {
                        if selected.contains(image.url) {
                            selected.remove(image.url)
                        } else {
                            selected.insert(image.url)
                        }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            RemoteImage(url: image.url)
                                .frame(maxWidth: .infinity)
                                .frame(height: 118)
                                .clipped()

                            Image(systemName: selected.contains(image.url)
                                  ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18))
                                .foregroundStyle(selected.contains(image.url)
                                                 ? Color(red: 1.0, green: 0.45, blue: 0.35)
                                                 : .white.opacity(0.85))
                                .background(Circle().fill(.black.opacity(0.25)).padding(1))
                                .padding(6)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(alignment: .bottomLeading) {
                            if !image.sizeText.isEmpty {
                                Text(image.sizeText)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.black.opacity(0.45)))
                                    .padding(5)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .overlay(alignment: .top) {
            if tab.images.isEmpty {
                VStack(spacing: 6) {
                    Text("这一页还没有抓到图片")
                        .font(.system(size: 13, weight: .medium))
                    Text("往下滑一滑让图片加载出来，再回来看")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)
            }
        }
    }

    private var imageBatchBar: some View {
        HStack(spacing: 10) {
            Button {
                saveSelectedImages()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                    Text(selected.isEmpty ? "全部保存到相册" : "保存 \(selected.count) 张")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(Capsule().fill(Color(red: 1.0, green: 0.42, blue: 0.31)))
            }
            .buttonStyle(.plain)
            .disabled(tab.images.isEmpty)

            Button {
                copySelectedImages()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                    Text("复制链接")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(selected.isEmpty ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(Capsule().fill(Color(.tertiarySystemFill)))
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func targetImages() -> [SniffedImage] {
        selected.isEmpty ? tab.images : tab.images.filter { selected.contains($0.url) }
    }

    private func saveSelectedImages() {
        let list = targetImages()
        guard !list.isEmpty else { return }
        let urls = list.map { $0.url }
        showHint("正在保存 \(urls.count) 张…")

        SniffImageSaver.save(urls) { ok, failed in
            if ok > 0 {
                showHint(failed > 0 ? "已保存 \(ok) 张，\(failed) 张失败" : "已保存 \(ok) 张到相册")
                selected.removeAll()
            } else {
                showHint("没能保存，可能是图片有防盗链或已过期")
            }
        }
    }

    private func copySelectedImages() {
        let list = targetImages()
        guard !list.isEmpty else { return }
        UIPasteboard.general.string = list.map { $0.url }.joined(separator: "\n")
        showHint("已复制 \(list.count) 条图片链接")
    }

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters, id: \.self) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { filter = item }
                    } label: {
                        HStack(spacing: 4) {
                            Text(item)
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(count(for: item))")
                                .font(.system(size: 10, weight: .semibold))
                                .opacity(0.75)
                        }
                        .foregroundStyle(filter == item ? .white : Color.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(filter == item
                                           ? Color(red: 1.0, green: 0.42, blue: 0.31)
                                           : Color(.secondarySystemBackground))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func count(for item: String) -> Int {
        switch item {
        case "HLS":
            return tab.found.filter { $0.kind == "HLS" }.count
        case "MP4":
            return tab.found.filter { $0.kind == "MP4" || $0.kind == "MOV" }.count
        case "其他":
            return tab.found.filter { $0.kind != "HLS" && $0.kind != "MP4" && $0.kind != "MOV" }.count
        default:
            return tab.found.count
        }
    }

    // MARK: 批量操作条

    private var batchBar: some View {
        HStack(spacing: 10) {
            batchButton("下载", symbol: "arrow.down.circle.fill") { batchDownload() }
            batchButton("加入列表", symbol: "text.badge.plus") { batchAdd() }
            batchButton("复制", symbol: "doc.on.doc") { batchCopy() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func batchButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(selected.isEmpty ? Color.secondary : Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(
                Capsule().fill(selected.isEmpty
                               ? Color(.tertiarySystemFill)
                               : Color(red: 1.0, green: 0.42, blue: 0.31))
            )
        }
        .buttonStyle(.plain)
        .disabled(selected.isEmpty)
    }

    private func selectedVideos() -> [SniffedVideo] {
        tab.found.filter { selected.contains($0.url) }
    }

    private func batchDownload() {
        let list = selectedVideos()
        guard !list.isEmpty else { return }

        var started = 0
        for video in list.prefix(20) {
            if case .started = DownloadManager.shared.start(
                from: video.url,
                title: video.displayName,
                alternates: alternates(for: video)
            ) {
                started += 1
            }
        }

        selecting = false
        selected.removeAll()
        showHint(started > 0
                 ? "已加入 \(started) 个下载任务，进度在首页「下载管理」里看"
                 : "这些地址都没能开始下载，可能已经过期")
    }

    private func batchAdd() {
        let list = selectedVideos()
        guard !list.isEmpty else { return }

        let target = PlaylistStore.downloadListID()
        for video in list {
            _ = PlaylistStore.add(
                PlaylistItem(url: video.url, title: video.displayName),
                to: target
            )
        }

        selecting = false
        selected.removeAll()
        showHint("已把 \(list.count) 条加入「下载」列表")
    }

    private func batchCopy() {
        let list = selectedVideos()
        guard !list.isEmpty else { return }

        UIPasteboard.general.string = list.map { $0.url }.joined(separator: "\n")
        selecting = false
        selected.removeAll()
        showHint("已复制 \(list.count) 条链接")
    }

    // MARK: 下载

    /// 和播放页共用同一个 DownloadManager：进度、记录、完成后自动进「下载」列表都是同一份
    private func download(_ video: SniffedVideo) {
        // m3u8 有多档清晰度时先让用户挑，普通直链直接开下
        if HLSDownloader.looksLikeHLS(video.url) {
            showHint("正在检查清晰度…")
            DownloadManager.shared.requestDownload(
                from: video.url,
                title: video.displayName,
                alternates: alternates(for: video)
            )
            return
        }

        switch DownloadManager.shared.start(
            from: video.url,
            title: video.displayName,
            alternates: alternates(for: video)
        ) {
        case .started(let item):
            showHint("已开始下载：\(item.fileName)")
        case .failed(let reason):
            showHint(reason)
        }
    }

    /// 同一页面里标题相同的候选通常是同一部片的不同清晰度，失败时可以互相顶替
    private func alternates(for video: SniffedVideo) -> [String] {
        guard !video.displayName.isEmpty else { return [] }
        return tab.found
            .filter { $0.url != video.url && $0.displayName == video.displayName }
            .map { $0.url }
    }

    private func showHint(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { hint = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if hint == text {
                withAnimation(.easeIn(duration: 0.2)) { hint = nil }
            }
        }
    }

    private func row(_ video: SniffedVideo) -> some View {
        HStack(spacing: 8) {
            if selecting {
                Image(systemName: selected.contains(video.url) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(selected.contains(video.url)
                                     ? Color(red: 1.0, green: 0.42, blue: 0.31)
                                     : Color.secondary)
            }

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
                Text(detailText(video))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if !selecting {
                Button {
                    download(video)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(Color(red: 1.0, green: 0.5, blue: 0.4))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    onPlay(video)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(red: 1.0, green: 0.5, blue: 0.4))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting {
                if selected.contains(video.url) {
                    selected.remove(video.url)
                } else {
                    selected.insert(video.url)
                }
            } else {
                onPlay(video)
            }
        }
        .task(id: video.url) {
            probe.request(video.url)
        }
    }

    /// 第二行：域名 + 时长 + 分辨率，后两项探到才有
    private func detailText(_ video: SniffedVideo) -> String {
        guard let summary = probe.info(for: video.url)?.summary, !summary.isEmpty else {
            return video.host
        }
        return video.host + " · " + summary
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

// MARK: - 图片缩略图 / 保存
//
// 图集站的图片大多有防盗链，直接用 AsyncImage 会一片空白，
// 这里走 URLSession 并套上请求头规则，和播放 / 下载用同一套 Referer。

final class HeaderImageLoader: ObservableObject {
    @Published var image: UIImage?

    private static let cache = NSCache<NSString, UIImage>()
    private var loading = false

    func load(_ urlString: String) {
        guard image == nil, !loading else { return }
        if let hit = Self.cache.object(forKey: urlString as NSString) {
            image = hit
            return
        }
        guard let url = URL(string: urlString) else { return }
        loading = true

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        HTTPHeaderStore.apply(to: &request, url: url)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            defer { self?.loading = false }
            guard let data, let image = UIImage(data: data) else { return }
            Self.cache.setObject(image, forKey: urlString as NSString)
            DispatchQueue.main.async { self?.image = image }
        }.resume()
    }
}

struct RemoteImage: View {
    let url: String

    @StateObject private var loader = HeaderImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color(.tertiarySystemFill))
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .task(id: url) { loader.load(url) }
    }
}

enum SniffImageSaver {
    /// 返回（成功数, 失败数）
    static func save(_ urls: [String], completion: @escaping (Int, Int) -> Void) {
        guard !urls.isEmpty else {
            completion(0, 0)
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(0, urls.count) }
                return
            }

            let group = DispatchGroup()
            let lock = NSLock()
            let limit = DispatchSemaphore(value: 3)
            var ok = 0
            var failed = 0

            for url in urls {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    limit.wait()
                    defer {
                        limit.signal()
                        group.leave()
                    }

                    guard let data = fetch(url), let image = UIImage(data: data) else {
                        lock.lock(); failed += 1; lock.unlock()
                        return
                    }
                    if saveOne(image) {
                        lock.lock(); ok += 1; lock.unlock()
                    } else {
                        lock.lock(); failed += 1; lock.unlock()
                    }
                }
            }

            group.notify(queue: .main) { completion(ok, failed) }
        }
    }

    private static func fetch(_ urlString: String) -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        HTTPHeaderStore.apply(to: &request, url: url)

        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 25)
        return result
    }

    private static func saveOne(_ image: UIImage) -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.95) ?? image.pngData() else {
            return false
        }
        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }) { done, _ in
            success = done
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 20)
        return success
    }
}
