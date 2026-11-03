import SwiftUI
import WebKit
import UIKit

// MARK: - 历史记录

struct BrowserHistoryView: View {
    var onOpen: (String) -> Void

    @ObservedObject private var history = BrowserHistory.shared
    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""
    @State private var confirmClear = false

    private var filtered: [WebVisit] {
        let text = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return history.items }
        return history.items.filter {
            $0.title.localizedCaseInsensitiveContains(text) || $0.url.localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(groups(), id: \.0) { group in
                            Section {
                                ForEach(group.1) { visit in
                                    Button {
                                        onOpen(visit.url)
                                        dismiss()
                                    } label: {
                                        row(visit)
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            history.remove(visit)
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                                }
                            } header: {
                                Text(group.0)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("历史")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $keyword, prompt: "搜索历史")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("清空") { confirmClear = true }
                        .disabled(history.isEmpty)
                }
            }
            .confirmationDialog("清空全部历史记录？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) { history.clear() }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(keyword.isEmpty ? "还没有浏览记录" : "没有找到相关记录")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ visit: WebVisit) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(visit.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(visit.host)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(visit.date, format: .dateTime.hour().minute())
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func groups() -> [(String, [WebVisit])] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"

        let calendar = Calendar.current
        var buckets: [(String, [WebVisit])] = []
        var index: [String: Int] = [:]

        for visit in filtered {
            var key: String
            if calendar.isDateInToday(visit.date) {
                key = "今天"
            } else if calendar.isDateInYesterday(visit.date) {
                key = "昨天"
            } else {
                key = formatter.string(from: visit.date)
            }
            if let position = index[key] {
                buckets[position].1.append(visit)
            } else {
                index[key] = buckets.count
                buckets.append((key, [visit]))
            }
        }
        return buckets
    }
}

// MARK: - 书签

struct BookmarksView: View {
    var onOpen: (String) -> Void

    @ObservedObject private var library = BookmarkLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""
    @State private var editing: Bookmark?
    @State private var editingTitle = ""

    private var filtered: [Bookmark] {
        let text = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return library.items }
        return library.items.filter {
            $0.title.localizedCaseInsensitiveContains(text) || $0.url.localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "heart")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.secondary)
                        Text(keyword.isEmpty ? "还没有收藏的网页" : "没有找到相关收藏")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                        if keyword.isEmpty {
                            Text("浏览网页时点底部「⋯」→「收藏」")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filtered) { item in
                            Button {
                                onOpen(item.url)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.accentColor.opacity(0.16))
                                            .frame(width: 30, height: 30)
                                        Text(item.initial)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Color.accentColor)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.displayTitle)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(item.host)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    library.remove(item)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button {
                                    editing = item
                                    editingTitle = item.title
                                } label: {
                                    Label("重命名", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    library.remove(item)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("收藏")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $keyword, prompt: "搜索收藏")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("清空") { library.clear() }
                        .disabled(library.items.isEmpty)
                }
            }
            .alert("重命名", isPresented: Binding(
                get: { editing != nil },
                set: { if !$0 { editing = nil } }
            )) {
                TextField("标题", text: $editingTitle)
                Button("取消", role: .cancel) { editing = nil }
                Button("保存") {
                    if let item = editing {
                        library.add(title: editingTitle, url: item.url)
                    }
                    editing = nil
                }
            }
        }
    }
}

// MARK: - 下载

struct DownloadsView: View {
    var onPlay: (URL) -> Void

    @ObservedObject private var manager = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var shareBox: ShareBox?
    @State private var converting = false
    @State private var showInbox = false
    @State private var toast: String?
    @State private var editMode: EditMode = .inactive
    @State private var altItem: DownloadItem?

    var body: some View {
        NavigationStack {
            Group {
                if manager.items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("还没有下载")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("网页里的安装包、压缩包会自动进这里，首页和播放页也能直接下视频")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(manager.items) { item in
                            DownloadRow(item: item) {
                                if let url = item.fileURL {
                                    open(url)
                                } else if item.isHLS {
                                    playWhileDownloading(item)
                                }
                            }
                            .contextMenu { menu(for: item) }
                            .swipeActions(edge: .leading) {
                                if item.state == .finished, let url = item.fileURL {
                                    Button {
                                        MediaExporter.exportToFiles([url])
                                    } label: {
                                        Label("导出", systemImage: "folder")
                                    }
                                    .tint(.blue)

                                    Button {
                                        MediaExporter.saveToPhotos(url) { message in
                                            showToast(message)
                                        }
                                    } label: {
                                        Label("存相册", systemImage: "photo")
                                    }
                                    .tint(.green)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    manager.remove(item)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                        .onMove { source, destination in
                            manager.moveQueued(from: source, to: destination)
                        }
                    }
                    .listStyle(.plain)
                    .environment(\.editMode, $editMode)
                }
            }
            .navigationTitle("下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showInbox = true
                        } label: {
                            Label("从电脑传文件", systemImage: "antenna.radiowaves.left.and.right")
                        }

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                editMode = editMode == .active ? .inactive : .active
                            }
                        } label: {
                            Label(editMode == .active ? "完成排序" : "调整顺序", systemImage: "arrow.up.arrow.down")
                        }
                        .disabled(manager.items.isEmpty)

                        Divider()

                        Button {
                            manager.pauseAll()
                        } label: {
                            Label("全部暂停", systemImage: "pause.circle")
                        }
                        .disabled(manager.items.isEmpty)

                        Button {
                            manager.resumeAll()
                        } label: {
                            Label("全部继续", systemImage: "play.circle")
                        }
                        .disabled(manager.items.isEmpty)

                        Divider()

                        Button(role: .destructive) {
                            manager.clearFinished()
                        } label: {
                            Label("清理已结束", systemImage: "trash")
                        }
                        .disabled(manager.items.isEmpty)
                    } label: {
                        Text("管理")
                    }
                }
            }
            .sheet(item: $shareBox) { box in
                ActivityView(items: [box.url])
            }
            .sheet(isPresented: $showInbox) {
                LANInboxView()
            }
            .sheet(item: $altItem) { item in
                AltSourceSheet(item: item)
            }
            .overlay(alignment: .bottom) {
                if let toast = toast {
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.black.opacity(0.78)))
                        .padding(.bottom, 24)
                }
            }
            .overlay {
                if converting {
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        HStack(spacing: 10) {
                            ProgressView().tint(.white)
                            Text("正在合并为 MP4…")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for item: DownloadItem) -> some View {
        if item.state.isUnfinished {
            Button {
                manager.togglePin(item)
            } label: {
                Label(item.isPinned ? "取消置顶" : "置顶优先下载",
                      systemImage: item.isPinned ? "pin.slash" : "pin")
            }
        }

        if let url = item.fileURL {
            Button {
                MediaExporter.exportToFiles([url])
            } label: {
                Label("导出到「文件」", systemImage: "folder")
            }

            Button {
                MediaExporter.saveToPhotos(url) { message in
                    showToast(message)
                }
            } label: {
                Label("存到相册", systemImage: "photo")
            }

            Button {
                shareBox = ShareBox(url: url)
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
            }
        }

        if !item.source.isEmpty {
            Button {
                UIPasteboard.general.string = item.source
                showToast("下载地址已复制")
            } label: {
                Label("复制下载地址", systemImage: "link")
            }
        }

        if item.isHLS, item.state != .finished {
            Button {
                playWhileDownloading(item)
            } label: {
                Label("边下边看", systemImage: "play.rectangle.on.rectangle")
            }
        }

        if item.state == .paused {
            Button {
                manager.resume(item)
            } label: {
                Label("继续下载", systemImage: "play.circle")
            }
        }

        if item.state == .failed {
            Button {
                manager.retry(item)
            } label: {
                Label(item.hasNextSource ? "换源重试" : "重试", systemImage: "arrow.clockwise")
            }
        }

        if item.state != .finished {
            Button {
                altItem = item
            } label: {
                Label("备用下载地址…", systemImage: "arrow.triangle.branch")
            }
        }

        Button(role: .destructive) {
            manager.remove(item)
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    /// 下载中的 HLS：起本地中转，把已下好的分片先播起来，后面由下载器继续补
    private func playWhileDownloading(_ item: DownloadItem) {
        HLSRelay.shared.prepare(item: item) { url in
            DispatchQueue.main.async {
                guard let url else {
                    showToast("这个任务还没解析出分片清单，等下载开始后再试")
                    return
                }
                onPlay(url)
            }
        }
    }

    private func open(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let videoExts = ["mp4", "m4v", "mov", "mkv", "flv", "webm", "ts", "avi", "mp3", "m4a", "aac", "wav", "flac"]

        // 之前下到的 .ts 直接放会失败，播放前先换成 MP4
        if ext == "ts" {
            converting = true
            Task {
                let converted = try? await MediaRemuxer.remuxToMP4(url)
                await MainActor.run {
                    converting = false
                    if let converted = converted,
                       let item = manager.items.first(where: { $0.localPath == url.path }) {
                        manager.replacePath(of: item, with: converted)
                    }
                    onPlay(converted ?? url)
                    dismiss()
                }
            }
            return
        }

        if videoExts.contains(ext) {
            onPlay(url)
            dismiss()
        } else {
            shareBox = ShareBox(url: url)
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if toast == text {
                withAnimation(.easeIn(duration: 0.2)) { toast = nil }
            }
        }
    }
}

struct ShareBox: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    var onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // 内容区单独做成按钮：整行不再挂 onTapGesture，
            // 否则右边那颗暂停/继续按钮的点击会被行手势抢走
            Button {
                guard item.state == .finished else { return }
                onTap()
            } label: {
                HStack(spacing: 10) {
                    leading

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            if item.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.orange)
                            }
                            Text(item.fileName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }

                        statusLine
                    }

                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            actionButton
        }
        .padding(.vertical, 5)
    }

    // MARK: 左侧

    @ViewBuilder
    private var leading: some View {
        if item.state == .finished, isVideoFile {
            VideoThumbnail(path: item.localPath, width: 54, height: 34, corner: 6)
        } else {
            Image(systemName: iconName)
                .font(.system(size: 16))
                .foregroundStyle(iconColor)
                .frame(width: 30)
        }
    }

    private var isVideoFile: Bool {
        guard !item.localPath.isEmpty else { return false }
        let ext = (item.localPath as NSString).pathExtension.lowercased()
        let list = ["mp4", "m4v", "mov", "mkv", "webm", "flv", "ts", "avi", "wmv",
                    "rmvb", "mp3", "m4a", "aac", "wav", "flac"]
        return list.contains(ext)
    }

    // MARK: 状态行

    @ViewBuilder
    private var statusLine: some View {
        if item.state == .running || item.state == .queued {
            ProgressView(value: item.state == .queued ? 0 : min(max(item.progress, 0), 1))
                .progressViewStyle(.linear)
                .tint(.accentColor)

            Text(item.state == .queued ? "排队中" : runningDetail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if item.state == .paused {
            Text(item.progress > 0
                 ? "已暂停 · \(Int(item.progress * 100))%，点右边的按钮接着下"
                 : "已暂停")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else if item.state == .failed {
            Text(failureText)
                .font(.system(size: 10))
                .foregroundStyle(.red.opacity(0.85))
                .lineLimit(2)
        } else if !item.note.isEmpty {
            Text(item.note)
                .font(.system(size: 10))
                .foregroundStyle(.orange.opacity(0.9))
                .lineLimit(2)
        } else {
            Text(item.sizeText.isEmpty ? "已完成" : item.sizeText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    /// 下载中那行：「2.4 MB/s · 34% · 12.1 MB / 40 MB」
    private var runningDetail: String {
        var parts: [String] = []
        if !item.speedText.isEmpty { parts.append(item.speedText) }

        if !item.note.isEmpty {
            parts.append(item.note)
        } else {
            parts.append("\(Int(item.progress * 100))%")
            if !item.transferText.isEmpty { parts.append(item.transferText) }
        }

        if !item.sourceCountText.isEmpty { parts.append(item.sourceCountText) }

        return parts.joined(separator: " · ")
    }

    private var failureText: String {
        let reason = item.failReason.isEmpty ? "下载失败" : item.failReason
        guard !item.sourceCountText.isEmpty else { return reason }
        return "\(item.sourceCountText) · \(reason)"
    }

    // MARK: 右侧按钮

    @ViewBuilder
    private var actionButton: some View {
        switch item.state {
        case .running, .queued:
            Button {
                DownloadManager.shared.pause(item)
            } label: {
                actionIcon("pause.circle")
            }
        case .paused:
            Button {
                DownloadManager.shared.resume(item)
            } label: {
                actionIcon("play.circle.fill")
            }
        case .failed:
            Button {
                DownloadManager.shared.retry(item)
            } label: {
                actionIcon("arrow.clockwise.circle.fill")
            }
        case .finished:
            EmptyView()
        }
    }

    private func actionIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 21))
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private var iconName: String {
        switch item.state {
        case .queued: return "clock"
        case .running: return "arrow.down.circle"
        case .paused: return "pause.circle"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch item.state {
        case .queued: return .secondary
        case .running: return .accentColor
        case .paused: return .orange
        case .finished: return .green
        case .failed: return .red
        }
    }
}

// MARK: - 浏览器设置（对齐 Firefox for iOS）

struct BrowserSettingsView: View {
    @ObservedObject var library: UserscriptLibrary

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @AppStorage(SettingsKey.homePage) private var homePage = ""
    @AppStorage(SettingsKey.searchEngine) private var engineRaw = SearchEngine.baidu.rawValue
    @AppStorage(SettingsKey.customSearch) private var customSearch = ""
    @AppStorage(SettingsKey.noImage) private var noImage = false
    @AppStorage(SettingsKey.uaMode) private var uaMode = UAMode.mobile.rawValue
    @AppStorage(SettingsKey.customUA) private var customUA = ""
    @AppStorage(SettingsKey.adBlock) private var adBlock = true
    @AppStorage(SettingsKey.fabX) private var fabX = -1.0
    @AppStorage(SettingsKey.fabY) private var fabY = -1.0

    @State private var showScripts = false
    @State private var confirmClearData = false
    @State private var confirmClearHistory = false
    @State private var toast: String?

    private var isDark: Bool { scheme == .dark }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    section("常规") {
                        toggle("无图模式", "photo", Color(red: 0.96, green: 0.55, blue: 0.18), isOn: $noImage)
                        toggle("广告拦截", "shield.lefthalf.filled", Color(red: 0.20, green: 0.65, blue: 0.42), isOn: $adBlock)
                    }

                    section("搜索") {
                        pickerRow("搜索引擎", "magnifyingglass", Color(red: 0.20, green: 0.47, blue: 0.90)) {
                            Picker("", selection: $engineRaw) {
                                ForEach(SearchEngine.allCases) { engine in
                                    Text(engine.title).tag(engine.rawValue)
                                }
                            }
                            .labelsHidden()
                            .tint(FirefoxStyle.accent)
                        }

                        if (SearchEngine(rawValue: engineRaw) ?? .baidu) == .custom {
                            HStack(spacing: 10) {
                                TextField("https://example.com/search?q=%s", text: $customSearch)
                                    .font(.system(size: 13, design: .monospaced))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                        }
                    }

                    section("主页") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("留空显示常用网站宫格", text: $homePage)
                                .font(.system(size: 14, design: .monospaced))
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }

                    section("网页标识") {
                        pickerRow("网页版本", "desktopcomputer", Color(red: 0.32, green: 0.56, blue: 0.94)) {
                            Picker("", selection: $uaMode) {
                                ForEach(UAMode.allCases) { mode in
                                    Text(mode.title).tag(mode.rawValue)
                                }
                            }
                            .labelsHidden()
                            .tint(FirefoxStyle.accent)
                        }

                        if UAMode(rawValue: uaMode) == .custom {
                            TextField(
                                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) ...",
                                text: $customUA,
                                axis: .vertical
                            )
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(3...6)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                        }
                    }

                    section("扩展") {
                        Button {
                            showScripts = true
                        } label: {
                            HStack(spacing: 11) {
                                badge("curlybraces", Color(red: 0.86, green: 0.30, blue: 0.52))
                                Text("油猴脚本")
                                    .font(.system(size: 16))
                                    .foregroundStyle(FirefoxStyle.text(isDark))
                                Spacer(minLength: 6)
                                Text(library.statusText)
                                    .font(.system(size: 13))
                                    .foregroundStyle(FirefoxStyle.sub(isDark))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(FirefoxStyle.sub(isDark).opacity(0.7))
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 50)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    section("隐私与数据") {
                        actionRow("重置悬浮球位置", "arrow.counterclockwise", Color(red: 0.45, green: 0.45, blue: 0.50)) {
                            fabX = -1
                            fabY = -1
                            showToast("悬浮球已回到默认位置")
                        }
                        actionRow("清除浏览历史", "clock.arrow.circlepath", Color(red: 0.20, green: 0.47, blue: 0.90), destructive: true) {
                            confirmClearHistory = true
                        }
                        actionRow("清除缓存与 Cookie", "trash", Color(red: 0.88, green: 0.24, blue: 0.24), destructive: true) {
                            confirmClearData = true
                        }
                    }

                    section("关于") {
                        HStack(spacing: 11) {
                            badge("info.circle.fill", Color(red: 0.45, green: 0.45, blue: 0.50))
                            Text("版本")
                                .font(.system(size: 16))
                                .foregroundStyle(FirefoxStyle.text(isDark))
                            Spacer()
                            Text(versionText)
                                .font(.system(size: 14))
                                .foregroundStyle(FirefoxStyle.sub(isDark))
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 50)

                        HStack(spacing: 11) {
                            badge("person.fill", Color(red: 0.98, green: 0.45, blue: 0.35))
                            Text("作者")
                                .font(.system(size: 16))
                                .foregroundStyle(FirefoxStyle.text(isDark))
                            Spacer()
                            Text("衣")
                                .font(.system(size: 14))
                                .foregroundStyle(FirefoxStyle.sub(isDark))
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 50)
                    }

                    Text("工具箱 · 浏览器内核基于 WKWebView\n界面参考 Firefox for iOS 的信息结构")
                        .font(.system(size: 11.5))
                        .foregroundStyle(FirefoxStyle.sub(isDark).opacity(0.8))
                        .lineSpacing(3)
                        .padding(.horizontal, 6)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
            .background(FirefoxStyle.bg(isDark))
            .onAppear {
                // 进来先按当前存储值刷一遍，避免开关是「开着」但页面从没应用过
                NotificationCenter.default.post(name: .browserAppearanceChanged, object: nil)
            }
            .onChange(of: noImage) { value in
                notifyAppearance(value ? "无图模式已开启" : "无图模式已关闭")
            }
            .onChange(of: adBlock) { value in
                notifyAppearance(value ? "广告拦截已开启" : "广告拦截已关闭")
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let text = toast {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .padding(.bottom, 24)
                }
            }
            .sheet(isPresented: $showScripts) {
                UserscriptListView(library: library)
            }
            .confirmationDialog("清除缓存与 Cookie？", isPresented: $confirmClearData, titleVisibility: .visible) {
                Button("清除", role: .destructive) { clearCache() }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("清除全部浏览历史？", isPresented: $confirmClearHistory, titleVisibility: .visible) {
                Button("清除", role: .destructive) {
                    BrowserHistory.shared.clear()
                    showToast("浏览历史已清除")
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: 组件

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FirefoxStyle.sub(isDark))
                .padding(.leading, 4)

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
    }

    private func badge(_ symbol: String, _ tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint)
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 28, height: 28)
    }

    private func toggle(_ title: String, _ symbol: String, _ tint: Color, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 11) {
            badge(symbol, tint)
            Toggle(isOn: isOn) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(FirefoxStyle.text(isDark))
            }
            .tint(FirefoxStyle.accent)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FirefoxStyle.line(isDark))
                .frame(height: 0.5)
                .padding(.leading, 53)
        }
    }

    private func pickerRow<Content: View>(_ title: String, _ symbol: String, _ tint: Color,
                                          @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 11) {
            badge(symbol, tint)
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(FirefoxStyle.text(isDark))
            Spacer(minLength: 6)
            content()
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FirefoxStyle.line(isDark))
                .frame(height: 0.5)
                .padding(.leading, 53)
        }
    }

    private func actionRow(_ title: String, _ symbol: String, _ tint: Color,
                           destructive: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                badge(symbol, tint)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(destructive ? Color(red: 0.88, green: 0.24, blue: 0.24) : FirefoxStyle.text(isDark))
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FirefoxStyle.line(isDark))
                .frame(height: 0.5)
                .padding(.leading, 53)
        }
    }

    /// 设置页和网页不在同一层视图，改完直接广播，让嗅探页立刻重刷
    private func notifyAppearance(_ text: String) {
        NotificationCenter.default.post(name: .browserAppearanceChanged, object: nil)
        showToast(text)
    }

    private func clearCache() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(
            ofTypes: types,
            modifiedSince: Date(timeIntervalSince1970: 0),
            completionHandler: {}
        )
        URLCache.shared.removeAllCachedResponses()
        showToast("缓存已清除")
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeIn(duration: 0.2)) { toast = nil }
        }
    }
}

// MARK: - 备用下载地址

struct AltSourceSheet: View {
    let item: DownloadItem

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.fileName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)

                    Text(item.sources.first ?? item.source)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } header: {
                    Text("主地址")
                }

                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 150)
                        .font(.system(size: 11, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("备用地址（一行一个）")
                } footer: {
                    Text("主地址失败时会按顺序自动换下一个。也可以点下载列表里的「换源重试」手动换。")
                }

                Section {
                    PasteButton(payloadType: String.self) { strings in
                        guard let value = strings.first, !value.isEmpty else { return }
                        text = text.isEmpty ? value : text + "\n" + value
                    }
                    .labelStyle(.titleAndIcon)

                    if !text.isEmpty {
                        Button("清空", role: .destructive) { text = "" }
                    }
                }
            }
            .navigationTitle("备用地址")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        DownloadManager.shared.setAlternates(text, for: item)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            if text.isEmpty {
                text = item.sources.dropFirst().joined(separator: "\n")
            }
        }
    }
}
