import SwiftUI

// MARK: - 请求头设置页
//
// 只做三件事：开关自动 Referer、改全局 UA、按站点加规则。
// 规则表支持拖动排序，越靠上的规则在同样长度下优先。

struct RequestHeaderView: View {

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = HTTPHeaderStore.shared

    @State private var editing: HeaderRule?
    @State private var isNew = false
    @State private var showingImport = false
    @State private var banner: String?

    var body: some View {
        NavigationStack {
            listBody
        }
    }

    private var listBody: some View {
        List {
            Section {
                Toggle(isOn: $store.autoReferer) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("自动带 Referer")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.text)
                        Text("没配规则时，用视频地址的域名当来源页")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .tint(theme.accent)

                VStack(alignment: .leading, spacing: 6) {
                    Text("默认 User-Agent")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.text)
                    TextField("留空使用内置 iPhone Safari UA", text: $store.userAgent)
                        .font(.system(size: 12, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(.vertical, 2)
            } header: {
                Text("通用")
            } footer: {
                Text("部分站点会按 UA 决定给不给视频，遇到「能打开网页但播放失败」时可以改这里。")
            }

            if let banner {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.accent)
                        Text(banner)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.vertical, 1)
                }
            }

            Section {
                Button {
                    showingImport = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.accent)
                            .frame(width: 20)

                        Text("粘贴导入")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.text)

                        Spacer(minLength: 6)

                        Text("一次加一批")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showingImport) {
                    HeaderRuleImportView { summary in
                        banner = summary.message
                    }
                }

                if store.rules.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("还没有站点规则")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                        Text("遇到 403 / 只给封面不给视频时，点右上角 + 加一条")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(store.rules) { rule in
                        Button {
                            isNew = false
                            editing = rule
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: rule.enabled ? "globe" : "globe.badge.chevron.backward")
                                    .font(.system(size: 14))
                                    .foregroundStyle(rule.enabled ? theme.accent : theme.textTertiary)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(rule.displayHost)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(rule.enabled ? theme.text : theme.textTertiary)
                                        .lineLimit(1)
                                    Text(rule.summary)
                                        .font(.system(size: 11))
                                        .foregroundStyle(theme.textTertiary)
                                }

                                Spacer(minLength: 6)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { indexSet in
                        for index in indexSet where index < store.rules.count {
                            store.delete(store.rules[index])
                        }
                    }
                    .onMove { source, destination in
                        store.move(from: source, to: destination)
                    }
                }
            } header: {
                HStack {
                    Text("站点规则")
                    Spacer()
                    if !store.rules.isEmpty {
                        EditButton()
                            .font(.system(size: 12))
                    }
                }
            } footer: {
                Text("域名支持 example.com 和 *.example.com 两种写法；同时命中多条时，域名更长的生效。")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(BackgroundView())
        .navigationTitle("请求头")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isNew = true
                    editing = HeaderRule()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        }
        .sheet(item: $editing) { rule in
            HeaderRuleEditor(rule: rule, isNew: isNew) { saved in
                if isNew {
                    store.add(saved)
                } else {
                    store.update(saved)
                }
            }
        }
        .task(id: banner) {
            guard banner != nil else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation(.easeOut(duration: 0.2)) { banner = nil }
        }
    }
}

// MARK: - 单条规则编辑

private struct HeaderRuleEditor: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let isNew: Bool
    let onSave: (HeaderRule) -> Void

    @State private var rule: HeaderRule

    init(rule: HeaderRule, isNew: Bool, onSave: @escaping (HeaderRule) -> Void) {
        self.isNew = isNew
        self.onSave = onSave
        _rule = State(initialValue: rule)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("example.com", text: $rule.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("站点域名")
                } footer: {
                    Text("留空表示所有站点。可以只填 bilibili.com，子域名会自动命中。")
                }

                Section {
                    TextField("https://www.example.com/", text: $rule.referer)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.system(size: 13, design: .monospaced))
                } header: {
                    Text("Referer")
                } footer: {
                    Text("多数 403 是缺这个。填视频所在网页的地址，不确定就填站点首页。")
                }

                Section {
                    TextField("SESSDATA=xxx; bili_jct=xxx", text: $rule.cookie)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 13, design: .monospaced))
                } header: {
                    Text("Cookie")
                } footer: {
                    Text("需要登录才给资源的站点才填。Cookie 存在本机，不会上传。")
                }

                Section {
                    TextField("留空沿用全局 UA", text: $rule.userAgent)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 13, design: .monospaced))
                } header: {
                    Text("User-Agent")
                }

                Section {
                    Toggle("启用这条规则", isOn: $rule.enabled)
                        .tint(theme.accent)
                }
            }
            .navigationTitle(isNew ? "新增规则" : "编辑规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(rule)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - 批量导入
//
// 目标是把「加十几条规则」压成两次点击：贴进来，导入。
// 输入框右上角是系统的 PasteButton，点一下直接读剪贴板，不会弹「允许粘贴」。

private struct HeaderRuleImportView: View {

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let onImport: (HeaderRuleImporter.Summary) -> Void

    @State private var text = ""

    private var parsed: (rules: [HeaderRule], skipped: Int) {
        HeaderRuleImporter.parse(text)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("域名 | Referer | Cookie | UA")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)

                    Spacer(minLength: 4)

                    Text("\(parsed.rules.count) 条")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(parsed.rules.isEmpty ? theme.textTertiary : theme.accent)
                }

                editor

                HStack(spacing: 16) {
                    Button {
                        text = HeaderRuleImporter.presetText
                    } label: {
                        Label("填入推荐规则", systemImage: "wand.and.stars")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)

                    if !text.isEmpty {
                        Button {
                            text = ""
                        } label: {
                            Label("清空", systemImage: "trash")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer(minLength: 0)
                }

                Text("后三列可以留空；# 开头是注释行。同一域名会更新已有规则，不会重复添加。")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    let summary = HTTPHeaderStore.shared.importRules(text)
                    onImport(summary)
                    dismiss()
                } label: {
                    Text(parsed.rules.isEmpty ? "没有可导入的规则" : "导入 \(parsed.rules.count) 条")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(theme.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .opacity(parsed.rules.isEmpty ? 0.35 : 1)
                }
                .buttonStyle(.plain)
                .disabled(parsed.rules.isEmpty)
                .padding(.bottom, 4)
            }
            .padding(.horizontal, 20)
            .background(theme.bg.ignoresSafeArea())
            .navigationTitle("粘贴导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.text)
                .scrollContentBackground(.hidden)
                .padding(8)

            if text.isEmpty {
                Text("每行一条，例如：\nbilivideo.com | https://www.bilibili.com/")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }

            PasteButton(payloadType: String.self) { strings in
                if let value = strings.first { text = value }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.capsule)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .topTrailing)
        }
        .frame(maxHeight: .infinity)
        .background(theme.field, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}
