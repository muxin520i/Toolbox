import SwiftUI
import UIKit

// MARK: - 网络存储（WebDAV）

struct WebDAVView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var config = WebDAVConfig.load()
    @State private var editing = !WebDAVConfig.load().isUsable

    @State private var draftURL = WebDAVConfig.load().baseURL
    @State private var draftUser = WebDAVConfig.load().username
    @State private var draftPass = WebDAVConfig.savedPassword

    @State private var entries: [WebDAVEntry] = []
    @State private var currentPath = ""
    @State private var loading = false
    @State private var errorText: String?
    @State private var connecting = false
    @State private var request: PlayRequest?

    private var client: WebDAVClient {
        WebDAVClient(config: config, password: WebDAVConfig.savedPassword)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                ScrollView {
                    VStack(spacing: 16) {
                        if editing {
                            setupCard
                        } else {
                            browserCard
                        }
                        tipsCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 40)
                }

                if loading || connecting {
                    ProgressView()
                        .tint(theme.accent)
                }
            }
            .navigationTitle("网络存储")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.navBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(theme.accent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !editing {
                        Menu {
                            Button {
                                Task { await reload() }
                            } label: {
                                Label("刷新", systemImage: "arrow.clockwise")
                            }
                            Button {
                                draftURL = config.baseURL
                                draftUser = config.username
                                draftPass = WebDAVConfig.savedPassword
                                editing = true
                            } label: {
                                Label("修改地址", systemImage: "slider.horizontal.3")
                            }
                            Divider()
                            Button(role: .destructive) {
                                WebDAVConfig.clear()
                                config = WebDAVConfig()
                                entries = []
                                currentPath = ""
                                draftURL = ""
                                draftUser = ""
                                draftPass = ""
                                editing = true
                            } label: {
                                Label("断开连接", systemImage: "wifi.slash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(theme.accent)
                        }
                    }
                }
            }
        }
        .onAppear {
            if !editing, entries.isEmpty {
                Task { await reload() }
            }
        }
        .fullScreenCover(item: $request) { req in
            PlayerScreen(request: req)
        }
        .alert("连接失败", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("知道了", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: 配置

    private var setupCard: some View {
        card(title: "连接 WebDAV", icon: "externaldrive.connected.to.line.below") {
            VStack(alignment: .leading, spacing: 12) {
                field(title: "服务器地址", text: $draftURL, placeholder: "https://nas.local:5006/dav", keyboard: .URL)
                field(title: "用户名", text: $draftUser, placeholder: "可选", keyboard: .default)
                secureField(title: "密码", text: $draftPass)

                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Spacer()
                        Text(connecting ? "连接中…" : "连接")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .background(theme.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(connecting || draftURL.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(draftURL.isEmpty ? 0.6 : 1)
            }
        }
    }

    private func field(title: String, text: Binding<String>, placeholder: String, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textTertiary)
            TextField(placeholder, text: text)
                .font(.system(size: 14))
                .foregroundStyle(theme.text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func secureField(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textTertiary)
            SecureField("可选", text: text)
                .font(.system(size: 14))
                .foregroundStyle(theme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: 浏览

    private var browserCard: some View {
        card(title: config.baseURL, icon: "folder.fill") {
            VStack(spacing: 0) {
                if !currentPath.isEmpty {
                    Button {
                        currentPath = parentPath(currentPath)
                        Task { await reload() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                            Text("返回上级")
                                .font(.system(size: 13))
                            Spacer()
                            Text("/" + currentPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .foregroundStyle(theme.accent)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider().overlay(theme.cardStroke)
                }

                if entries.isEmpty {
                    Text(loading ? "正在读取…" : "这个目录里没有文件")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 26)
                } else {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Divider().overlay(theme.cardStroke)
                        }
                        row(entry)
                    }
                }
            }
        }
    }

    private func row(_ entry: WebDAVEntry) -> some View {
        Button {
            if entry.isDirectory {
                currentPath = entry.path
                Task { await reload() }
            } else {
                play(entry)
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: entry.isDirectory ? "folder" : "film")
                    .font(.system(size: 15))
                    .foregroundStyle(entry.isDirectory ? theme.accent : theme.textSecondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    if !entry.isDirectory {
                        Text(subtitle(entry))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                Spacer()

                if !entry.isDirectory {
                    Image(systemName: "play.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !entry.isDirectory {
                Button {
                    play(entry)
                } label: {
                    Label("播放", systemImage: "play.fill")
                }
                Button {
                    copyLink(entry)
                } label: {
                    Label("复制地址", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private func subtitle(_ entry: WebDAVEntry) -> String {
        var parts: [String] = []
        if entry.size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
        }
        if let modified = entry.modified {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy/M/d"
            parts.append(formatter.string(from: modified))
        }
        return parts.joined(separator: " · ")
    }

    private var tipsCard: some View {
        card(title: "说明", icon: "info.circle") {
            VStack(alignment: .leading, spacing: 6) {
                Text("支持群晖、威联通、Nextcloud、坚果云、Alist 这类标准 WebDAV 服务。地址要填到 WebDAV 根目录，例如 https://nas.local:5006/dav。")
                Text("点视频直接播，不用先下载到手机；直播源、m3u8 也能播。")
                Text("密码保存在系统钥匙串里，不会写进配置文件。")
                Text("仅支持 WebDAV。SMB / AFP 需要额外的系统组件，这一版没做。")
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.textTertiary)
            .lineSpacing(3)
        }
    }

    // MARK: 行为

    private func connect() async {
        let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var normalized = URL(string: trimmed) else {
            errorText = WebDAVError.badURL.errorDescription
            return
        }
        if normalized.scheme == nil {
            guard let fixed = URL(string: "https://" + trimmed) else {
                errorText = WebDAVError.badURL.errorDescription
                return
            }
            normalized = fixed
        }

        var draft = WebDAVConfig()
        draft.baseURL = normalized.absoluteString
        draft.username = draftUser.trimmingCharacters(in: .whitespaces)

        connecting = true
        defer { connecting = false }

        let tester = WebDAVClient(config: draft, password: draftPass)
        do {
            _ = try await tester.list(path: "")
            draft.save()
            WebDAVConfig.savedPassword = draftPass
            config = draft
            currentPath = ""
            editing = false
            await reload()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func reload() async {
        guard config.isUsable else { return }
        loading = true
        defer { loading = false }
        do {
            entries = try await client.list(path: currentPath)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            entries = []
        }
    }

    private func play(_ entry: WebDAVEntry) {
        guard let url = try? client.url(for: entry.path, directory: false) else { return }
        let item = PlaybackItem(
            url: url.absoluteString,
            title: entry.name,
            credential: config.username + ":" + WebDAVConfig.savedPassword
        )
        request = PlayRequest(items: [item], startIndex: 0)
    }

    private func copyLink(_ entry: WebDAVEntry) {
        guard let url = try? client.url(for: entry.path, directory: false) else { return }
        UIPasteboard.general.string = url.absoluteString
    }

    private func parentPath(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let range = trimmed.range(of: "/", options: .backwards) else { return "" }
        let parent = String(trimmed[trimmed.startIndex..<range.lowerBound])
        return parent.isEmpty ? "" : parent + "/"
    }

    private func card<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(theme.cardStroke, lineWidth: 1)
        )
    }
}
