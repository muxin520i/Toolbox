import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.theme) private var theme

    @AppStorage(SettingsKey.theme) private var themeRaw = AppTheme.system.rawValue
    @AppStorage(SettingsKey.tint) private var tintRaw = AppTint.coral.rawValue
    @State private var iconBusy = false
    @AppStorage(SettingsKey.rate) private var rate = 1.0
    @AppStorage(SettingsKey.downloadConcurrency) private var concurrency = 3
    @AppStorage(SettingsKey.subtitleSize) private var subtitleSize = 17.0

    /// 签到接口配置的版本，刷新后手动更新
    @State private var endpointText = WBRemoteConfig.shared.statusText
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
    @State private var showLANShare = false
    @State private var showLANTransfer = false
    @State private var showStats = false
    @State private var showStorage = false
    @State private var showSiteData = false
    @State private var showTransfer = false
    @State private var showPatrol = false
    @State private var showSync = false
    @State private var showUpdate = false

    @ObservedObject private var updateChecker = UpdateChecker.shared
    @State private var showWebDAV = false
    @State private var showEndpoint = false
    @State private var showHeaders = false
    @State private var showReceiver = false
    @State private var showGestures = false
    @State private var showAudioSync = false
    @State private var showDiagnostics = false
    @State private var showPrivateHelp = false
    @State private var showMemos = false
    @State private var toast: String?

    @ObservedObject private var memos = MemoStore.shared

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
                        networkCard
                        storageCard
                        privacyCard
                        memoCard
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
        .sheet(isPresented: $showLANShare) {
            LANShareView()
        }
        .sheet(isPresented: $showLANTransfer) {
            LANTransferView()
        }
        .sheet(isPresented: $showUpdate) {
            UpdateSheet()
        }
        .sheet(isPresented: $showStats) {
            WatchStatsView()
        }
        .sheet(isPresented: $showStorage) {
            StorageManagerView()
        }
        .sheet(isPresented: $showSiteData) {
            SiteDataView()
        }
        .sheet(isPresented: $showTransfer) {
            TransferView()
        }
        .sheet(isPresented: $showSync) {
            SyncView()
        }
        .sheet(isPresented: $showPatrol) {
            PatrolView()
        }
        .sheet(isPresented: $showMemos) {
            MemoListView()
        }
        .sheet(isPresented: $showWebDAV) {
            WebDAVView()
        }
        .sheet(isPresented: $showHeaders) {
            RequestHeaderView()
        }
        .sheet(isPresented: $showReceiver) {
            DLNAReceiverView()
        }
        .alert("私密保险箱", isPresented: $showPrivateHelp) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("在「列表」页长按任意列表 →「移入私密保险箱」，该列表会从列表页消失。\n\n查看：列表页左上角 ⋯ →「私密保险箱」，验证\(AppLock.biometryName)后出现；切到后台会自动收回。")
        }
        .sheet(isPresented: $showEndpoint) {
            WBEndpointSheet()
        }
        .onChange(of: showEndpoint) { opened in
            if !opened { endpointText = WBRemoteConfig.shared.statusText }
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
        .onAppear {
            reloadDownloadTargets()
            updateChecker.checkIfNeeded()
        }
        .alert("新建播放列表", isPresented: $showNewList) {
            TextField("列表名称", text: $newListName)
            Button("取消", role: .cancel) { newListName = "" }
            Button("创建") {
                let name = newListName
                newListName = ""
                if let list = PlaylistStore.createList(named: name) {
                    playlists = PlaylistStore.visible()
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
        playlists = PlaylistStore.visible()
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

                Divider().overlay(theme.cardStroke)

                VStack(alignment: .leading, spacing: 10) {
                    Text("主题色")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.textSecondary)

                    HStack(spacing: 10) {
                        ForEach(AppTint.allCases) { item in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    tintRaw = item.rawValue
                                }
                            } label: {
                                Circle()
                                    .fill(LinearGradient(colors: item.colors,
                                                         startPoint: .topLeading,
                                                         endPoint: .bottomTrailing))
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(.white.opacity(tintRaw == item.rawValue ? 0.95 : 0),
                                                          lineWidth: 2.5)
                                    )
                                    .overlay(
                                        Circle()
                                            .strokeBorder(theme.cardStroke, lineWidth: 1)
                                    )
                                    .shadow(color: item.accent.opacity(tintRaw == item.rawValue ? 0.5 : 0),
                                            radius: 6, y: 2)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.title)
                        }

                        Spacer(minLength: 0)

                        Text(AppTint(rawValue: tintRaw)?.title ?? "")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                Divider().overlay(theme.cardStroke)

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("App 图标")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(theme.text)
                        Text("换成对应配色的桌面图标，第一颗是默认")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textTertiary)
                    }

                    HStack(spacing: 8) {
                        ForEach(AppTint.allCases) { item in
                            Button {
                                applyIcon(item)
                            } label: {
                                IconPreview(colors: item.colors)
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(theme.accent.opacity(0.9),
                                                          lineWidth: currentIconName == item.iconName ? 2 : 0)
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(iconBusy)
                        }

                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// 当前使用的桌面图标名，nil 是默认图标
    private var currentIconName: String? {
        UIApplication.shared.alternateIconName
    }

    private func applyIcon(_ tint: AppTint) {
        guard UIApplication.shared.supportsAlternateIcons else {
            showToast("这台设备不支持换图标")
            return
        }
        guard UIApplication.shared.alternateIconName != tint.iconName else { return }

        iconBusy = true
        UIApplication.shared.setAlternateIconName(tint.iconName) { error in
            DispatchQueue.main.async {
                iconBusy = false
                if error != nil {
                    showToast("换图标失败，稍后再试")
                } else {
                    showToast("图标已换成「\(tint.title)」")
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

                Divider().overlay(theme.cardStroke)

                Button {
                    showGestures = true
                } label: {
                    actionRow("手势与手感", symbol: "hand.tap")
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showGestures) {
                    GestureSettingsView()
                }

                Divider().overlay(theme.cardStroke)

                Button {
                    showAudioSync = true
                } label: {
                    actionRow("音画同步（蓝牙耳机）", symbol: "headphones")
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showAudioSync) {
                    AudioSyncSheet { _ in }
                }
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
                    showPatrol = true
                } label: {
                    actionRow("定时巡检", symbol: "clock.arrow.circlepath")
                }
                .buttonStyle(.plain)

                Divider().overlay(theme.cardStroke)

                Button {
                    showInbox = true
                } label: {
                    actionRow("局域网收件箱", symbol: "antenna.radiowaves.left.and.right")
                }

                Divider().overlay(theme.cardStroke)

                Button {
                    showLANShare = true
                } label: {
                    actionRow("局域网投屏（电脑浏览器看）", symbol: "airplayvideo")
                }
                .buttonStyle(.plain)

                Divider().overlay(theme.cardStroke)

                Button {
                    showLANTransfer = true
                } label: {
                    actionRow("局域网互传（手机对手机）", symbol: "arrow.left.arrow.right")
                }
                .buttonStyle(.plain)

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

    // MARK: 网络

    private var networkCard: some View {
        card(title: "网络与请求", icon: "network") {
            VStack(spacing: 0) {
                Button {
                    showHeaders = true
                } label: {
                    actionRow("请求头（Referer / Cookie / UA）", symbol: "chevron.right")
                }
                .buttonStyle(.plain)

                Divider().overlay(theme.cardStroke)

                Text("有些站点直接播只给 403，加一条对应域名的规则就能放；下载和嗅探也会用同一套规则。")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                Divider().overlay(theme.cardStroke)

                Button {
                    showReceiver = true
                } label: {
                    actionRow("接收投屏（手机当电视）", symbol: "tv.badge.wifi")
                }
                .buttonStyle(.plain)

                Divider().overlay(theme.cardStroke)

                Button {
                    showDiagnostics = true
                } label: {
                    actionRow("网络诊断（IP / 延迟 / 测速）", symbol: "waveform.path.ecg")
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showDiagnostics) {
                    NetworkDiagnosticsView()
                }
            }
        }
    }

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

                Divider().overlay(theme.cardStroke)

                Button {
                    showPrivateHelp = true
                } label: {
                    actionRow("私密保险箱", symbol: "chevron.right")
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 备忘录

    private var memoCard: some View {
        card(title: "备忘", icon: "note.text") {
            Button {
                showMemos = true
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("备忘录")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.text)
                        Text(memoSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if !memos.items.isEmpty {
                        Text("\(memos.items.count) 条")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(theme.accent.opacity(0.12), in: Capsule())
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var memoSummary: String {
        guard let latest = memos.items.first else {
            return "把链接、账号、临时记的东西放这里，免得搞丢"
        }
        return "最近更新 \(latest.dateText)"
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
                    showSiteData = true
                } label: {
                    actionRow("网站数据", symbol: "globe")
                }
                .buttonStyle(.plain)

                Divider().overlay(theme.cardStroke)

                Button {
                    showTransfer = true
                } label: {
                    actionRow("换机搬家", symbol: "shippingbox")
                }
                .buttonStyle(.plain)

                Divider().overlay(theme.cardStroke)

                Button {
                    showSync = true
                } label: {
                    actionRow("多设备同步", symbol: "arrow.triangle.2.circlepath")
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
                Button {
                    showUpdate = true
                } label: {
                    HStack(spacing: 8) {
                        Text("检查更新")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.text)

                        Spacer()

                        if updateChecker.hasUpdate {
                            Text("有新版本")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(theme.accent, in: Capsule())
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

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
                Button {
                    showEndpoint = true
                } label: {
                    HStack(spacing: 8) {
                        Text("签到接口")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.text)
                        Spacer()
                        Text(endpointText)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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

// MARK: - 签到接口配置

struct WBEndpointSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = WBRemoteConfig.shared.customURL
    @State private var pasteText = ""
    @State private var statusText = WBRemoteConfig.shared.statusText
    @State private var isRemote = WBRemoteConfig.shared.isRemote
    @State private var hint = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                ScrollView {
                    VStack(spacing: 14) {
                        statusCard
                        urlCard
                        importCard
                        helpCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("签到接口")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.navBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("当前配置")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)

                Spacer()

                Text(isRemote ? "远端" : "内置")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isRemote ? Color.green : theme.textTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background((isRemote ? Color.green : theme.textTertiary).opacity(0.12), in: Capsule())
            }

            Text(statusText)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.text)

            Text("签到、积分、派猫猫旅行的路径都从这里来，拉取失败自动用内置路径。")
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
                .lineSpacing(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private var urlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("配置地址")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)

            TextField("https://…/wb-endpoints.json", text: $urlText)
                .font(.system(size: 12.5))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(10)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 10) {
                Button {
                    Task { await saveAndFetch() }
                } label: {
                    Text(busy ? "拉取中…" : "保存并拉取")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(theme.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .opacity(busy ? 0.6 : 1)
                }
                .buttonStyle(.plain)
                .disabled(busy)

                if !urlText.isEmpty {
                    Button {
                        urlText = ""
                        WBRemoteConfig.shared.customURL = ""
                        hint = "已清空自定义地址"
                    } label: {
                        Text("清空")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 64, height: 38)
                            .background(theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("直接粘贴配置")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)

            TextEditor(text: $pasteText)
                .font(.system(size: 11.5))
                .scrollContentBackground(.hidden)
                .frame(height: 96)
                .padding(8)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 10) {
                Button {
                    pasteText = UIPasteboard.general.string ?? ""
                } label: {
                    Text("从剪贴板粘贴")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    applyPaste()
                } label: {
                    Text("导入")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(theme.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .opacity(pasteText.isEmpty ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(pasteText.isEmpty)
            }

            if !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .lineSpacing(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("怎么用")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)

            Text("官方改了接口路径时，把新的 wb-endpoints.json 放到任意能公开访问的地址，填在上面的「配置地址」里；也可以把 JSON 内容直接粘进来导入。改完重启 App 生效，不用换安装包。\n\n只能改路径和附加请求头。如果官方连返回结构都改了，还是得等 App 更新。")
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
                .lineSpacing(3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private func saveAndFetch() async {
        busy = true
        WBRemoteConfig.shared.customURL = urlText
        // 返回 false 说明这次没拿到，可能还在用上一份，别误报成功
        let ok = await WBRemoteConfig.shared.refreshNow()
        refreshStatus()
        busy = false
        hint = ok ? "已更新：" + statusText : "没拉到配置，继续使用原有路径"
    }

    private func applyPaste() {
        if let error = WBRemoteConfig.shared.importJSON(pasteText) {
            hint = error
            return
        }
        refreshStatus()
        hint = "已导入：" + statusText
        pasteText = ""
    }

    private func refreshStatus() {
        statusText = WBRemoteConfig.shared.statusText
        isRemote = WBRemoteConfig.shared.isRemote
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}

/// 图标预览：渐变底 + 白色播放三角，和桌面图标同一套构图
private struct IconPreview: View {
    let colors: [Color]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Path { path in
                    path.move(to: CGPoint(x: w * 0.38, y: h * 0.26))
                    path.addLine(to: CGPoint(x: w * 0.74, y: h * 0.50))
                    path.addLine(to: CGPoint(x: w * 0.38, y: h * 0.74))
                    path.closeSubpath()
                }
                .fill(.white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
