import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 本机视频

/// 扫描 App 文件夹里的视频，或者从「文件」App 导入。
/// 列表分两段：还没进过列表的在前，已经在播放列表里的在后，避免重复添加
struct LocalMediaView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @ObservedObject private var downloads = DownloadManager.shared

    @State private var files: [LocalMediaFile] = []
    /// 已经在某个播放列表里的文件路径。只认播放列表，不认下载记录——
    /// 下载记录里有、列表里没有的那些，必须还能点「+」加进去，否则会卡成死结
    @State private var known: Set<String> = []
    @State private var scanning = true
    @State private var importing = false
    @State private var importNote: String?
    @State private var toast: String?
    @State private var request: PlayRequest?
    @State private var showPicker = false

    private var freshFiles: [LocalMediaFile] {
        files.filter { !known.contains($0.path) }
    }

    private var addedFiles: [LocalMediaFile] {
        files.filter { known.contains($0.path) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()
                content
            }
            .navigationTitle("本机视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            reload()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .disabled(scanning || importing)

                        Button {
                            presentImporter()
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .disabled(importing)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !freshFiles.isEmpty {
                    footer
                }
            }
        }
        .onAppear(perform: reload)
        .fullScreenCover(item: $request) { req in
            PlayerScreen(request: req)
        }
        .sheet(isPresented: $showPicker) {
            DocumentPickerSheet(
                contentTypes: [.movie, .video, .audio, .data],
                onPick: { urls in
                    showPicker = false
                    handlePicked(urls)
                },
                onCancel: { failed in
                    showPicker = false
                    if failed {
                        showToast("系统选择器没能打开，试试底部「去「文件」App」")
                    }
                }
            )
            .presentationDetents([.height(1)])
            .presentationDragIndicator(.hidden)
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .padding(.bottom, freshFiles.isEmpty ? 26 : 78)
                    .transition(.opacity)
            }
        }
        .overlay {
            if importing {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text(importNote ?? "正在导入…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.8))
                )
                .transition(.opacity)
            }
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if scanning {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在扫描…")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if files.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !freshFiles.isEmpty {
                        section(title: "发现 \(freshFiles.count) 个", items: freshFiles)
                    }
                    if !addedFiles.isEmpty {
                        section(title: "已在列表 \(addedFiles.count) 个", items: addedFiles)
                    }
                    folderHint
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 30)
            }
        }
    }

    private func section(title: String, items: [LocalMediaFile]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.path) { index, file in
                    row(file)
                    if index < items.count - 1 {
                        Divider().overlay(theme.cardStroke).padding(.leading, 88)
                    }
                }
            }
            .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.cardStroke, lineWidth: 1)
            )
        }
    }

    private func row(_ file: LocalMediaFile) -> some View {
        HStack(spacing: 12) {
            VideoThumbnail(path: file.path, width: 64, height: 40, corner: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(file.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text(file.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if known.contains(file.path) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(theme.accent.opacity(0.85))
                    .frame(width: 34, height: 34)
            } else {
                Button {
                    add(file)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(theme.accent)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { play(file) }
        .contextMenu {
            Button {
                play(file)
            } label: {
                Label("播放", systemImage: "play.fill")
            }
            if !known.contains(file.path) {
                Button {
                    add(file)
                } label: {
                    Label("加入播放列表", systemImage: "text.badge.plus")
                }
            }
            Button {
                MediaExporter.exportToFiles([file.url])
            } label: {
                Label("导出到「文件」", systemImage: "folder.badge.plus")
            }
            Button {
                UIPasteboard.general.string = file.path
                showToast("路径已复制")
            } label: {
                Label("复制文件路径", systemImage: "doc.on.doc")
            }
        }
    }

    private var footer: some View {
        Button {
            addAll()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 14, weight: .bold))
                Text(importing ? "正在处理…" : "全部加入播放列表（\(freshFiles.count)）")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(theme.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 20)
        }
        .buttonStyle(.plain)
        .disabled(importing)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(theme.textTertiary)

            Text("还没扫到视频文件")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.text)

            VStack(alignment: .leading, spacing: 8) {
                bullet("点右上角「导入」，从「文件」App 里挑视频，可以一次选多个")
                bullet("打开「文件」App → 我的 iPhone → VideoLinker，把视频拖进这个文件夹")
                bullet("电脑上用 Finder 或 iTunes 的文件共享，也能直接拖进来")
            }
            .padding(.top, 2)

            Button {
                presentImporter()
            } label: {
                Text("从「文件」导入")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 42)
                    .background(theme.gradient, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(theme.textTertiary)
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var folderHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                Text("文件夹路径：「文件」App → 我的 iPhone → VideoLinker")
                    .font(.system(size: 11))
            }
            .foregroundStyle(theme.textTertiary)

            Button {
                openFilesApp()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .semibold))
                    Text("选择器打不开？直接去「文件」App 把视频拖进来")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 4)
    }

    private func openFilesApp() {
        guard let url = URL(string: "shareddocuments://") else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok {
                showToast("手动打开「文件」App → 我的 iPhone → VideoLinker")
            }
        }
    }

    // MARK: 动作

    private func reload() {
        scanning = true
        Task { @MainActor in
            let list = await LocalMedia.scan()

            // 先把「下载记录里有、播放列表里却没有」的补回「下载」列表。
            // 老版本有段时间下载完成没登记进列表，这些文件在界面上会显示成
            // 「已在列表」，用户点不到「+」，也就永远加不进去，只能这样兜一次
            let orphans = downloads.items.compactMap { item -> (path: String, title: String)? in
                let path = item.localPath
                guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
                return (path, (item.fileName as NSString).deletingPathExtension)
            }
            let repaired = PlaylistStore.reconcileDownloads(orphans)

            // 只认播放列表：下载记录里有的、列表里没有的，还得能加
            let inLists = Set(PlaylistStore.load().flatMap { $0.items.compactMap { $0.localPath } })

            withAnimation(.easeInOut(duration: 0.18)) { files = list }
            known = inLists
            scanning = false
            if repaired > 0 {
                showToast("已把 \(repaired) 个已下载的视频补回「下载」列表")
            }
        }
    }

    private func play(_ file: LocalMediaFile) {
        request = PlayRequest(
            items: [PlaybackItem(url: file.url.absoluteString, title: file.title)],
            startIndex: 0
        )
    }

    private func add(_ file: LocalMediaFile) {
        DownloadManager.shared.importFile(at: file.url)
        if let list = PlaylistStore.attachDownload(path: file.path, title: file.title) {
            showToast("已加入「\(list.name)」")
        } else {
            showToast("已加入播放列表")
        }
        withAnimation(.easeInOut(duration: 0.18)) { known.insert(file.path) }
    }

    private func addAll() {
        let targets = freshFiles
        guard !targets.isEmpty else { return }
        importing = true
        for file in targets {
            DownloadManager.shared.importFile(at: file.url)
            PlaylistStore.attachDownload(path: file.path, title: file.title)
            known.insert(file.path)
        }
        importing = false
        showToast("已加入 \(targets.count) 个视频")
    }

    private func handlePicked(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importing = true
        importNote = urls.count == 1
            ? "正在导入 \(urls[0].lastPathComponent)"
            : "正在导入 \(urls.count) 个文件"

        Task {
            let outcome = await LocalMedia.importFiles(urls)
            await MainActor.run {
                importing = false
                importNote = nil
                showToast(summary(of: outcome))
                reload()
            }
        }
    }

    private func summary(of outcome: LocalMedia.ImportOutcome) -> String {
        if outcome.isEmpty { return "没有可导入的文件" }
        if outcome.added > 0 {
            var text = "已导入 \(outcome.added) 个"
            if outcome.skipped > 0 { text += "，\(outcome.skipped) 个已在列表" }
            if outcome.failed > 0 { text += "，\(outcome.failed) 个读不出来" }
            return text
        }
        if outcome.skipped > 0 && outcome.failed == 0 {
            return "这些视频已经在列表里了"
        }
        if outcome.skipped > 0 {
            return "\(outcome.skipped) 个已在列表，\(outcome.failed) 个读不出来"
        }
        return "读不出来，试试先把它下载到本机"
    }

    private func presentImporter() {
        // ts / m2ts / flv 这些没有标准的 UTType，用 .data 兜住，导入时再按后缀过滤
        showPicker = true
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if toast == text {
                withAnimation(.easeIn(duration: 0.2)) { toast = nil }
            }
        }
    }
}
