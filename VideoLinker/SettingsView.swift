import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.theme) private var theme

    @AppStorage(SettingsKey.theme) private var themeRaw = AppTheme.system.rawValue
    @AppStorage(SettingsKey.rate) private var rate = 1.0
    @AppStorage(SettingsKey.downloadConcurrency) private var concurrency = 3
    @AppStorage(SettingsKey.subtitleSize) private var subtitleSize = 17.0
    @AppStorage(SettingsKey.autoResume) private var autoResume = true
    @AppStorage(SettingsKey.gestures) private var gestures = true
    @AppStorage(AppLock.enabledKey) private var lockEnabled = false
    @AppStorage(AppLock.timingKey) private var lockTiming = 0
    @AppStorage(PlaylistStore.downloadTargetKey) private var downloadTarget = PlaylistStore.autoTarget

    @State private var playlists: [Playlist] = []
    @State private var builtinDownloadID: UUID? = PlaylistStore.existingDownloadListID()
    @State private var showNewList = false
    @State private var newListName = ""
    @State private var confirmClearResume = false
    @State private var confirmClearHistory = false
    @State private var showInbox = false
    @State private var showStats = false
    @State private var showStorage = false
    @State private var showWebDAV = false
    @State private var toast: String?

    private let rates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                ScrollView {
                    VStack(spacing: 16) {
                        themeCard
                        playbackCard
                        downloadCard
                        storageCard
                        privacyCard
                        dataCard
                        aboutCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 40)
                }

                if let toast = toast {
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
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(theme.navBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .sheet(isPresented: $showInbox) {
            LANInboxView()
        }
        .sheet(isPresented: $showStats) {
            WatchStatsView()
        }
        .sheet(isPresented: $showStorage) {
            StorageManagerView()
        }
        .sheet(isPresented: $showWebDAV) {
            WebDAVView()
        }
        .confirmationDialog("清除所有观看进度？", isPresented: $confirmClearResume, titleVisibility: .visible) {            Button("清除", role: .destructive) {
                ResumeStore.clear()
                showToast("观看进度已清除")
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("清空播放历史？", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                HistoryStore.clear()
                showToast("历史记录已清空")
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear(perform: reloadDownloadTargets)
        .alert("新建播放列表", isPresented: $showNewList) {
            TextField("列表名称", text: $newListName)
            Button("取消", role: .cancel) { newListName = "" }
            Button("创建") {
                let name = newListName
                newListName = ""
                if let list = PlaylistStore.createList(named: name) {
                    playlists = PlaylistStore.load()
                    downloadTarget = list.id.uuidString
                    showToast("已新建「\(list.name)」，之后下载都放这里")
                }
            }
        } message: {
            Text("新建后会自动设为下载保存位置。")
        }
    }

    private func reloadDownloadTargets() {
        // 保证内置「下载」列表存在，同时把已删除的目标回落到默认
        _ = PlaylistStore.downloadListID()
        playlists = PlaylistStore.load()
        builtinDownloadID = PlaylistStore.existingDownloadListID()
        if downloadTarget != PlaylistStore.autoTarget,
           !playlists.contains(where: { $0.id.uuidString == downloadTarget }) {
            downloadTarget = PlaylistStore.autoTarget
        }
    }

    // MARK: 外观

    private var themeCard: some View {
        card(title: "外观", icon: "paintbrush.fill") {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(AppTheme.allCases) { item in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                themeRaw = item.rawValue
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 17, weight: .semibold))
                                Text(item.title)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(themeRaw == item.rawValue ? .white : theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 66)
                            .background(
                                themeRaw == item.rawValue
                                    ? AnyShapeStyle(theme.gradient)
                                    : AnyShapeStyle(theme.field),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: 播放

    private var playbackCard: some View {
        card(title: "播放", icon: "play.circle.fill") {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("默认播放速度")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.text)
                        Text("每次打开播放器都用这个速度；播放页里临时调倍速不会改动它")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Picker("", selection: $rate) {
                        ForEach(rates, id: \.self) { value in
                            Text(rateText(value)).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(theme.accent)
                }
                .padding(.vertical, 8)

                Divider().overlay(theme.cardStroke)

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("字幕字号")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.text)
                        Text("播放页加载 srt / vtt / ass 字幕时用这个大小")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                    }

                    Spacer(minLength: 8)

                    Picker("", selection: $subtitleSize) {
                        Text("小").tag(15.0)
                        Text("标准").tag(17.0)
                        Text("大").tag(20.0)
                        Text("特大").tag(24.0)
                    }
                    .pickerStyle(.menu)
                    .tint(theme.accent)
                }
                .padding(.vertical, 6)

                Divider().overlay(theme.cardStroke)

                toggleRow("记忆观看进度", subtitle: "下次打开自动从上次的位置继续", isOn: $autoResume)

                Divider().overlay(theme.cardStroke)

                toggleRow("全屏手势", subtitle: "双击快进快退、上下滑调音量、按住画面 0.5 秒 2 倍速", isOn: $gestures)
            }
        }
    }

    // MARK: 下载

    private var downloadCard: some View {
        card(title: "下载", icon: "arrow.down.circle.fill") {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("下载保存到")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.text)
                        Text("下好的视频自动加入这个列表")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                    }

                    Spacer(minLength: 8)

                    Picker("", selection: $downloadTarget) {
                        Text("下载（默认）")
                            .tag(PlaylistStore.autoTarget)
                        ForEach(playlists.filter { $0.id != builtinDownloadID }) { playlist in
                            Text(playlist.name)
                                .tag(playlist.id.uuidString)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(theme.accent)
                }
                .padding(.vertical, 6)

                Divider().overlay(theme.cardStroke)

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("同时下载数量")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.text)
                        Text("同时下的任务越多越快，也越吃网速和电量")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                    }

                    Spacer(minLength: 8)

                    Picker("", selection: $concurrency) {
                        ForEach(1...5, id: \.self) { value in
                            Text("\(value) 个").tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(theme.accent)
                    .onChange(of: concurrency) { value in
                        DownloadManager.shared.concurrency = value
                    }
                }
                .padding(.vertical, 6)

                Divider().overlay(theme.cardStroke)

                Button {
                    showInbox = true
                } label: {
                    actionRow("局域网收件箱", symbol: "antenna.radiowaves.left.and.right")
                }

                Divider().overlay(theme.cardStroke)

                Button {
                    newListName = ""
                    showNewList = true
                } label: {
                    actionRow("新建列表并保存到", symbol: "folder.badge.plus")
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 数据
    // MARK: 网络存储

    private var storageCard: some View {
        card(title: "网络存储", icon: "externaldrive.connected.to.line.below") {
            VStack(spacing: 0) {
                Button {
                    showWebDAV = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("WebDAV")
                                .font(.system(size: 14))
                                .foregroundStyle(theme.text)
                            Text(webdavSubtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var webdavSubtitle: String {
        let config = WebDAVConfig.load()
        guard config.isUsable, let host = URL(string: config.baseURL)?.host else {
            return "未连接 · 点这里挂载 NAS 或网盘"
        }
        return host
    }

    // MARK: 隐私

    private var privacyCard: some View {
        card(title: "隐私", icon: "lock.shield.fill") {
            VStack(spacing: 0) {
                Toggle(isOn: $lockEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("App 锁")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.text)
                        Text("打开或切回前台时需要\(AppLock.biometryName)")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .tint(theme.accent)
                .padding(.vertical, 10)

                if lockEnabled {
                    Divider().overlay(theme.cardStroke)

                    HStack {
                        Text("离开后重新验证")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.text)
                        Spacer()
                        Picker("", selection: $lockTiming) {
                            Text("立即").tag(0)
                            Text("1 分钟").tag(60)
                            Text("5 分钟").tag(300)
                        }
                        .pickerStyle(.menu)
                        .tint(theme.textSecondary)
                    }
                    .padding(.vertical, 4)

                    Divider().overlay(theme.cardStroke)

                    Button {
                        NotificationCenter.default.post(name: AppLock.lockNowNotification, object: nil)
                        showToast("已锁定，验证后继续")
                    } label: {
                        actionRow("立即锁定", symbol: "lock.fill")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 数据

    private var dataCard: some View {
        card(title: "数据", icon: "internaldrive.fill") {
            VStack(spacing: 0) {
                Button {
                    showStats = true
                } label: {
                    actionRow("观看统计", symbol: "chart.bar.xaxis")
                }
                .buttonStyle(.plain)

                Divider().overlay(theme.cardStroke)

                Button {
                    showStorage = true
                } label: {
                    actionRow("存储管理", symbol: "internaldrive")
                }
                .buttonStyle(.plain)

                Divider().overlay(theme.cardStroke)

                Button {
                    confirmClearResume = true
                } label: {
                    actionRow("清除观看进度", symbol: "arrow.counterclockwise")
                }
                .buttonStyle(.plain)

                Divider().overlay(theme.cardStroke)

                Button {
                    confirmClearHistory = true
                } label: {
                    actionRow("清空播放历史", symbol: "trash")
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 关于

    private var aboutCard: some View {
        card(title: "关于", icon: "info.circle.fill") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("版本")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.text)
                    Spacer()
                    Text(appVersion)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
                HStack {
                    Text("作者")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.text)
                    Spacer()
                    Text("衣")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
                HStack {
                    Text("数据存储")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.text)
                    Spacer()
                    Text("SQLite · \(AppDB.sizeText)")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
                Text("支持 MP4 / MOV / M4V / HLS 等常见格式，另用 VLC 兜底 MKV、FLV、AVI、RMVB 等。网页链接不是直链，需要在「嗅探」里抓取真实地址。\n浏览器相关的 UA、广告拦截等在嗅探页的「菜单 → 设置」里；网页夜间效果跟随这里选的外观切换。")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
                    .lineSpacing(3)
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    // MARK: 组件

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
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private func toggleRow(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.text)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .tint(theme.accent)
        .padding(.vertical, 10)
    }

    private func actionRow(_ title: String, symbol: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(theme.text)
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func rateText(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.001 { return "\(Int(value))x" }
        return String(format: "%.2gx", value)
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeIn(duration: 0.2)) { toast = nil }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
