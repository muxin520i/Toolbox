import Foundation
import SwiftUI

// MARK: - 回收站
//
// 删文件先挪进 Documents/回收站，记一条 json，7 天后自动清。
// 只挪不拷，同卷 rename 是瞬时的，不占额外空间。

struct TrashEntry: Codable, Identifiable {
    let id: UUID
    /// 原文件名
    let name: String
    /// 回收站里的文件名
    let stored: String
    let originalPath: String
    let size: Int64
    let deletedAt: Date
}

enum TrashStore {

    /// 保留天数
    static let keepDays = 7

    private static let lock = NSLock()

    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("回收站", isDirectory: true)
    }

    private static var indexURL: URL {
        directory.appendingPathComponent("记录.json")
    }

    static func fileURL(for entry: TrashEntry) -> URL {
        directory.appendingPathComponent(entry.stored)
    }

    // MARK: 读取

    static func entries() -> [TrashEntry] {
        lock.lock()
        defer { lock.unlock() }
        return readIndex().sorted { $0.deletedAt > $1.deletedAt }
    }

    static func totalSize() -> Int64 {
        entries().reduce(0) { $0 + $1.size }
    }

    // MARK: 删除

    /// 挪进回收站。文件不存在时返回 false
    @discardableResult
    static func moveToTrash(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }

        lock.lock()
        defer { lock.unlock() }

        ensureDirectory()
        var list = readIndex()

        let stamp = Int(Date().timeIntervalSince1970)
        var stored = "\(stamp)-\(url.lastPathComponent)"
        var index = 1
        while fm.fileExists(atPath: directory.appendingPathComponent(stored).path) {
            stored = "\(stamp)-\(index)-\(url.lastPathComponent)"
            index += 1
        }

        let target = directory.appendingPathComponent(stored)
        do {
            try fm.moveItem(at: url, to: target)
        } catch {
            return false
        }

        let attributes = try? fm.attributesOfItem(atPath: target.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        list.append(
            TrashEntry(
                id: UUID(),
                name: url.lastPathComponent,
                stored: stored,
                originalPath: url.path,
                size: size,
                deletedAt: Date()
            )
        )
        writeIndex(list)
        return true
    }

    // MARK: 还原 / 彻底删

    /// 还原到原来的位置；原位置被占用时改名。返回还原后的地址
    @discardableResult
    static func restore(_ entry: TrashEntry) -> URL? {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        let source = directory.appendingPathComponent(entry.stored)
        guard fm.fileExists(atPath: source.path) else {
            removeFromIndex(entry.id)
            return nil
        }

        let original = URL(fileURLWithPath: entry.originalPath)
        var target = original
        if fm.fileExists(atPath: target.path) {
            target = uniqueURL(for: original)
        }

        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: target)
        } catch {
            return nil
        }

        removeFromIndex(entry.id)
        return target
    }

    static func purge(_ entry: TrashEntry) {
        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.stored))
        removeFromIndex(entry.id)
    }

    static func empty() {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: directory.path) {
            for name in names where name != indexURL.lastPathComponent {
                try? fm.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        writeIndex([])
    }

    /// 超过 7 天的直接清掉
    static func cleanExpired() {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        var list = readIndex()
        let deadline = Date().addingTimeInterval(-Double(keepDays) * 86400)
        var removed = false

        list.removeAll { entry in
            guard entry.deletedAt < deadline else { return false }
            try? fm.removeItem(at: directory.appendingPathComponent(entry.stored))
            removed = true
            return true
        }

        if removed { writeIndex(list) }
    }

    // MARK: 内部

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func readIndex() -> [TrashEntry] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([TrashEntry].self, from: data) else { return [] }
        return list
    }

    private static func writeIndex(_ list: [TrashEntry]) {
        ensureDirectory()
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private static func removeFromIndex(_ id: UUID) {
        var list = readIndex()
        list.removeAll { $0.id == id }
        writeIndex(list)
    }

    private static func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        let base = url.deletingPathExtension()
        let ext = url.pathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base.lastPathComponent) \(index)" : "\(base.lastPathComponent) \(index).\(ext)"
            let candidate = base.deletingLastPathComponent().appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}

// MARK: - 界面

struct TrashView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [TrashEntry] = []
    @State private var confirmEmpty = false
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                if entries.isEmpty {
                    emptyView
                } else {
                    list
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
                            .padding(.bottom, 30)
                    }
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("回收站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空") { confirmEmpty = true }
                        .disabled(entries.isEmpty)
                }
            }
            .confirmationDialog("清空回收站？", isPresented: $confirmEmpty, titleVisibility: .visible) {
                Button("全部删除", role: .destructive) {
                    let count = entries.count
                    TrashStore.empty()
                    load()
                    showToast("已删除 \(count) 个文件")
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("清空后文件就找不回来了")
            }
        }
        .onAppear {
            TrashStore.cleanExpired()
            load()
        }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 10) {
                header

                ForEach(entries) { entry in
                    row(entry)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 40)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            Text("删掉的文件先放这儿，\(TrashStore.keepDays) 天后自动清掉")
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
    }

    private func row(_ entry: TrashEntry) -> some View {
        HStack(spacing: 12) {
            VideoThumbnail(path: TrashStore.fileURL(for: entry).path, width: 58, height: 36, corner: 7)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)

                Text("\(Fmt.bytes(entry.size)) · \(dateText(entry.deletedAt)) 删除")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer(minLength: 6)

            Button {
                restore(entry)
            } label: {
                Text("还原")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(theme.accent.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(11)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
        .contextMenu {
            Button {
                restore(entry)
            } label: {
                Label("还原", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                TrashStore.purge(entry)
                load()
                showToast("已彻底删除")
            } label: {
                Label("彻底删除", systemImage: "trash.slash")
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.textTertiary)
            Text("回收站是空的")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Text("删掉的视频会先放这儿，7 天内都能还原")
                .font(.system(size: 12))
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() {
        entries = TrashStore.entries()
    }

    private func restore(_ entry: TrashEntry) {
        if TrashStore.restore(entry) != nil {
            load()
            showToast("已还原，去「本机视频」里看看")
        } else {
            showToast("还原失败，文件可能已经不在了")
            load()
        }
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if toast == text {
                withAnimation(.easeIn(duration: 0.2)) { toast = nil }
            }
        }
    }
}
