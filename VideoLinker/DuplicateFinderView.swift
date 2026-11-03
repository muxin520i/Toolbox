import SwiftUI
import UIKit

// MARK: - 画面查重

final class DuplicateFinderModel: ObservableObject {
    @Published var groups: [DuplicateScanner.Group] = []
    @Published var scanning = false
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var scanned = 0
    @Published var failed = 0
    @Published var cached = 0
    @Published var keep: [UUID: String] = [:]
    @Published var selected: Set<UUID> = []
    @Published var merging = false

    var selectedGroups: [DuplicateScanner.Group] {
        groups.filter { selected.contains($0.id) }
    }

    var totalWaste: Int64 {
        selectedGroups.reduce(0) { $0 + $1.waste }
    }

    func scan() async {
        guard !scanning else { return }
        await MainActor.run {
            scanning = true
            progress = 0
            statusText = "正在读取本机视频…"
        }

        let files = await LocalMedia.scan(limit: 600, probeDuration: false)

        let result = await DuplicateScanner.scan(files: files) { done, total in
            DispatchQueue.main.async {
                self.progress = total > 0 ? Double(done) / Double(total) : 0
                self.statusText = "正在比对画面 \(done)/\(total)"
            }
        }

        await MainActor.run {
            groups = result.groups
            scanned = result.scanned
            failed = result.failed
            cached = result.cached
            scanning = false
            statusText = ""
            keep = Dictionary(uniqueKeysWithValues: result.groups.map { ($0.id, $0.files[0].path) })
            selected = Set(result.groups.map { $0.id })
        }
    }

    /// 每组留一条，其余删掉，播放列表记录和进度都迁到留下的那条上
    func mergeSelected() {
        guard !merging else { return }
        merging = true

        var removedTotal: Int64 = 0
        var removedCount = 0
        let targets = selectedGroups

        for group in targets {
            let keepPath = keep[group.id] ?? group.files[0].path
            var replacements: [String: String] = [:]

            for file in group.files where file.path != keepPath {
                replacements[file.path] = keepPath
                removedTotal += file.size
                removedCount += 1
            }

            guard !replacements.isEmpty else { continue }

            _ = PlaylistStore.mergeDuplicatePaths(replacements)

            for (oldPath, newPath) in replacements {
                ResumeStore.migrate(
                    from: URL(fileURLWithPath: oldPath).absoluteString,
                    to: URL(fileURLWithPath: newPath).absoluteString
                )

                if let item = DownloadManager.shared.items.first(where: { $0.localPath == oldPath }) {
                    DownloadManager.shared.remove(item)
                } else {
                    try? FileManager.default.removeItem(atPath: oldPath)
                }
            }
        }

        PlaylistStore.pruneMissingLocalItems()

        groups.removeAll { selected.contains($0.id) }
        selected.removeAll()
        merging = false

        lastMergedText = removedCount > 0
            ? "已删 \(removedCount) 个，腾出 \(Fmt.bytes(removedTotal))"
            : "没有需要删的文件"
    }

    @Published var lastMergedText = ""
}

struct DuplicateFinderView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = DuplicateFinderModel()
    @State private var confirmMerge = false
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                if model.scanning {
                    scanningView
                } else if model.groups.isEmpty {
                    emptyView
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
            .navigationTitle("画面查重")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await model.scan() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .disabled(model.scanning)
                }
            }
            .confirmationDialog(
                "删除 \(model.selectedGroups.reduce(0) { $0 + $1.files.count - 1 }) 个重复文件？",
                isPresented: $confirmMerge,
                titleVisibility: .visible
            ) {
                Button("合并，腾出 \(Fmt.bytes(model.totalWaste))", role: .destructive) {
                    model.mergeSelected()
                    showToast(model.lastMergedText)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("每组保留你勾选的那一个，播放列表里的条目和观看进度会迁过去。删了就找不回来了。")
            }
        }
        .task {
            if model.groups.isEmpty, !model.scanning {
                await model.scan()
            }
        }
    }

    // MARK: 扫描中

    private var scanningView: some View {
        VStack(spacing: 16) {
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .tint(theme.accent)
                .frame(width: 220)

            Text(model.statusText.isEmpty ? "正在准备…" : model.statusText)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)

            Text("第一次要把每个视频抽一帧算指纹，文件多会比较慢；算过的会缓存。")
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: 空状态

    private var emptyView: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(theme.textTertiary)
            Text("没有找到重复的视频")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Text("按画面指纹比对，同一部片的不同清晰度也能认出来。\n已扫描 \(model.scanned) 个文件" +
                 (model.failed > 0 ? "，\(model.failed) 个读不出画面已跳过" : ""))
                .font(.system(size: 12))
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 结果

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    summaryCard

                    ForEach(model.groups) { group in
                        groupCard(group)
                    }

                    Text("比对方式：抽每个视频 15% 处的一帧，算 64 位画面指纹，差异很小的归为一组，再要求时长接近。缓存命中 \(model.cached) 个。")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 100)
            }

            bottomBar
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.accent)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(model.groups.count) 组疑似重复")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text("勾选要处理的组，点视频卡片可以换保留哪一个")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer(minLength: 6)
        }
        .padding(14)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private func groupCard(_ group: DuplicateScanner.Group) -> some View {
        let checked = model.selected.contains(group.id)
        let keepPath = model.keep[group.id] ?? group.files[0].path

        return VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    if checked {
                        model.selected.remove(group.id)
                    } else {
                        model.selected.insert(group.id)
                    }
                } label: {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(checked ? theme.accent : theme.textTertiary)
                }
                .buttonStyle(.plain)

                Text("\(group.files.count) 个")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text)

                Text("可省 \(Fmt.bytes(group.waste))")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)

                Spacer(minLength: 4)

                if !checked {
                    Text("不处理")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textTertiary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(group.files) { file in
                        fileCard(file, isKeep: file.path == keepPath) {
                            model.keep[group.id] = file.path
                            model.selected.insert(group.id)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(checked ? theme.accent.opacity(0.35) : theme.cardStroke, lineWidth: 1)
        )
        .opacity(checked ? 1 : 0.6)
    }

    private func fileCard(_ file: LocalMediaFile, isKeep: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    VideoThumbnail(path: file.path, width: 132, height: 78, corner: 8)

                    if isKeep {
                        Text("保留")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(theme.accent, in: Capsule())
                            .padding(5)
                    }
                }

                Text(file.name)
                    .font(.system(size: 11.5, weight: isKeep ? .semibold : .regular))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 132, alignment: .leading)

                Text(file.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isKeep ? theme.accent.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isKeep ? theme.accent.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("已选 \(model.selectedGroups.count) 组")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text("可腾出 \(Fmt.bytes(model.totalWaste))")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer()

            Button {
                confirmMerge = true
            } label: {
                Text(model.merging ? "处理中…" : "合并重复")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 42)
                    .background(
                        Capsule().fill(model.selectedGroups.isEmpty
                                       ? Color.gray.opacity(0.35)
                                       : theme.accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(model.selectedGroups.isEmpty || model.merging)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().overlay(theme.cardStroke) }
    }

    private func showToast(_ text: String) {
        guard !text.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if toast == text {
                withAnimation(.easeIn(duration: 0.2)) { toast = nil }
            }
        }
    }
}
