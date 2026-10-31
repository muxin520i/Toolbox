import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 备份文件

struct VideoLinkerBackup: Codable {
    var version: Int = 1
    var playlists: [Playlist]
    var favorites: [String]
    var history: [HistoryItem]
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - 列表总览

struct PlaylistListView: View {
    @Environment(\.theme) private var theme

    @State private var playlists: [Playlist] = PlaylistStore.load()
    @State private var downloadListID: UUID? = PlaylistStore.existingDownloadListID()
    @AppStorage(PlaylistStore.downloadTargetKey) private var downloadTarget = PlaylistStore.autoTarget
    @State private var showCreateSheet = false
    @State private var newName = ""

    @State private var showExporter = false
    @State private var showImporter = false
    @State private var backupData = Data()
    @State private var alertText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                ScrollView {
                    VStack(spacing: 10) {
                        if playlists.isEmpty {
                            emptyState
                        } else {
                            ForEach(playlists) { playlist in
                                NavigationLink {
                                    PlaylistDetailView(playlistID: playlist.id)
                                } label: {
                                    row(playlist)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            playlists = PlaylistStore.delete(playlist.id)
                                        }
                                    } label: {
                                        Label("删除列表", systemImage: "trash")
                                    }
                                }
                            }
                        }

                        backupHint
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("播放列表")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(theme.navBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button {
                            exportBackup()
                        } label: {
                            Label("导出备份", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            showImporter = true
                        } label: {
                            Label("从备份导入", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        newName = ""
                        showCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
        }
        .onAppear {
            playlists = PlaylistStore.load()
            downloadListID = PlaylistStore.existingDownloadListID()
        }
        .sheet(isPresented: $showCreateSheet) {
            createSheet
                .presentationDetents([.height(230)])
                .presentationDragIndicator(.visible)
        }
        .fileExporter(
            isPresented: $showExporter,
            document: BackupDocument(data: backupData),
            contentType: .json,
            defaultFilename: "videolinker-backup"
        ) { _ in }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json]
        ) { result in
            importBackup(result)
        }
        .alert("提示", isPresented: Binding(
            get: { alertText != nil },
            set: { if !$0 { alertText = nil } }
        )) {
            Button("知道了", role: .cancel) { alertText = nil }
        } message: {
            Text(alertText ?? "")
        }
    }

    private var backupHint: some View {
        Text("点左上角 ⋯ 可以导出/导入备份，换机或重装不会丢列表")
            .font(.system(size: 11))
            .foregroundStyle(theme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 18)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(theme.textTertiary)
            Text("还没有播放列表")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Text("点右上角 + 新建一个，把常看的视频放进去")
                .font(.system(size: 12))
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    private func badgeTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(theme.accent, in: Capsule())
    }

    private func row(_ playlist: Playlist) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.gradientTopLeft)
                .frame(width: 46, height: 46)
                .overlay(
                    Image(systemName: "list.bullet")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(playlist.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)

                    if playlist.id.uuidString == downloadTarget {
                        badgeTag("下载保存到")
                    } else if playlist.id == downloadListID {
                        badgeTag("内置")
                    }
                }
                Text(playlist.items.isEmpty ? "空列表" : "\(playlist.items.count) 个视频")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(12)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private var createSheet: some View {        VStack(alignment: .leading, spacing: 16) {
            Text("新建播放列表")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.text)
                .padding(.top, 22)

            TextField("", text: $newName,
                      prompt: Text("给列表起个名字").foregroundColor(theme.textTertiary))
                .font(.system(size: 15))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            Button {
                playlists = PlaylistStore.create(named: newName)
                showCreateSheet = false
            } label: {
                Text("创建")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(theme.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .background(theme.bg)
    }

    // MARK: 备份

    private func exportBackup() {
        let backup = VideoLinkerBackup(
            playlists: PlaylistStore.load(),
            favorites: Array(ResumeStore.favorites()),
            history: HistoryStore.load()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(backup) else {
            alertText = "导出失败，请重试。"
            return
        }
        backupData = data
        showExporter = true
    }

    private func importBackup(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            alertText = "这个文件读不出来。"
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let backup = try? decoder.decode(VideoLinkerBackup.self, from: data) else {
            alertText = "文件格式不对，需要本 App 导出的备份文件。"
            return
        }

        // 合并：同名列表追加条目，其余新建
        var current = PlaylistStore.load()
        var localSkipped = 0
        for incoming in backup.playlists {
            // 本机下载的条目拷到别的设备上文件不存在，导入时跳过
            let usable = incoming.items.filter {
                if $0.isLocal { localSkipped += 1; return false }
                return true
            }
            if let index = current.firstIndex(where: { $0.name == incoming.name }) {
                let existing = Set(current[index].items.map { $0.url })
                let fresh = usable.filter { !existing.contains($0.url) }
                current[index].items.append(contentsOf: fresh)
            } else {
                var copy = incoming
                copy.items = usable
                current.append(copy)
            }
        }
        PlaylistStore.save(current)

        if !backup.favorites.isEmpty {
            let set = ResumeStore.favorites().union(backup.favorites)
            UserDefaults.standard.set(Array(set), forKey: "video.favorites.v1")
        }

        playlists = PlaylistStore.load()
        alertText = localSkipped > 0
            ? "已导入 \(backup.playlists.count) 个列表，\(localSkipped) 条本机下载记录未导入。"
            : "已导入 \(backup.playlists.count) 个列表。"
    }
}

// MARK: - 列表详情

struct PlaylistDetailView: View {
    @Environment(\.theme) private var theme

    let playlistID: UUID

    @State private var playlist: Playlist?
    @State private var request: PlayRequest?
    @State private var showAddSheet = false
    @State private var showBulkSheet = false
    @State private var addURL = ""
    @State private var addTitle = ""
    @State private var bulkText = ""
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    @State private var toast: String?
    @State private var showMoveSheet = false
    @State private var pendingMoveIDs = Set<UUID>()

    var body: some View {
        ZStack {
            BackgroundView()

            if let playlist = playlist, !playlist.items.isEmpty {
                itemList(playlist)
            } else {
                emptyState
            }

            if let toast = toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.78), in: Capsule())
                        .padding(.bottom, 30)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .navigationTitle(playlist?.name ?? "列表")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.navBg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(editMode == .active ? "完成" : "编辑") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        editMode = editMode == .active ? .inactive : .active
                    }
                }
                .font(.system(size: 15, weight: .medium))
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    if editMode == .active {
                        Button {
                            pendingMoveIDs = selection
                            showMoveSheet = true
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(selection.isEmpty ? theme.textTertiary : theme.accent)
                        }
                        .disabled(selection.isEmpty)

                        Button {
                            deleteSelected()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(selection.isEmpty ? theme.textTertiary : .red)
                        }
                        .disabled(selection.isEmpty)
                    } else {
                        Menu {
                            Button {
                                addURL = ""
                                addTitle = ""
                                showAddSheet = true
                            } label: {
                                Label("添加一条", systemImage: "plus")
                            }
                            Button {
                                bulkText = ""
                                showBulkSheet = true
                            } label: {
                                Label("批量粘贴导入", systemImage: "text.badge.plus")
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: editMode) { newValue in
            if newValue == .inactive { selection.removeAll() }
        }
        .sheet(isPresented: $showAddSheet) {
            addSheet
                .presentationDetents([.height(320)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showBulkSheet) {
            bulkSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showMoveSheet) {
            PlaylistMoveSheet(
                sourceID: playlistID,
                count: pendingMoveIDs.count,
                onPick: { target in
                    let moved = PlaylistStore.move(pendingMoveIDs, from: playlistID, to: target.id)
                    pendingMoveIDs = []
                    selection.removeAll()
                    editMode = .inactive
                    reload()
                    toast = moved > 0 ? "已移动到「\(target.name)」" : "「\(target.name)」里已经有这些视频"
                    hideToastSoon()
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $request) { req in
            PlayerScreen(request: req)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(theme.textTertiary)
            Text("列表是空的")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Text("点右上角 + 添加，支持一次粘贴多行链接")
                .font(.system(size: 12))
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    private func itemList(_ playlist: Playlist) -> some View {
        List {
            ForEach(Array(playlist.items.enumerated()), id: \.element.id) { index, item in
                row(item, index: index)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            PlaylistStore.removeItem(item.id, from: playlistID)
                            reload()
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
            .onMove { source, destination in
                PlaylistStore.moveItem(in: playlistID, from: source, to: destination)
                reload()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $editMode)
    }

    private func row(_ item: PlaylistItem, index: Int) -> some View {
        Button {
            if editMode == .active {
                toggleSelection(item.id)
                return
            }
            guard let playlist = playlist else { return }

            if item.isLocal && !item.localFileExists {
                toast = "文件已被删除，可以重新下载一次"
                hideToastSoon()
                return
            }

            // 本地文件可能被清理掉了，队列里先剔掉，避免连播时卡在坏条目上
            let playable = playlist.items.filter { !$0.isLocal || $0.localFileExists }
            let playbackItems = playable.map {
                PlaybackItem(url: $0.url, title: $0.displayTitle)
            }
            guard !playbackItems.isEmpty else { return }
            let start = playable.firstIndex(where: { $0.id == item.id }) ?? 0
            request = PlayRequest(items: playbackItems, startIndex: start)
        } label: {
            HStack(spacing: 13) {
                if editMode == .active {
                    Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(selection.contains(item.id) ? theme.accent : theme.textTertiary)
                        .frame(width: 26, alignment: .leading)
                } else {
                    Text(String(format: "%02d", index + 1))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 26, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if item.isLocal {
                    Image(systemName: item.localFileExists ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(item.localFileExists ? theme.accent.opacity(0.85) : Color.orange)
                }

                if ResumeStore.progress(for: item.url) != nil {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.accent.opacity(0.8))
                }

                if editMode == .inactive {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(theme.field, in: Circle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.cardStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if item.isLocal {
                Button {
                    UIPasteboard.general.string = item.localPath ?? item.url
                } label: {
                    Label("复制文件路径", systemImage: "doc.on.doc")
                }
            } else {
                Button {
                    UIPasteboard.general.string = item.url
                } label: {
                    Label("复制链接", systemImage: "doc.on.doc")
                }
            }
            Button {
                pendingMoveIDs = [item.id]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showMoveSheet = true
                }
            } label: {
                Label("移动到其他列表", systemImage: "folder")
            }
            Button {
                ResumeStore.remove(url: item.url)
                toast = "已清除这条的观看进度"
                hideToastSoon()
            } label: {
                Label("清除观看进度", systemImage: "arrow.counterclockwise")
            }
            Button(role: .destructive) {
                PlaylistStore.removeItem(item.id, from: playlistID)
                reload()
            } label: {
                Label("从列表移除", systemImage: "minus.circle")
            }
        }
    }

    // MARK: 添加

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加视频")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.text)
                .padding(.top, 22)

            TextField("", text: $addURL,
                      prompt: Text("视频链接").foregroundColor(theme.textTertiary))
                .font(.system(size: 15))
                .foregroundStyle(theme.text)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            TextField("", text: $addTitle,
                      prompt: Text("标题（可留空）").foregroundColor(theme.textTertiary))
                .font(.system(size: 15))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            HStack(spacing: 10) {
                Button {
                    if let s = UIPasteboard.general.string {
                        addURL = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Text("粘贴")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(theme.field, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    saveNewItem()
                } label: {
                    Text("添加")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(theme.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .opacity(normalizedURL == nil ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .disabled(normalizedURL == nil)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .background(theme.bg)
    }

    private var bulkSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("批量导入")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer()
                Text("\(parsedBulkLines.count) 条")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.top, 22)

            Text("一行一个链接，空行和重复的会自动跳过")
                .font(.system(size: 12))
                .foregroundStyle(theme.textTertiary)

            TextEditor(text: $bulkText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(theme.text)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .frame(maxHeight: .infinity)

            HStack(spacing: 10) {
                Button {
                    if let s = UIPasteboard.general.string {
                        bulkText = s
                    }
                } label: {
                    Text("粘贴全部")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(theme.field, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    importBulk()
                } label: {
                    Text("导入")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(theme.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .opacity(parsedBulkLines.isEmpty ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .disabled(parsedBulkLines.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .background(theme.bg)
    }

    // MARK: 逻辑

    private var parsedBulkLines: [String] {
        bulkText
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains(".") && !$0.contains(" ") }
    }

    private func importBulk() {
        var added = 0
        for line in parsedBulkLines {
            var s = line
            if !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") {
                s = "https://" + s
            }
            guard let u = URL(string: s), u.host != nil else { continue }
            let before = PlaylistStore.load().first { $0.id == playlistID }?.items.count ?? 0
            PlaylistStore.add(PlaylistItem(url: u.absoluteString, title: ""), to: playlistID)
            let after = PlaylistStore.load().first { $0.id == playlistID }?.items.count ?? 0
            if after > before { added += 1 }
        }
        reload()
        showBulkSheet = false
        toast = "已导入 \(added) 条"
        hideToastSoon()
    }

    private func deleteSelected() {
        guard !selection.isEmpty else { return }
        for id in selection {
            PlaylistStore.removeItem(id, from: playlistID)
        }
        selection.removeAll()
        editMode = .inactive
        reload()
    }

    private func toggleSelection(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private var normalizedURL: String? {
        var s = addURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        guard let u = URL(string: s), let host = u.host, host.contains(".") else { return nil }
        return u.absoluteString
    }

    private func saveNewItem() {
        guard let url = normalizedURL else { return }
        let item = PlaylistItem(url: url, title: addTitle)
        let lists = PlaylistStore.add(item, to: playlistID)
        playlist = lists.first { $0.id == playlistID }
        showAddSheet = false
    }

    private func reload() {
        playlist = PlaylistStore.load().first { $0.id == playlistID }
    }

    private func hideToastSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeInOut(duration: 0.2)) { toast = nil }
        }
    }
}

// MARK: - 移动到其他列表

struct PlaylistMoveSheet: View {
    let sourceID: UUID
    let count: Int
    var onPick: (Playlist) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var playlists: [Playlist] = []

    private var targets: [Playlist] {
        playlists.filter { $0.id != sourceID }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                if targets.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(theme.textTertiary)
                        Text("还没有别的列表")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                        Text("先回列表页新建一个，再回来移动")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(targets) { playlist in
                                Button {
                                    pick(playlist)
                                } label: {
                                    row(playlist)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle(count > 1 ? "移动 \(count) 条到" : "移动到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.navBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear { playlists = PlaylistStore.load() }
        }
    }

    private func row(_ playlist: Playlist) -> some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.field)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "list.bullet")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text(playlist.items.isEmpty ? "空列表" : "\(playlist.items.count) 个视频")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer(minLength: 6)

            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(12)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private func pick(_ target: Playlist) {
        guard count > 0 else {
            dismiss()
            return
        }
        onPick(target)
        dismiss()
    }
}
