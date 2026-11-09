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
    case scriptMenu
    case sniff
    case find
    case settings
    case bookmark
    case memo
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
                        if !library.scripts.isEmpty {
                            row("脚本菜单", "list.bullet.rectangle", detail: "当前页") { onAction(.scriptMenu) }
                        }
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
                        row("存到备忘录", "note.text") { onAction(.memo) }
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

// MARK: - 脚本菜单（GM_registerMenuCommand 注册的命令）

struct ScriptMenuItem: Identifiable, Equatable {
    let id: String
    let title: String
    let script: String

    /// 解析页面里 __vlMenuList() 返回的 JSON
    static func parse(_ json: String) -> [ScriptMenuItem] {
        guard let data = json.data(using: .utf8),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { item in
            guard let key = item["key"] as? String, !key.isEmpty else { return nil }
            let title = (item["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let script = (item["script"] as? String) ?? ""
            return ScriptMenuItem(id: key,
                                  title: title.isEmpty ? "（未命名菜单）" : title,
                                  script: script)
        }
    }
}

struct ScriptMenuSheet: View {
    let items: [ScriptMenuItem]
    /// 当前已启用的脚本数量，空了能帮用户判断是脚本没跑还是没注册
    var enabledCount: Int = 0
    var onRun: (ScriptMenuItem) -> Void
    var onReload: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var isDark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(FirefoxStyle.line(isDark))
                .frame(height: 0.5)

            if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(groups) { group in
                            section(group)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                }
            }
        }
        .background(FirefoxStyle.bg(isDark).ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("脚本菜单")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(FirefoxStyle.text(isDark))

            if !items.isEmpty {
                Text("\(items.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FirefoxStyle.sub(isDark))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(FirefoxStyle.field(isDark)))
            }

            Spacer(minLength: 6)

            Button {
                onReload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(FirefoxStyle.accent)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FirefoxStyle.sub(isDark))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(FirefoxStyle.field(isDark)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(FirefoxStyle.sub(isDark))

            Text("这个页面没有脚本菜单")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FirefoxStyle.text(isDark))

            Text("只有脚本用 GM_registerMenuCommand 注册过命令，\n才会出现在这里。确认脚本已开启、页面已刷新。")
                .font(.system(size: 12))
                .foregroundStyle(FirefoxStyle.sub(isDark))
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Text(enabledCount > 0
                 ? "当前已启用 \(enabledCount) 个脚本"
                 : "当前没有启用的脚本，先去「油猴脚本」打开开关")
                .font(.system(size: 11))
                .foregroundStyle(enabledCount > 0 ? FirefoxStyle.sub(isDark) : FirefoxStyle.accent)
                .padding(.top, 2)

            Button {
                onReload()
            } label: {
                Text("重新获取")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(FirefoxStyle.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
    }

    private func section(_ group: Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.script)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FirefoxStyle.sub(isDark))
                .padding(.leading, 4)
                .lineLimit(1)

            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        onRun(item)
                    } label: {
                        HStack(spacing: 10) {
                            Text(item.title)
                                .font(.system(size: 15))
                                .foregroundStyle(FirefoxStyle.text(isDark))
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 6)
                            Image(systemName: "play.circle")
                                .font(.system(size: 17))
                                .foregroundStyle(FirefoxStyle.accent)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 46)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < group.items.count - 1 {
                        Rectangle()
                            .fill(FirefoxStyle.line(isDark))
                            .frame(height: 0.5)
                            .padding(.leading, 14)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(FirefoxStyle.card(isDark))
            )
        }
    }

    private struct Group: Identifiable {
        let script: String
        let items: [ScriptMenuItem]
        var id: String { script }
    }

    private var groups: [Group] {
        var order: [String] = []
        var map: [String: [ScriptMenuItem]] = [:]
        for item in items {
            let key = item.script.isEmpty ? "未命名脚本" : item.script
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(item)
        }
        return order.map { Group(script: $0, items: map[$0] ?? []) }
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
    /// 下载前的清晰度选择
    @State private var qualityChoice: DownloadManager.QualityChoice?
    @State private var showQuality = false
    /// 合并后的多清晰度组，点「N 档」时选
    @State private var groupChoice: SniffGroup?
    @State private var showGroupChoice = false
    /// 图片全屏预览
    @State private var previewIndex = 0
    @State private var showPreview = false

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

    /// 同一部片的多清晰度收成一组；已知只有几十秒的广告 / 预告挪到最后
    private var groups: [SniffGroup] {
        let built = SniffGroup.build(from: filtered)
        return built.enumerated().sorted { a, b in
            let da = probe.info(for: a.element.primary.url)?.duration ?? .greatestFiniteMagnitude
            let db = probe.info(for: b.element.primary.url)?.duration ?? .greatestFiniteMagnitude
            if (da < 25) != (db < 25) { return db < 25 }
            return a.offset < b.offset
        }.map { $0.element }
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
        .fullScreenCover(isPresented: $showPreview) {
            ImagePreviewView(images: tab.images, startIndex: previewIndex)
        }
        .presentationDetents([.medium, .large])
        .confirmationDialog("选择清晰度", isPresented: $showQuality, titleVisibility: .visible) {
            if let choice = qualityChoice {
                ForEach(choice.variants) { variant in
                    Button("\(variant.shortTitle) · \(variant.detail)") {
                        _ = DownloadManager.shared.start(choice, variant: variant)
                    }
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("下载的是 \(qualityChoice?.title ?? "这个视频")，挑一档占地方合适的")
        }
        .confirmationDialog("选择清晰度", isPresented: $showGroupChoice, titleVisibility: .visible) {
            if let group = groupChoice {
                ForEach(group.sorted) { video in
                    Button(qualityLabel(video)) {
                        download(video)
                    }
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text(groupChoice?.primary.displayName ?? "")
        }
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
                    if selecting {
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
                    } else {
                        ForEach(groups) { group in
                            groupRow(group)
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        UIPasteboard.general.string = group.videos.map(\.url).joined(separator: "\n")
                                        showHint(group.isMerged ? "已复制 \(group.videos.count) 条链接" : "链接已复制")
                                    } label: {
                                        Label(group.isMerged ? "复制全部" : "复制", systemImage: "doc.on.doc")
                                    }
                                    .tint(.gray)

                                    Button {
                                        onAddToPlaylist(group.best)
                                    } label: {
                                        Label("加入列表", systemImage: "text.badge.plus")
                                    }
                                    .tint(.blue)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        let urls = Set(group.videos.map(\.url))
                                        tab.found.removeAll { urls.contains($0.url) }
                                        selected.subtract(urls)
                                    } label: {
                                        Label("移除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                } header: {
                    Text(headerText)
                }
            }
            .listStyle(.plain)
        }
    }

    private var headerText: String {
        if selecting { return "已选 \(selected.count) 个" }
        if groups.count < filtered.count {
            return "共 \(filtered.count) 个，合并为 \(groups.count) 组，点一下播放"
        }
        return "共 \(filtered.count) 个，点一下播放，右边可下载"
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
            VStack(spacing: 8) {
                Text("点图片全屏放大，点右上角圆圈多选")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3),
                    spacing: 4
                ) {
                    ForEach(Array(tab.images.enumerated()), id: \.element.id) { index, image in
                        ZStack(alignment: .topTrailing) {
                            Button {
                                // 已经在多选状态时，点图继续加选，避免误触放大
                                if selected.isEmpty {
                                    previewIndex = index
                                    showPreview = true
                                } else {
                                    toggleImage(image.url)
                                }
                            } label: {
                                RemoteImage(url: image.url)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 118)
                                    .clipped()
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

                            Button {
                                toggleImage(image.url)
                            } label: {
                                Image(systemName: selected.contains(image.url)
                                      ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 18))
                                    .foregroundStyle(selected.contains(image.url)
                                                     ? Color(red: 1.0, green: 0.45, blue: 0.35)
                                                     : .white.opacity(0.85))
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
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

    private func toggleImage(_ url: String) {
        if selected.contains(url) {
            selected.remove(url)
        } else {
            selected.insert(url)
        }
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
            ) { choice in
                qualityChoice = choice
                showQuality = true
            }
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

    @ViewBuilder
    private func groupRow(_ group: SniffGroup) -> some View {
        if group.isMerged {
            mergedRow(group)
        } else {
            row(group.primary)
        }
    }

    /// 合并后的一行：一条片子只占一行，右边标出有几档，点开再挑
    private func mergedRow(_ group: SniffGroup) -> some View {
        HStack(spacing: 8) {
            Text(group.primary.kind)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color(red: 1.0, green: 0.42, blue: 0.31).opacity(0.9)))

            VStack(alignment: .leading, spacing: 2) {
                Text(group.primary.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(group.primary.host) · \(group.videos.count) 个清晰度")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Button {
                groupChoice = group
                showGroupChoice = true
            } label: {
                Text("\(group.videos.count) 档")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.5, blue: 0.4))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color(red: 1.0, green: 0.5, blue: 0.4).opacity(0.12)))
            }
            .buttonStyle(.plain)

            Button {
                download(group.best)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Color(red: 1.0, green: 0.5, blue: 0.4))
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                onPlay(group.best)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color(red: 1.0, green: 0.5, blue: 0.4))
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { onPlay(group.best) }
        .task(id: group.key) {
            for video in group.videos.prefix(4) {
                probe.request(video.url)
            }
        }
    }

    private func qualityLabel(_ video: SniffedVideo) -> String {
        var parts: [String] = []
        if let summary = probe.info(for: video.url)?.summary, !summary.isEmpty {
            parts.append(summary)
        } else {
            let token = qualityToken(video.url)
            if !token.isEmpty { parts.append(token) }
        }
        parts.append(video.kind)
        return parts.joined(separator: " · ")
    }

    private func qualityToken(_ url: String) -> String {
        let lower = url.lowercased()
        for token in ["2160p", "4k", "1440p", "1080p", "720p", "480p", "360p", "240p"] {
            if lower.contains(token) { return token.uppercased() }
        }
        return ""
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

    static let cache = NSCache<NSString, UIImage>()
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

    /// 预览页用：先看缓存，没有就按同一套请求头下载原图
    static func cached(_ urlString: String) -> UIImage? {
        cache.object(forKey: urlString as NSString)
    }

    static func fetch(_ urlString: String, completion: @escaping (UIImage?) -> Void) {
        if let hit = cached(urlString) {
            completion(hit)
            return
        }
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        HTTPHeaderStore.apply(to: &request, url: url)

        URLSession.shared.dataTask(with: request) { data, _, _ in
            let image = data.flatMap { UIImage(data: $0) }
            if let image {
                cache.setObject(image, forKey: urlString as NSString)
            }
            DispatchQueue.main.async { completion(image) }
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

// MARK: - 图片全屏预览

struct ImagePreviewView: View {
    let images: [SniffedImage]
    @State private var index: Int
    @State private var toast: String?
    @State private var saving = false

    @Environment(\.dismiss) private var dismiss

    init(images: [SniffedImage], startIndex: Int) {
        self.images = images
        let safe = images.isEmpty ? 0 : max(0, min(startIndex, images.count - 1))
        _index = State(initialValue: safe)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if images.isEmpty {
                Text("图片已经不在了")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                TabView(selection: $index) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { position, item in
                        ZoomingImage(url: item.url)
                            .tag(position)
                            .ignoresSafeArea()
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }

            chrome
        }
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .padding(.bottom, 108)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: toast)
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.white.opacity(0.18)))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                HStack(spacing: 10) {
                    Button {
                        step(-1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(index > 0 ? 0.9 : 0.28))
                            .frame(width: 22, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(index <= 0)

                    Text("\(index + 1) / \(images.count)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .monospacedDigit()

                    Button {
                        step(1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(index + 1 < images.count ? 0.9 : 0.28))
                            .frame(width: 22, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(index + 1 >= images.count)
                }

                Spacer(minLength: 4)

                Button {
                    saveCurrent()
                } label: {
                    Group {
                        if saving {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .disabled(saving || images.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 12)
            .background(
                LinearGradient(colors: [.black.opacity(0.62), .black.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
            )

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Text(sizeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))

                Spacer(minLength: 6)

                Text("双击放大 · 双指缩放")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))

                Button {
                    copyCurrent()
                } label: {
                    Label("复制链接", systemImage: "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 24)
            .background(
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.6)],
                               startPoint: .top, endPoint: .bottom)
            )
        }
    }

    private var sizeText: String {
        guard index >= 0, index < images.count else { return "" }
        let text = images[index].sizeText
        return text.isEmpty ? "" : text
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard next >= 0, next < images.count else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            index = next
        }
    }

    private func saveCurrent() {
        guard !saving, index >= 0, index < images.count else { return }
        let item = images[index]
        saving = true
        toast = "正在保存…"

        SniffImageSaver.save([item.url]) { ok, _ in
            saving = false
            toast = ok > 0 ? "已保存到相册" : "保存失败，可能有防盗链或链接已过期"
            clearToast(after: 2.0)
        }
    }

    private func copyCurrent() {
        guard index >= 0, index < images.count else { return }
        UIPasteboard.general.string = images[index].url
        toast = "链接已复制"
        clearToast(after: 1.6)
    }

    private func clearToast(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            toast = nil
        }
    }
}

/// 单张可缩放图：外包 UIScrollView，支持双指缩放、双击放大
private struct ZoomingImage: UIViewRepresentable {
    let url: String

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.load(url)
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        view.load(url)
    }
}

private final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let failLabel = UILabel()
    private var currentURL: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        addSubview(imageView)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        addSubview(spinner)

        failLabel.text = "图片加载失败"
        failLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        failLabel.font = .systemFont(ofSize: 13)
        failLabel.textAlignment = .center
        failLabel.isHidden = true
        addSubview(failLabel)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(_ urlString: String) {
        guard currentURL != urlString else { return }
        currentURL = urlString
        setZoomScale(1, animated: false)
        failLabel.isHidden = true

        if let hit = HeaderImageLoader.cached(urlString) {
            apply(hit)
            return
        }

        imageView.image = nil
        spinner.startAnimating()
        HeaderImageLoader.fetch(urlString) { [weak self] image in
            guard let self, self.currentURL == urlString else { return }
            if let image {
                self.apply(image)
            } else {
                self.spinner.stopAnimating()
                self.failLabel.isHidden = false
            }
        }
    }

    private func apply(_ image: UIImage) {
        spinner.stopAnimating()
        failLabel.isHidden = true
        imageView.image = image
        setZoomScale(1, animated: false)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        failLabel.frame = CGRect(x: 20, y: bounds.midY + 26, width: max(bounds.width - 40, 0), height: 20)

        if zoomScale <= 1.001 {
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // 放大后图片小于屏幕时保持居中
        let offsetX = max((bounds.width - contentSize.width) / 2, 0)
        let offsetY = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: offsetY, left: offsetX, bottom: offsetY, right: offsetX)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 1 倍时把手势让给外层分页，放大后才允许在图片上拖动
        if gestureRecognizer === panGestureRecognizer && zoomScale <= 1.001 {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.001 {
            setZoomScale(1, animated: true)
            return
        }

        let point = gesture.location(in: imageView)
        let width = bounds.width / 2.5
        let height = bounds.height / 2.5
        zoom(to: CGRect(x: point.x - width / 2,
                        y: point.y - height / 2,
                        width: width,
                        height: height),
             animated: true)
    }
}
