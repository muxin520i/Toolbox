import SwiftUI
import UIKit

// MARK: - 备忘录列表

struct MemoListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @ObservedObject private var store = MemoStore.shared

    @State private var keyword = ""
    @State private var editing: MemoEditTarget?
    @State private var pendingDelete: PendingMemoDelete?
    @State private var undoTask: DispatchWorkItem?
    @State private var toast: String?

    private var filtered: [Memo] {
        let text = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return store.items }
        return store.items.filter { $0.text.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                if store.items.isEmpty {
                    emptyState
                } else if filtered.isEmpty {
                    searchEmptyState
                } else {
                    list
                }

                if let toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.black.opacity(0.82)))
                            .padding(.bottom, pendingDelete == nil ? 26 : 74)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .navigationTitle("备忘录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.navBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .searchable(
                text: $keyword,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索备忘"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editing = MemoEditTarget(memo: nil)
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let pendingDelete {
                    undoBar(pendingDelete.memo)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // 进后台就别留着待撤销的条目，回来时已经过期了
            clearPendingDelete()
        }
        .sheet(item: $editing) { target in
            MemoEditorView(memo: target.memo)
        }
    }

    // MARK: 列表

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(keyword.isEmpty ? "\(store.items.count) 条备忘" : "找到 \(filtered.count) 条")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    Text("· 只存在本机")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)

                ForEach(filtered) { memo in
                    row(memo)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 30)
        }
    }

    private func row(_ memo: Memo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.accent.opacity(0.13))
                    .frame(width: 38, height: 38)
                Image(systemName: memo.linkCount > 0 ? "link" : "note.text")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(memo.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)

                if !memo.preview.isEmpty {
                    Text(memo.preview)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 6) {
                    Text(memo.dateText)
                    if memo.linkCount > 0 {
                        Circle()
                            .fill(theme.textTertiary)
                            .frame(width: 3, height: 3)
                        Label("\(memo.linkCount) 个链接", systemImage: "link")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(theme.textTertiary)
                .padding(.top, 1)
            }

            Spacer(minLength: 2)

            Menu {
                Button {
                    editing = MemoEditTarget(memo: memo)
                } label: {
                    Label("编辑", systemImage: "pencil")
                }

                Button {
                    copy(memo.text, note: "已复制全文")
                } label: {
                    Label("复制全文", systemImage: "doc.on.doc")
                }

                if !memo.links.isEmpty {
                    Button {
                        copy(memo.links.joined(separator: "\n"), note: "已复制 \(memo.links.count) 个链接")
                    } label: {
                        Label("只复制链接", systemImage: "link")
                    }
                }

                ShareLink(item: memo.text) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }

                Divider()

                Button(role: .destructive) {
                    delete(memo)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
        }
        .padding(13)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { editing = MemoEditTarget(memo: memo) }
        .contextMenu {
            Button {
                copy(memo.text, note: "已复制全文")
            } label: {
                Label("复制全文", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                delete(memo)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: 空状态

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "note.text")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(theme.textTertiary)

            Text("还没有备忘")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.text)

            Text("点右上角新建，把链接、账号、临时记的东西粘进来。\n内容只保存在本机，覆盖安装不会丢。")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Button {
                editing = MemoEditTarget(memo: nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                    Text("新建备忘")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .frame(height: 42)
                .background(theme.gradient, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(theme.textTertiary)
            Text("没有找到相关备忘")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 撤销条

    private func undoBar(_ memo: Memo) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Text("已删除「\(memo.title)」")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("撤销") {
                undoDelete()
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.accent)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: 动作

    private func copy(_ text: String, note: String) {
        UIPasteboard.general.string = text
        showToast(note)
    }

    private func delete(_ memo: Memo) {
        guard let index = store.items.firstIndex(where: { $0.id == memo.id }) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            store.remove(memo)
            pendingDelete = PendingMemoDelete(memo: memo, index: index)
        }

        undoTask?.cancel()
        let pending = pendingDelete
        let task = DispatchWorkItem {
            guard pendingDelete?.id == pending?.id else { return }
            withAnimation(.easeIn(duration: 0.2)) { pendingDelete = nil }
        }
        undoTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: task)
    }

    private func undoDelete() {
        undoTask?.cancel()
        undoTask = nil
        guard let pending = pendingDelete else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            store.insert(pending.memo, at: pending.index)
            pendingDelete = nil
        }
        showToast("已恢复")
    }

    private func clearPendingDelete() {
        undoTask?.cancel()
        undoTask = nil
        pendingDelete = nil
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

// MARK: - 新建 / 编辑

struct MemoEditorView: View {
    let memo: Memo?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @ObservedObject private var store = MemoStore.shared

    @State private var text: String
    @State private var confirmDiscard = false
    @FocusState private var focused: Bool

    init(memo: Memo?) {
        self.memo = memo
        _text = State(initialValue: memo?.text ?? "")
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var changed: Bool {
        trimmed != (memo?.text ?? "")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                VStack(spacing: 10) {
                    editor
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
            .navigationTitle(memo == nil ? "新建备忘" : "编辑备忘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.navBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if changed {
                            confirmDiscard = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .font(.system(size: 15, weight: .semibold))
                        .disabled(trimmed.isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button {
                        pasteClipboard()
                    } label: {
                        Label("粘贴", systemImage: "doc.on.clipboard")
                    }
                    Spacer()
                    Button("完成") { focused = false }
                }
            }
            .onAppear {
                if memo == nil { focused = true }
            }
            .interactiveDismissDisabled(changed)
            .confirmationDialog("放弃这次修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("放弃", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) {}
            }
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .focused($focused)
                .font(.system(size: 15))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10)
                .padding(.vertical, 12)

            if text.isEmpty {
                Text("把链接、账号、临时要记的东西粘在这里……\n\n一行一条也不会乱，右上角保存。")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textTertiary)
                    .lineSpacing(3)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 20)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(countText)
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)

            Spacer()

            Button {
                pasteClipboard()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11, weight: .semibold))
                    Text("粘贴剪贴板")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    private var countText: String {
        var parts = ["\(text.count) 字"]
        let linkCount = links.count
        if linkCount > 0 {
            parts.append("\(linkCount) 个链接")
        }
        if text.count > 20000 {
            parts.append("超出 20000 字会被截断")
        }
        return parts.joined(separator: " · ")
    }

    private var links: [String] {
        Memo(text: text).links
    }

    private func pasteClipboard() {
        guard let value = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = value
        } else if text.hasSuffix("\n") {
            text += value
        } else {
            text += "\n" + value
        }
        focused = true
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        if let memo {
            if changed {
                store.update(memo, text: trimmed)
            }
        } else {
            store.add(trimmed)
        }
        dismiss()
    }
}

// MARK: - 辅助类型

private struct MemoEditTarget: Identifiable {
    let id = UUID()
    let memo: Memo?
}

private struct PendingMemoDelete: Identifiable {
    let id = UUID()
    let memo: Memo
    let index: Int
}
