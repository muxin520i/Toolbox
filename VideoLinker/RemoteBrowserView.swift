import SwiftUI

// MARK: - FTP / SFTP 影库
//
// 入口在设置 → 网络存储。和局域网影库分开，是因为账号模型不一样：
// SMB 是「主机 + 共享名」，FTP/SFTP 是「主机 + 端口 + 账号」。
// 播放入口统一走 Router.pending。

// MARK: - 账号列表

struct RemoteLibraryView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var mode: RemoteProtocol = .ftp
    @State private var accounts: [RemoteAccountConfig] = RemoteAccountConfig.load()
    @State private var showAdd = false
    @State private var toast: String?

    private var filtered: [RemoteAccountConfig] {
        accounts.filter { $0.proto == mode }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                VStack(spacing: 0) {
                    Picker("协议", selection: $mode) {
                        ForEach(RemoteProtocol.allCases) { proto in
                            Text(proto.title).tag(proto)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                    Button {
                        showAdd = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 15))
                            Text("添加 \(mode.title) 服务器")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(theme.accent.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)

                    if filtered.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: mode == .ftp ? "network" : "lock.shield")
                                .font(.system(size: 34))
                                .foregroundStyle(theme.textTertiary)
                            Text(mode == .ftp
                                 ? "还没有 FTP 服务器。老 NAS、路由器硬盘盒常见 FTP，端口一般 21。"
                                 : "还没有 SFTP 服务器。VPS、Linux 主机常见 SFTP，端口一般 22。")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textTertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            Section {
                                ForEach(filtered) { account in
                                    NavigationLink {
                                        RemoteBrowseView(config: account,
                                                         path: account.normalizedBasePath,
                                                         pathTitle: account.host)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: account.proto.symbol)
                                                .font(.system(size: 15))
                                                .foregroundStyle(theme.accent)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(account.host)
                                                    .font(.system(size: 14))
                                                    .foregroundStyle(theme.text)
                                                Text("\(account.proto.title) · \(account.effectivePort) · \(account.normalizedBasePath)")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(theme.textTertiary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }
                                .onDelete { indexSet in
                                    let doomed = indexSet.map { filtered[$0] }
                                    for item in doomed {
                                        item.clearPassword()
                                        accounts.removeAll { $0.id == item.id }
                                    }
                                    RemoteAccountConfig.save(accounts)
                                }
                            } header: {
                                Text("已存账号 · 左滑可删除")
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
            .navigationTitle("FTP / SFTP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.navBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(theme.accent)
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            RemoteAddSheet(initialProtocol: mode) { _ in
                accounts = RemoteAccountConfig.load()
            }
        }
    }
}

// MARK: - 目录浏览

struct RemoteBrowseView: View {
    @Environment(\.theme) private var theme

    let config: RemoteAccountConfig
    let path: String
    let pathTitle: String

    @State private var client: RemoteFileSource
    @State private var entries: [RemoteEntry] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var toast: String?

    init(config: RemoteAccountConfig, path: String, pathTitle: String) {
        self.config = config
        self.path = path
        self.pathTitle = pathTitle
        _client = State(initialValue: RemoteFileFactory.make(config: config))
    }

    var body: some View {
        ZStack {
            BackgroundView()

            if loading {
                ProgressView("读取目录…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.orange)
                    Text(errorText)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button {
                        load()
                    } label: {
                        Text("重试")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 34))
                        .foregroundStyle(theme.textTertiary)
                    Text("这个目录是空的")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(entries) { entry in
                            if entry.isContainer {
                                NavigationLink {
                                    RemoteBrowseView(config: config, path: entry.id, pathTitle: entry.title)
                                } label: {
                                    row(entry)
                                }
                            } else {
                                Button {
                                    play(entry)
                                } label: {
                                    row(entry)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        Text("\(entries.count) 项")
                            .font(.system(size: 12))
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
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
        .navigationTitle(pathTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.navBg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            load()
        }
    }

    private func row(_ entry: RemoteEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isContainer ? "folder.fill" : "play.rectangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(entry.isContainer ? Color.orange : theme.accent)
            Text(entry.title)
                .font(.system(size: 14))
                .foregroundStyle(theme.text)
                .lineLimit(2)
            Spacer()
            if let size = entry.size, size > 0 {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func load() {
        loading = true
        errorText = nil
        Task {
            do {
                let list = try await client.list(path: path)
                await MainActor.run {
                    entries = list
                    loading = false
                }
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    loading = false
                }
            }
        }
    }

    private func play(_ entry: RemoteEntry) {
        guard SMBStreamServer.mime(for: entry.title) != nil else {
            toast = "暂不支持这种文件格式"
            return
        }
        toast = "正在准备流媒体…"
        let keep = client
        Task {
            _ = await RemoteStreamServer.shared.start(provider: { keep },
                                                      label: config.proto.title)
            guard let url = RemoteStreamServer.shared.streamURL(for: entry.id) else {
                await MainActor.run { toast = "本地流服务没起来" }
                return
            }
            await MainActor.run {
                toast = nil
                Router.shared.pending = PlayRequest(url: url)
            }
        }
    }
}

// MARK: - 添加账号

struct RemoteAddSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var initialProtocol: RemoteProtocol = .ftp
    var onSaved: (RemoteAccountConfig) -> Void

    @State private var proto: RemoteProtocol = .ftp
    @State private var host = ""
    @State private var portText = ""
    @State private var username = ""
    @State private var password = ""
    @State private var basePath = "/"
    @State private var testing = false
    @State private var errorText: String?
    @State private var hint: String?

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                Form {
                    Section {
                        Picker("协议", selection: $proto) {
                            ForEach(RemoteProtocol.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: proto) { value in
                            portText = ""
                            hint = nil
                            errorText = nil
                        }
                    } header: {
                        Text("连接方式")
                    }

                    Section {
                        TextField("主机，如 192.168.1.5 或 nas.local", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("端口，留空用 \(proto.defaultPort)", text: $portText)
                            .keyboardType(.numberPad)
                        TextField("账号（FTP 匿名留空）", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("密码", text: $password)
                        TextField("初始目录，如 /volume1/video", text: $basePath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("\(proto.title) 服务器")
                    } footer: {
                        Text(proto == .ftp
                             ? "FTP 走被动模式；很多 NAS 默认关着 FTP，要先去控制台打开。"
                             : "SFTP 走 SSH 密码登录，端口一般 22。首次连接会接受服务器指纹。")
                    }

                    if let errorText {
                        Section {
                            Text(errorText)
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                        }
                    }
                    if let hint {
                        Section {
                            Text(hint)
                                .font(.system(size: 12))
                                .foregroundStyle(.green)
                        }
                    }

                    Section {
                        Button {
                            save()
                        } label: {
                            HStack {
                                Spacer()
                                Text(testing ? "正在连接…" : "测试并保存")
                                    .font(.system(size: 15, weight: .semibold))
                                Spacer()
                            }
                        }
                        .disabled(testing || host.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("添加 \(proto.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(theme.accent)
                }
            }
            .onAppear {
                proto = initialProtocol
            }
        }
    }

    private func save() {
        testing = true
        errorText = nil
        hint = nil

        var config = RemoteAccountConfig()
        config.proto = proto
        config.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        config.port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? 0
        config.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        config.basePath = basePath.trimmingCharacters(in: .whitespacesAndNewlines)

        let source = RemoteFileFactory.make(config: config, password: password)
        Task {
            do {
                try await source.verify()
                var list = RemoteAccountConfig.load()
                if let index = list.firstIndex(where: {
                    $0.proto == config.proto && $0.host == config.host && $0.username == config.username
                }) {
                    config.id = list[index].id
                    list[index] = config
                } else {
                    list.append(config)
                }
                config.savedPassword = password
                RemoteAccountConfig.save(list)
                if let ftp = source as? FTPClient { ftp.disconnect() }
                if let sftp = source as? SFTPRemoteClient { await sftp.disconnect() }
                await MainActor.run {
                    onSaved(config)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    testing = false
                    errorText = error.localizedDescription
                }
            }
        }
    }
}
