import SwiftUI

// MARK: - 定时巡检

struct PatrolView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @ObservedObject private var store = PatrolStore.shared

    @State private var editing: PatrolTask?
    @State private var isNewTask = false
    @State private var toast: String?
    @State private var runningID: UUID?

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                ScrollView {
                    VStack(spacing: 14) {
                        if store.tasks.isEmpty {
                            emptyView
                        } else {
                            ForEach(store.tasks) { task in
                                taskCard(task)
                            }
                        }

                        noteCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 40)
                }

                if let toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.78), in: Capsule())
                            .padding(.bottom, 28)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("定时巡检")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isNewTask = true
                        editing = PatrolTask(name: "", pageURL: "")
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { task in
                PatrolEditView(task: task, isNew: isNewTask) { saved in
                    if isNewTask {
                        store.add(saved)
                        showToast("已添加")
                    } else {
                        store.update(saved)
                        showToast("已保存")
                    }
                }
            }
            .task {
                store.scheduleBackground()
            }
        }
    }

    private func taskCard(_ task: PatrolTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.name.isEmpty ? task.host : task.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Text(task.pageURL)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Toggle("", isOn: Binding(
                    get: { task.enabled },
                    set: { _ in store.toggle(task) }
                ))
                .labelsHidden()
                .tint(theme.accent)
                .scaleEffect(0.85)
            }

            HStack(spacing: 8) {
                chip(task.intervalText)
                if !task.keyword.isEmpty {
                    chip("含「\(task.keyword)」")
                }
                chip(task.statusText)
            }

            if let message = task.lastMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    run(task)
                } label: {
                    HStack(spacing: 5) {
                        if runningID == task.id {
                            ProgressView().tint(theme.accent).scaleEffect(0.7)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(runningID == task.id ? "运行中…" : "立即运行")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(runningID != nil)

                Button {
                    isNewTask = false
                    editing = task
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 44, height: 36)
                        .background(theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    store.remove(task)
                    showToast("已删除")
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 44, height: 36)
                        .background(theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(15)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
        .opacity(task.enabled ? 1 : 0.62)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(theme.textTertiary)
            Text("还没有巡检任务")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Text("点右上角加一个追更的页面，之后有新视频会自动进下载队列")
                .font(.system(size: 12))
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .padding(.vertical, 40)
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text("说明")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text)
            }

            bullet("后台由系统按使用习惯安排，通常几小时内会跑一次，不保证准时")
            bullet("想立刻看结果就点「立即运行」，走的是同一个抓取逻辑")
            bullet("只认页面里直接写出来的 mp4 / m3u8 地址，需要登录或加密的源抓不到")
            bullet("同一条地址只会下一次，之后不再重复入队")
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.field, in: Capsule())
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(theme.textTertiary)
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func run(_ task: PatrolTask) {
        guard runningID == nil else { return }
        runningID = task.id
        Task {
            let message = await store.run(task)
            runningID = nil
            showToast(message)
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation { toast = nil }
        }
    }
}

// MARK: - 新增 / 编辑

struct PatrolEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var draft: PatrolTask
    private let isNew: Bool
    private let onSave: (PatrolTask) -> Void

    @State private var errorText: String?

    init(task: PatrolTask, isNew: Bool, onSave: @escaping (PatrolTask) -> Void) {
        _draft = State(initialValue: task)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                ScrollView {
                    VStack(spacing: 16) {
                        fieldCard

                        VStack(alignment: .leading, spacing: 8) {
                            Text("检查间隔")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(theme.textSecondary)

                            HStack(spacing: 8) {
                                ForEach(intervalOptions, id: \.value) { option in
                                    Button {
                                        draft.intervalHours = option.value
                                    } label: {
                                        Text(option.title)
                                            .font(.system(size: 13, weight: draft.intervalHours == option.value ? .semibold : .regular))
                                            .foregroundStyle(draft.intervalHours == option.value ? .white : theme.textSecondary)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 38)
                                            .background(
                                                draft.intervalHours == option.value
                                                    ? AnyShapeStyle(theme.gradient)
                                                    : AnyShapeStyle(theme.field),
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(theme.cardStroke, lineWidth: 1)
                        )

                        Toggle(isOn: $draft.enabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("启用")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(theme.text)
                                Text("关掉后后台不会再跑这个任务")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                        .tint(theme.accent)
                        .padding(16)
                        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(theme.cardStroke, lineWidth: 1)
                        )

                        if let errorText {
                            Text(errorText)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color(red: 0.95, green: 0.36, blue: 0.36))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle(isNew ? "新建巡检" : "编辑巡检")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var fieldCard: some View {
        VStack(spacing: 0) {
            inputRow("名称", placeholder: "比如「某站更新」", text: $draft.name)
            Divider().overlay(theme.cardStroke)
            inputRow("页面地址", placeholder: "https://", text: $draft.pageURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
            Divider().overlay(theme.cardStroke)
            inputRow("关键字（可选）", placeholder: "只下地址里含这个词的", text: $draft.keyword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private func inputRow(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.textTertiary)
            TextField(placeholder, text: text)
                .font(.system(size: 14))
                .foregroundStyle(theme.text)
        }
        .padding(.vertical, 11)
    }

    private var intervalOptions: [(title: String, value: Int)] {
        [("6 小时", 6), ("12 小时", 12), ("每天", 24), ("3 天", 72)]
    }

    private func save() {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var url = draft.pageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            errorText = "页面地址不能为空"
            return
        }
        if !url.lowercased().hasPrefix("http://"), !url.lowercased().hasPrefix("https://") {
            url = "https://" + url
        }
        guard let parsed = URL(string: url), parsed.host != nil else {
            errorText = "地址格式不对"
            return
        }

        draft.name = name.isEmpty ? (parsed.host ?? "巡检任务") : name
        draft.pageURL = url
        draft.keyword = draft.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(draft)
        dismiss()
    }
}
