import SwiftUI
import UIKit

extension Notification.Name {
    /// 让嗅探页的内置浏览器打开某个网址
    static let openInBrowser = Notification.Name("vl.openInBrowser")
}

/// 脚本来源地址（直接用内置浏览器打开，页面里点安装由拦截逻辑收进脚本库）
enum ScriptSite {
    /// 国内可直连的 Greasy Fork 镜像（GFork Proxy，走国内 CDN）
    static let mirror = "https://home.greasyfork.org.cn/zh-hans"
    /// 官方站，网络能通时更可靠
    static let official = "https://greasyfork.org/zh-CN/scripts"

    static let greasyFork = mirror
}

// MARK: - 脚本列表

struct UserscriptListView: View {
    @ObservedObject var library: UserscriptLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var editing: Userscript?
    @State private var showLinkInput = false
    @State private var linkText = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.scripts) { script in
                        HStack(spacing: 12) {
                            Button {
                                editing = script
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(script.displayName)
                                        .font(.system(size: 15, weight: .semibold))
                                    Text(script.matchSummary)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Toggle("", isOn: enabledBinding(for: script))
                                .labelsHidden()
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                delete(script)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("已安装")
                } footer: {
                    Text(library.scripts.isEmpty
                         ? "把油猴脚本的代码贴进来，打开匹配的网页就会自动运行。"
                         : "开关打开后，只要网址匹配就会自动执行。改完脚本要重新载入网页才生效。")
                }
            }
            .overlay {
                if library.scripts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "curlybraces")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("还没有脚本")
                            .font(.system(size: 14, weight: .semibold))
                        Text("点右上角 + 新建，或到 Greasy Fork 装一个")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 90)
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("油猴脚本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            editing = Userscript()
                        } label: {
                            Label("新建空白脚本", systemImage: "square.and.pencil")
                        }
                        Button {
                            openGreasyFork(ScriptSite.mirror)
                        } label: {
                            Label("获取新脚本（国内镜像）", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            openGreasyFork(ScriptSite.official)
                        } label: {
                            Label("打开官方站（需网络能通）", systemImage: "globe")
                        }
                        Button {
                            showLinkInput = true
                        } label: {
                            Label("粘贴脚本链接安装", systemImage: "link")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("粘贴脚本链接", isPresented: $showLinkInput) {
                TextField("https://.../xxx.user.js", text: $linkText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("取消", role: .cancel) {}
                Button("安装") { installFromLink() }
            } message: {
                Text("脚本详情页地址或 .user.js 直链都行。")
            }
            .alert("提示", isPresented: messageBinding) {
                Button("知道了", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
            .overlay {
                if busy {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("正在安装…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
            .sheet(item: $editing) { script in
                UserscriptEditorView(script: script) { updated in
                    library.upsert(updated)
                }
            }
        }
    }

    private var messageBinding: Binding<Bool> {
        Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )
    }

    /// 手动粘贴链接兜底：镜像站偶尔把安装按钮做成脚本跳转，拦不到时用这个
    private func installFromLink() {
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme, scheme.hasPrefix("http") else {
            message = "链接要以 https:// 开头"
            return
        }
        guard !busy else { return }
        busy = true

        GreasyForkClient.installFromURL(text) { code, error in
            busy = false
            guard let code = code else {
                message = error ?? "安装失败"
                return
            }
            guard code.lowercased().contains("==userscript==") else {
                message = "这个链接返回的不是脚本代码，试试复制 .user.js 直链"
                return
            }

            let meta = UserscriptParser.parse(code)
            let name = (meta.name?.isEmpty == false ? meta.name! : "未命名脚本")
            var script = Userscript(
                name: name,
                matches: meta.matches.isEmpty ? ["*://*/*"] : meta.matches,
                code: code,
                enabled: true,
                documentStart: meta.documentStart
            )
            if let existing = library.scripts.first(where: { $0.name == name }) {
                script.id = existing.id
            }
            library.upsert(script)
            message = "已安装「\(script.displayName)」，回到嗅探页刷新一下即可生效。"
        }
    }

    /// 关掉脚本页，直接用内置浏览器打开 Greasy Fork 镜像，点安装就能收进脚本库
    private func openGreasyFork(_ url: String) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(name: .openInBrowser, object: url)
        }
    }

    private func enabledBinding(for script: Userscript) -> Binding<Bool> {
        Binding(
            get: { library.scripts.first(where: { $0.id == script.id })?.enabled ?? false },
            set: { newValue in
                library.setEnabled(newValue, for: script)
            }
        )
    }

    /// 按 id 删除，避免索引错位导致的崩溃
    private func delete(_ script: Userscript) {
        library.remove(script)
    }
}

// MARK: - 脚本编辑

struct UserscriptEditorView: View {
    @State private var draft: Userscript
    @State private var matchText: String
    @State private var showPasteHint = false

    let onSave: (Userscript) -> Void
    @Environment(\.dismiss) private var dismiss

    init(script: Userscript, onSave: @escaping (Userscript) -> Void) {
        _draft = State(initialValue: script)
        _matchText = State(initialValue: script.matches.joined(separator: "\n"))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("例如：视频网站去广告", text: $draft.name)
                }

                Section {
                    TextEditor(text: $matchText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 62)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("生效的网址")
                } footer: {
                    Text("一行一条，可以用 * 通配。例如 *://*.bilibili.com/* 表示该站所有页面。")
                }

                Section {
                    Toggle("页面一打开就执行", isOn: $draft.documentStart)
                } footer: {
                    Text("关闭时等页面结构准备好再执行，对应 @run-at document-end，大多数脚本用这个。")
                }

                Section {
                    TextEditor(text: $draft.code)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 260)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    HStack {
                        Text("脚本代码")
                        Spacer()
                        Button("从剪贴板粘贴") { paste() }
                            .font(.system(size: 12, weight: .semibold))
                    }
                } footer: {
                    Text("把油猴脚本完整贴进来，开头的 ==UserScript== 注释会被自动识别，名称和网址规则会帮你填好。")
                }
            }
            .navigationTitle(draft.name.isEmpty ? "新建脚本" : "编辑脚本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { commit() }
                        .fontWeight(.semibold)
                }
            }
            .alert("剪贴板是空的", isPresented: $showPasteHint) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("先复制脚本代码，再回来点一次。")
            }
        }
    }

    private func paste() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showPasteHint = true
            return
        }

        let meta = UserscriptParser.parse(text)
        draft.code = text
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty, let name = meta.name {
            draft.name = name
        }
        if !meta.matches.isEmpty {
            matchText = meta.matches.joined(separator: "\n")
        }
        if meta.documentStart {
            draft.documentStart = true
        }
    }

    private func commit() {
        var output = draft
        let list = matchText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        output.matches = list.isEmpty ? ["*://*/*"] : list
        if output.name.trimmingCharacters(in: .whitespaces).isEmpty {
            output.name = "未命名脚本"
        }
        output.updatedAt = Date()
        onSave(output)
        dismiss()
    }
}
