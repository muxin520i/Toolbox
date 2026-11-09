import SwiftUI
import UniformTypeIdentifiers

// MARK: - 压缩包工具页
//
// 第一屏：App 下载目录里已有的压缩包 + 「从文件 App 选一个」
// 第二屏：包内容列表，顶部「全部解压」，解压到 Documents/Downloads/解压/<包名>

/// sheet(item:) 要求 Identifiable，URL 不满足，包一层
struct PickedArchive: Identifiable {
    let id = UUID()
    let url: URL
}

struct ArchiveView: View {
    @Environment(\.theme) private var theme

    @State private var archives: [URL] = ArchiveStore.archivesInApp()
    @State private var showPicker = false
    @State private var showCreate = false
    @State private var picked: PickedArchive?
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                VStack(spacing: 0) {
                    importButton

                    if archives.isEmpty {
                        emptyHint
                    } else {
                        List {
                            Section {
                                ForEach(archives, id: \.path) { url in
                                    NavigationLink {
                                        ArchiveDetailView(archive: url)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "doc.zipper")
                                                .font(.system(size: 15))
                                                .foregroundStyle(theme.accent)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(url.lastPathComponent)
                                                    .font(.system(size: 14))
                                                    .foregroundStyle(theme.text)
                                                Text(Self.sizeText(url))
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(theme.textTertiary)
                                            }
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }
                            } header: {
                                Text("App 里的压缩包（下载目录）")
                                    .font(.system(size: 12))
                            }
                        }
                        .listStyle(.insetGrouped)
                        .scrollContentBackground(.hidden)
                    }
                }

                if let toast {
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
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("压缩包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.navBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .sheet(isPresented: $showPicker) {
            DocumentPickerSheet(contentTypes: Self.archiveTypes, allowsMultiple: false) { urls in
                showPicker = false
                guard let url = urls.first else { return }
                picked = PickedArchive(url: url)
            } onCancel: { failed in
                showPicker = false
                if failed {
                    toast = "文件选择器没弹出来，稍后再试"
                }
            }
        }
        .sheet(item: $picked) { picked in
            NavigationStack {
                ArchiveDetailView(archive: picked.url)
            }
        }
        .sheet(isPresented: $showCreate) {
            ZipCreateSheet { url in
                archives = ArchiveStore.archivesInApp()
                toast = "已打包：\(url.lastPathComponent)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if toast?.contains("已打包") == true { toast = nil }
                }
            }
        }
        .onAppear {
            archives = ArchiveStore.archivesInApp()
        }
    }

    private var importButton: some View {
        HStack(spacing: 10) {
            Button {
                showCreate = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc.zipper")
                        .font(.system(size: 14, weight: .semibold))
                    Text("新建压缩包")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                showPicker = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                        .font(.system(size: 14, weight: .semibold))
                    Text("从文件 App 选")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 34))
                .foregroundStyle(theme.textTertiary)
            Text("还没有压缩包")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.text)
            Text("支持 zip、tar、tar.gz。rar 和 7z 暂不支持，请先在电脑上解压")
                .font(.system(size: 12))
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func sizeText(_ url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static var archiveTypes: [UTType] {
        var types: [UTType] = []
        for ext in ["zip", "tar", "tgz", "gz"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types.isEmpty ? [.data] : types
    }
}

// MARK: - 包内容页

struct ArchiveDetailView: View {
    @Environment(\.theme) private var theme

    let archive: URL

    @State private var entries: [ArchiveEntryItem]?
    @State private var errorText: String?
    @State private var extracting = false
    @State private var progress: Double = 0
    @State private var toast: String?

    private var totalSize: Int64 {
        entries?.reduce(0) { $0 + $1.size } ?? 0
    }

    private var totalCount: Int {
        entries?.filter { !$0.isDirectory }.count ?? 0
    }

    var body: some View {
        ZStack {
            BackgroundView()

            VStack(spacing: 0) {
                if let errorText {
                    errorHint(errorText)
                } else if let entries {
                    if entries.isEmpty {
                        emptyBody
                    } else {
                        summaryBar
                        contentList(entries)
                    }
                } else {
                    ProgressView("读取中…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if extracting {
                    extractingBar
                }
            }

            if let toast {
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
                .allowsHitTesting(false)
            }
        }
        .navigationTitle(archive.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.navBg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            load()
        }
    }

    // MARK: 内容

    private func load() {
        do {
            entries = try ArchiveStore.shared.list(url: archive)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private var summaryBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(totalCount) 个文件")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.text)
                Text("共 \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer()

            Button {
                extractAll()
            } label: {
                Text("全部解压")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(extracting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func contentList(_ items: [ArchiveEntryItem]) -> some View {
        List {
            Section {
                ForEach(items) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(entry.isDirectory ? Color.orange : theme.textTertiary)
                        Text(entry.path)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.text)
                            .lineLimit(2)
                        Spacer()
                        if !entry.isDirectory {
                            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("包内内容")
                    .font(.system(size: 12))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var emptyBody: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 34))
                .foregroundStyle(theme.textTertiary)
            Text("这个包是空的")
                .font(.system(size: 14))
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorHint(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Color.orange)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var extractingBar: some View {
        VStack(spacing: 10) {
            ProgressView(value: progress)
                .tint(theme.accent)
            Text(progress >= 1 ? "收尾中…" : "解压中 \(Int(progress * 100))%")
                .font(.system(size: 12))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: 解压

    private func extractAll() {
        guard !extracting else { return }
        extracting = true
        progress = 0
        let dest = ArchiveStore.extractDirectory(for: archive)
        Task {
            do {
                try await ArchiveStore.shared.extract(url: archive, to: dest) { p in
                    Task { @MainActor in
                        progress = p
                    }
                }
                extracting = false
                toast = "已解压到 下载/解压/\(dest.lastPathComponent)"
            } catch {
                extracting = false
                toast = error.localizedDescription
            }
        }
    }
}

// MARK: - 新建压缩包

/// 从下载目录里挑文件打包，可选传统 zip 密码。
/// 输出放在同一个下载目录，回到压缩包页立刻能看到。
struct ZipCreateSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var onCreated: (URL) -> Void

    @State private var files: [URL] = []
    @State private var selected: Set<String> = []
    @State private var name = ""
    @State private var password = ""
    @State private var working = false
    @State private var done = 0
    @State private var total = 0
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                Form {
                    Section {
                        TextField("压缩包名字", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("文件名")
                    } footer: {
                        Text("不用写 .zip，会自动补上；同名会自动加序号。")
                    }

                    Section {
                        if files.isEmpty {
                            Text("下载目录里还没有文件，先下点东西再来打包。")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textTertiary)
                        } else {
                            ForEach(files, id: \.path) { file in
                                Button {
                                    toggle(file)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: selected.contains(file.path)
                                              ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 17))
                                            .foregroundStyle(selected.contains(file.path)
                                                             ? theme.accent : theme.textTertiary)

                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(file.lastPathComponent)
                                                .font(.system(size: 13))
                                                .foregroundStyle(theme.text)
                                                .lineLimit(1)
                                            Text(Self.sizeText(file))
                                                .font(.system(size: 11))
                                                .foregroundStyle(theme.textTertiary)
                                        }

                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        HStack {
                            Text("选择文件")
                            Spacer()
                            Button(selected.count == files.count && !files.isEmpty ? "取消全选" : "全选") {
                                if selected.count == files.count && !files.isEmpty {
                                    selected.removeAll()
                                } else {
                                    selected = Set(files.map(\.path))
                                }
                            }
                            .font(.system(size: 12))
                            .disabled(files.isEmpty)
                        }
                    }

                    Section {
                        SecureField("密码（可选）", text: $password)
                    } header: {
                        Text("加密")
                    } footer: {
                        Text("留空则不加密。加密后的 zip 用系统解压、Windows 资源管理器都能打开；这只是防止随手翻看，不是强加密。")
                    }

                    if working {
                        Section {
                            ProgressView(value: Double(done), total: Double(max(total, 1)))
                                .tint(theme.accent)
                            Text(done >= total ? "收尾中…" : "正在打包 \(done)/\(total)")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }

                    if let errorText {
                        Section {
                            Text(errorText)
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("新建压缩包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? "打包中…" : "打包") { create() }
                        .disabled(working || selected.isEmpty)
                }
            }
        }
        .onAppear {
            files = Self.sourceFiles()
            if name.isEmpty { name = Self.defaultName() }
        }
    }

    private func toggle(_ file: URL) {
        if selected.contains(file.path) {
            selected.remove(file.path)
        } else {
            selected.insert(file.path)
        }
    }

    private func create() {
        let list = files.filter { selected.contains($0.path) }
        guard !list.isEmpty else { return }

        var clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { clean = Self.defaultName() }
        if !clean.lowercased().hasSuffix(".zip") { clean += ".zip" }
        let output = Self.uniqueURL(named: clean)

        working = true
        errorText = nil
        done = 0
        total = list.count
        let pwd = password

        Task.detached(priority: .userInitiated) {
            do {
                let writer = ZipWriter(output: output, password: pwd.isEmpty ? nil : pwd)
                for (index, file) in list.enumerated() {
                    try writer.addFile(at: file)
                    await MainActor.run { done = index + 1 }
                }
                try writer.finish()
                await MainActor.run {
                    working = false
                    onCreated(output)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    working = false
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private static func sourceFiles() -> [URL] {
        let fm = FileManager.default
        let dir = DownloadManager.directory()
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return [] }

        return files
            .filter {
                guard let values = try? $0.resourceValues(forKeys: [.isRegularFileKey]) else { return false }
                return values.isRegularFile == true
            }
            .filter { $0.lastPathComponent != ".DS_Store" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func sizeText(_ url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return "—" }
        let size = values.fileSize ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private static func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd-HHmm"
        return "打包-\(formatter.string(from: Date()))"
    }

    private static func uniqueURL(named name: String) -> URL {
        let dir = DownloadManager.directory()
        var url = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return url }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(index).\(ext)")
            index += 1
        }
        return url
    }
}
