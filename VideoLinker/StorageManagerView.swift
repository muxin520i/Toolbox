import SwiftUI

// MARK: - 存储管理

struct StorageFile: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let size: Int64
    let modified: Date
    var duration: Double?
    var inPlaylist: Bool
    /// 0~1，看过多少
    var watched: Double?
    /// 同尺寸的疑似重复文件（值为尺寸），不重复为 nil
    var duplicateSize: Int64?
}

struct StorageManagerView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var files: [StorageFile] = []
    @State private var loading = true
    @State private var totalSize: Int64 = 0
    @State private var freeSpace: Int64 = 0
    @State private var toast: String?
    @State private var confirmDuplicates = false
    @State private var confirmWatched = false
    @State private var showDuplicateFinder = false

    private var duplicates: [StorageFile] {
        files.filter { $0.duplicateSize != nil }
    }

    private var watchedFiles: [StorageFile] {
        files.filter { ($0.watched ?? 0) >= 0.95 }
    }

    private var orphanFiles: [StorageFile] {
        files.filter { !$0.inPlaylist }
    }

    /// 重复文件（每组留最早的一个）+ 已看完的，理论上能腾出来的空间
    private var reclaimable: Int64 {
        var total: Int64 = 0
        var seen = Set<Int64>()
        for file in files.sorted(by: { $0.modified < $1.modified }) {
            if let key = file.duplicateSize {
                if seen.contains(key) {
                    total += file.size
                    continue
                }
                seen.insert(key)
            }
            if (file.watched ?? 0) >= 0.95 {
                total += file.size
            }
        }
        return total
    }

    private var duplicateWaste: Int64 {
        var total: Int64 = 0
        var seen = Set<Int64>()
        for file in files.sorted(by: { $0.modified < $1.modified }) {
            guard let key = file.duplicateSize else { continue }
            if seen.contains(key) {
                total += file.size
            } else {
                seen.insert(key)
            }
        }
        return total
    }

    private var watchedSize: Int64 {
        watchedFiles.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                if loading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在统计…")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                    }
                } else if files.isEmpty {
                    emptyState
                } else {
                    content
                }

                if let toast = toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.8), in: Capsule())
                            .padding(.bottom, 28)
                    }
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("存储管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .disabled(loading)
                }
            }
            .onAppear(perform: reload)
            .confirmationDialog(
                "合并 \(duplicateGroupCount) 组重复视频（每组保留最早的一个）？",
                isPresented: $confirmDuplicates,
                titleVisibility: .visible
            ) {
                Button("合并，腾出 \(Fmt.bytes(duplicateWaste))", role: .destructive) {
                    cleanDuplicates()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("播放列表里的条目和观看进度会迁到保留下来的文件上。只按文件大小判断重复，合并前建议先看一眼文件名")
            }
            .confirmationDialog(
                "删除 \(watchedFiles.count) 个已看完的视频？",
                isPresented: $confirmWatched,
                titleVisibility: .visible
            ) {
                Button("删除，腾出 \(Fmt.bytes(watchedSize))", role: .destructive) {
                    cleanWatched()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("观看进度会一起清掉，删了就找不回来了")
            }
            .sheet(isPresented: $showDuplicateFinder) {
                DuplicateFinderView()
            }
        }
    }

    private var duplicateGroupCount: Int {
        Set(duplicates.compactMap { $0.duplicateSize }).count
    }

    // MARK: 内容

    private var content: some View {
        List {
            summaryCard
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 6, trailing: 20))

            actionsCard
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 10, trailing: 20))

            Section {
                ForEach(files) { file in
                    row(file)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 3, leading: 20, bottom: 3, trailing: 20))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                remove(file)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            } header: {
                Text("按大小排序 · 共 \(files.count) 个")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .textCase(nil)
            }

            Text("删掉后播放列表里的对应条目会一起清理；想留着以后再看，先别删。")
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 30, trailing: 20))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.bytes(totalSize))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.text)
                Text("已占用")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
                Spacer()
            }

            HStack(spacing: 0) {
                metric(title: "设备可用", value: freeSpace > 0 ? Fmt.bytes(freeSpace) : "—")
                Divider().frame(height: 26).overlay(theme.cardStroke)
                metric(title: "可释放", value: Fmt.bytes(reclaimable))
                Divider().frame(height: 26).overlay(theme.cardStroke)
                metric(title: "未进列表", value: "\(orphanFiles.count) 个")
            }

            usageBar
        }
        .padding(16)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    /// 占比条：一眼看出空间被「已进列表」还是「散落的文件」吃掉了
    private var usageBar: some View {
        let listed = listedSize
        let orphan = max(0, totalSize - listed)
        let total = max(totalSize, 1)

        return VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    if listed > 0 {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(theme.accent)
                            .frame(width: max(4, geo.size.width * CGFloat(listed) / CGFloat(total)))
                    }
                    if orphan > 0 {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.orange.opacity(0.72))
                    }
                }
            }
            .frame(height: 8)

            HStack(spacing: 14) {
                legend(color: theme.accent, text: "已在列表 \(Fmt.bytes(listed))")
                legend(color: .orange.opacity(0.72), text: "未进列表 \(Fmt.bytes(orphan))")
            }
        }
        .padding(.top, 2)
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private var listedSize: Int64 {
        files.filter { $0.inPlaylist }.reduce(0) { $0 + $1.size }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
    }

    private var actionsCard: some View {
        VStack(spacing: 10) {
            if !duplicates.isEmpty, duplicateWaste > 0 {
                Button {
                    confirmDuplicates = true
                } label: {
                    actionRow(
                        title: "合并重复视频",
                        detail: "\(duplicateGroupCount) 组 · 可腾 \(Fmt.bytes(duplicateWaste))",
                        symbol: "doc.on.doc"
                    )
                }
                .buttonStyle(.plain)
            }

            if !watchedFiles.isEmpty {
                Button {
                    confirmWatched = true
                } label: {
                    actionRow(
                        title: "清理已看完的",
                        detail: "\(watchedFiles.count) 个 · 可腾 \(Fmt.bytes(watchedSize))",
                        symbol: "checkmark.circle"
                    )
                }
                .buttonStyle(.plain)
            }

            Button {
                showDuplicateFinder = true
            } label: {
                actionRow(
                    title: "按画面查重",
                    detail: "抽帧比对指纹，不同清晰度的同一部片也能认出来",
                    symbol: "square.on.square.dashed"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func actionRow(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(13)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private func row(_ file: StorageFile) -> some View {
        let biggest = max(files.first?.size ?? 1, 1)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                VideoThumbnail(path: file.path, width: 58, height: 36, corner: 7)

                VStack(alignment: .leading, spacing: 4) {
                    Text(file.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(Fmt.bytes(file.size))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)

                        if let duration = file.duration, duration > 0 {
                            Text("·").font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                            Text(ThumbnailCache.timeText(duration))
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textTertiary)
                        }

                        if let watched = file.watched, watched > 0.02 {
                            Text("·").font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                            Text(watched >= 0.95 ? "已看完" : "看到 \(Int((watched * 100).rounded()))%")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(watched >= 0.95 ? theme.textTertiary : theme.accent)
                        }
                    }
                }

                Spacer(minLength: 6)

                if file.duplicateSize != nil {
                    badge("重复", color: .orange)
                } else if !file.inPlaylist {
                    badge("未进列表", color: theme.textTertiary)
                }
            }

            // 相对占比：最大的那条满格，一眼看出谁在吃空间
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.field)
                    Capsule()
                        .fill(theme.accent.opacity(0.45))
                        .frame(width: max(3, geo.size.width * CGFloat(file.size) / CGFloat(biggest)))
                }
            }
            .frame(height: 3)
            .padding(.leading, 70)
        }
        .padding(11)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
        .contextMenu {
            Button {
                UIPasteboard.general.string = file.path
                showToast("路径已复制")
            } label: {
                Label("复制文件路径", systemImage: "doc.on.doc")
            }
            Button {
                MediaExporter.exportToFiles([URL(fileURLWithPath: file.path)])
            } label: {
                Label("导出到「文件」", systemImage: "folder.badge.plus")
            }
            Divider()
            Button(role: .destructive) {
                remove(file)
            } label: {
                Label("删除文件", systemImage: "trash")
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color, in: Capsule())
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "internaldrive")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(theme.textTertiary)
            Text("本机没有视频文件")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Text("下载或导入的视频会出现在这里")
                .font(.system(size: 12))
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 逻辑

    private func reload() {
        loading = true
        Task {
            let scanned = await LocalMedia.scan(limit: 500, probeDuration: false)
            let playlistPaths = Set(
                PlaylistStore.load().flatMap { $0.items.compactMap { $0.localPath } }
            )

            var sameSize: [Int64: Int] = [:]
            for file in scanned {
                sameSize[file.size, default: 0] += 1
            }

            let mapped = scanned.map { file -> StorageFile in
                let url = URL(fileURLWithPath: file.path).absoluteString
                let isDuplicate = (sameSize[file.size] ?? 0) > 1 && file.size > 5 * 1024 * 1024
                return StorageFile(
                    path: file.path,
                    name: file.name,
                    size: file.size,
                    modified: file.modified,
                    duration: file.duration,
                    inPlaylist: playlistPaths.contains(file.path),
                    watched: ResumeStore.progress(for: url),
                    duplicateSize: isDuplicate ? file.size : nil
                )
            }
            .sorted { $0.size > $1.size }

            let total = mapped.reduce(Int64(0)) { $0 + $1.size }
            let free = Self.availableSpace()

            await MainActor.run {
                files = mapped
                totalSize = total
                freeSpace = free
                loading = false
            }
        }
    }

    private func remove(_ file: StorageFile) {
        deleteFiles([file.path])
        withAnimation(.easeInOut(duration: 0.2)) {
            files.removeAll { $0.path == file.path }
            totalSize = max(0, totalSize - file.size)
        }
        showToast("已删除 \(Fmt.bytes(file.size))")
    }

    private func cleanDuplicates() {
        var keep: [Int64: StorageFile] = [:]
        var replacements: [String: String] = [:]
        var targets: [String] = []
        var freed: Int64 = 0

        for file in files.sorted(by: { $0.modified < $1.modified }) {
            guard let key = file.duplicateSize else { continue }
            if let original = keep[key] {
                replacements[file.path] = original.path
                targets.append(file.path)
                freed += file.size
            } else {
                keep[key] = file
            }
        }

        guard !targets.isEmpty else { return }

        // 先把播放列表条目挪到保留的文件上，再删物理文件，
        // 不然列表里会留下一堆指向已删文件的死条目
        let moved = PlaylistStore.mergeDuplicatePaths(replacements)
        for (oldPath, newPath) in replacements {
            ResumeStore.migrate(
                from: URL(fileURLWithPath: oldPath).absoluteString,
                to: URL(fileURLWithPath: newPath).absoluteString
            )
        }

        deleteFiles(targets)
        let merged = Set(replacements.values).count
        showToast("已合并 \(merged) 组，腾出 \(Fmt.bytes(freed))，迁移 \(moved) 条列表记录")
        reload()
    }

    private func cleanWatched() {
        let targets = watchedFiles.map { $0.path }
        guard !targets.isEmpty else { return }
        let freed = watchedSize
        deleteFiles(targets)
        showToast("已清理 \(targets.count) 个，腾出 \(Fmt.bytes(freed))")
        reload()
    }

    private func deleteFiles(_ paths: [String]) {
        for path in paths {
            if let item = DownloadManager.shared.items.first(where: { $0.localPath == path }) {
                DownloadManager.shared.remove(item)
            } else {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        PlaylistStore.pruneMissingLocalItems()
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if toast == text {
                withAnimation(.easeIn(duration: 0.2)) { toast = nil }
            }
        }
    }

    private static func availableSpace() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return 0 }
        return capacity
    }
}
