import SwiftUI

// MARK: - 局域网影库
//
// 两个来源：
//   DLNA 媒体服务器 —— SSDP 自动发现，浏览目录直接播（NAS 都支持）
//   SMB 共享 —— 手动填主机 / 共享名 / 账号，浏览 + 本地流代理播放
//
// 播放入口统一走 Router.pending，和其他入口一致。

// MARK: - 入口页

struct LanLibraryView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case dlna = "DLNA 服务器"
        case smb = "SMB 共享"
        var id: String { rawValue }
    }

    @Environment(\.theme) private var theme
    @State private var mode: Mode = .dlna
    @StateObject private var browser = MediaServerBrowser()
    @State private var shares: [SMBShareConfig] = SMBShareConfig.load()
    @State private var showAddShare = false
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                VStack(spacing: 0) {
                    Picker("来源", selection: $mode) {
                        ForEach(Mode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                    if mode == .dlna {
                        dlnaPane
                    } else {
                        smbPane
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
            .navigationTitle("局域网影库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.navBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .sheet(isPresented: $showAddShare) {
            SMBAddShareSheet { _ in
                shares = SMBShareConfig.load()
            }
        }
        .onChange(of: shares) { _ in
            SMBShareConfig.save(shares)
        }
    }

    // MARK: DLNA 页

    private var dlnaPane: some View {
        VStack(spacing: 0) {
            Button {
                browser.scan()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: browser.scanning ? "stopwatch" : "dot.radiowaves.left.and.right")
                        .font(.system(size: 15))
                    Text(browser.scanning ? "正在扫描局域网…" : "扫描局域网里的媒体服务器")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(browser.scanning)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            if browser.devices.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.system(size: 34))
                        .foregroundStyle(theme.textTertiary)
                    Text(browser.hint.isEmpty ? "点上面的按钮找家里的 NAS" : browser.hint)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(browser.devices) { device in
                            NavigationLink {
                                DLNABrowseView(device: device, objectID: "0", pathTitle: "根目录")
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "server.rack")
                                        .font(.system(size: 15))
                                        .foregroundStyle(theme.accent)
                                    Text(device.name)
                                        .font(.system(size: 14))
                                        .foregroundStyle(theme.text)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    } header: {
                        Text("找到 \(browser.devices.count) 台")
                            .font(.system(size: 12))
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: SMB 页

    private var smbPane: some View {
        VStack(spacing: 0) {
            Button {
                showAddShare = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 15))
                    Text("添加 SMB 共享")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            if shares.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive")
                        .font(.system(size: 34))
                        .foregroundStyle(theme.textTertiary)
                    Text("还没有共享。填 NAS 的 IP、共享名和账号即可，如 smb://192.168.1.5 里的 video 共享")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(shares) { share in
                            NavigationLink {
                                SMBBrowseView(config: share, path: "/", pathTitle: share.share)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "externaldrive.fill")
                                        .font(.system(size: 15))
                                        .foregroundStyle(theme.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(share.share)
                                            .font(.system(size: 14))
                                            .foregroundStyle(theme.text)
                                        Text("smb://\(share.host)")
                                            .font(.system(size: 11))
                                            .foregroundStyle(theme.textTertiary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                shares[index].clearPassword()
                            }
                            shares.remove(atOffsets: indexSet)
                            SMBShareConfig.save(shares)
                        }
                    } header: {
                        Text("已存共享 · 左滑可删除")
                            .font(.system(size: 12))
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

// MARK: - DLNA 浏览

struct DLNABrowseView: View {
    @Environment(\.theme) private var theme

    let device: MediaServerDevice
    let objectID: String
    let pathTitle: String

    @State private var entries: [MediaEntry] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var toast: String?

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
                                    DLNABrowseView(device: device, objectID: entry.id, pathTitle: entry.title)
                                } label: {
                                    MediaEntryRow(entry: entry)
                                }
                            } else {
                                Button {
                                    play(entry)
                                } label: {
                                    MediaEntryRow(entry: entry)
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

    private func load() {
        loading = true
        errorText = nil
        Task {
            do {
                let list = try await MediaServerBrowser().browse(device, objectID: objectID)
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

    private func play(_ entry: MediaEntry) {
        guard let url = entry.resourceURL else {
            toast = "这台服务器没给出可播放的地址"
            return
        }
        Router.shared.pending = PlayRequest(url: url)
    }
}

// MARK: - SMB 浏览

struct SMBBrowseView: View {
    @Environment(\.theme) private var theme

    let config: SMBShareConfig
    let path: String
    let pathTitle: String

    @State private var client: SMBShareClient
    @State private var entries: [MediaEntry] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var toast: String?

    init(config: SMBShareConfig, path: String, pathTitle: String) {
        self.config = config
        self.path = path
        self.pathTitle = pathTitle
        _client = State(initialValue: SMBShareClient(config: config))
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
                                    SMBBrowseView(config: config, path: entry.id, pathTitle: entry.title)
                                } label: {
                                    MediaEntryRow(entry: entry)
                                }
                            } else {
                                Button {
                                    play(entry)
                                } label: {
                                    MediaEntryRow(entry: entry)
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

    private func play(_ entry: MediaEntry) {
        guard SMBStreamServer.mime(for: entry.title) != nil else {
            toast = "暂不支持这种文件格式"
            return
        }
        toast = "正在准备流媒体…"
        let keep = client
        Task {
            _ = await SMBStreamServer.shared.start(provider: { keep })
            guard let url = SMBStreamServer.shared.streamURL(for: entry.id) else {
                await MainActor.run {
                    toast = "本地流服务没起来"
                }
                return
            }
            await MainActor.run {
                toast = nil
                Router.shared.pending = PlayRequest(url: url)
            }
        }
    }
}

// MARK: - 条目行

private struct MediaEntryRow: View {
    @Environment(\.theme) private var theme

    let entry: MediaEntry

    var body: some View {
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
}

// MARK: - 添加共享表单

struct SMBAddShareSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var onSaved: (SMBShareConfig) -> Void

    @StateObject private var scanner = SMBDiscovery()
    @State private var host: String
    @State private var share = ""
    @State private var username = ""
    @State private var password = ""
    @State private var testing = false
    @State private var errorText: String?
    @State private var hint: String?

    init(initialHost: String = "", onSaved: @escaping (SMBShareConfig) -> Void) {
        self.onSaved = onSaved
        _host = State(initialValue: initialHost)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                Form {
                    Section {
                        if scanner.scanning {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("正在扫描同一 Wi-Fi 下的 SMB 设备…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ForEach(scanner.devices) { device in
                            Button {
                                host = device.host
                                hint = "已填入 \(device.host)，再补上共享名"
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "externaldrive.connected.to.line.below")
                                        .foregroundStyle(theme.accent)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(device.name)
                                            .font(.system(size: 14))
                                            .foregroundStyle(theme.text)
                                        Text(device.host)
                                            .font(.system(size: 11))
                                            .foregroundStyle(theme.textTertiary)
                                    }
                                    Spacer()
                                    if host == device.host {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(theme.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        if !scanner.hint.isEmpty {
                            Text(scanner.hint)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textTertiary)
                        }

                        Button {
                            scanner.start()
                        } label: {
                            Label(scanner.scanning ? "扫描中…" : "重新扫描",
                                  systemImage: "arrow.clockwise")
                                .font(.system(size: 12))
                        }
                        .disabled(scanner.scanning)
                    } header: {
                        Text("附近的设备")
                    } footer: {
                        Text("点一下自动填主机地址；共享名还是要手填（常见的 video、media、public）。")
                    }

                    Section {
                        TextField("主机，如 192.168.1.5 或 nas.local", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("共享名，如 video", text: $share)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("账号（匿名留空）", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("密码", text: $password)
                    } header: {
                        Text("smb://主机/共享名")
                    } footer: {
                        Text("NAS 的共享文件夹名在控制台里看，常见的是 video、media、public。匿名共享账号密码都留空。")
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
                        .disabled(testing || host.trimmingCharacters(in: .whitespaces).isEmpty || share.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("添加 SMB 共享")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(theme.accent)
                }
            }
        }
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
    }

    private func save() {
        testing = true
        errorText = nil
        hint = nil

        var config = SMBShareConfig()
        config.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        config.share = share.trimmingCharacters(in: .whitespacesAndNewlines)
        config.username = username.trimmingCharacters(in: .whitespacesAndNewlines)

        let client = SMBShareClient(config: config, password: password)
        Task {
            do {
                _ = try await client.list(path: "/")
                var list = SMBShareConfig.load()
                if let index = list.firstIndex(where: { $0.host == config.host && $0.share == config.share }) {
                    config.id = list[index].id
                    list[index] = config
                } else {
                    list.append(config)
                }
                config.savedPassword = password
                SMBShareConfig.save(list)
                await client.disconnect()
                await MainActor.run {
                    onSaved(config)
                    dismiss()
                }
            } catch {
                await client.disconnect()
                await MainActor.run {
                    testing = false
                    errorText = error.localizedDescription
                }
            }
        }
    }
}
