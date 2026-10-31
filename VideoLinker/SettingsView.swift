import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.theme) private var theme

    @AppStorage(SettingsKey.theme) private var themeRaw = AppTheme.system.rawValue
    @AppStorage(SettingsKey.rate) private var rate = 1.0
    @AppStorage(SettingsKey.autoResume) private var autoResume = true
    @AppStorage(SettingsKey.gestures) private var gestures = true
    @AppStorage(PlaylistStore.downloadTargetKey) private var downloadTarget = PlaylistStore.autoTarget

    @State private var playlists: [Playlist] = []
    @State private var builtinDownloadID: UUID? = PlaylistStore.existingDownloadListID()
    @State private var showNewList = false
    @State private var newListName = ""
    @State private var confirmClearResume = false
    @State private var confirmClearHistory = false
    @State private var showStorage = false
    @State private var storage = AppDB.report()
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
                        dataCard
                        storageCard
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
        .confirmationDialog("清除所有观看进度？", isPresented: $confirmClearResume, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
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
                    Text("默认倍速")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.text)
                    Spacer()
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
    private var dataCard: some View {
        card(title: "数据", icon: "internaldrive.fill") {
            VStack(spacing: 0) {
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

    // MARK: 存储

    private var storageCard: some View {
        card(title: "存储", icon: "cylinder.split.1x2.fill") {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("本地数据库")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.text)
                        Text(storage.ready
                             ? "历史、列表、脚本、下载都在一个 SQLite 库里"
                             : "未启用，正在使用旧的 UserDefaults 存储")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                    }

                    Spacer(minLength: 8)

                    Text(storage.size)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(.vertical, 6)

                Divider().overlay(theme.cardStroke)

                Button {
                    showStorage = true
                } label: {
                    actionRow("存储详情与一致性校验", symbol: "checklist")
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showStorage) {
            StorageDetailSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear { storage = AppDB.report() }
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
                Text("支持 MP4 / MOV / M4V 直链与 HLS（.m3u8）流。网页链接不是直链，需要在「嗅探」里抓取真实地址。\n浏览器相关的 UA、广告拦截等在嗅探页的「菜单 → 设置」里；网页夜间效果跟随这里选的外观切换。")
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


// MARK: - 存储详情

struct StorageDetailSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var report = AppDB.report()

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                ScrollView {
                    VStack(spacing: 14) {
                        summaryCard
                        countsCard
                        checkCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 36)
                }
            }
            .navigationTitle("存储详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.navBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { report = AppDB.report() }
        }
    }

    private var summaryCard: some View {
        card(title: "数据库", icon: "cylinder.split.1x2.fill") {
            VStack(alignment: .leading, spacing: 10) {
                line("状态", report.ready ? "正常" : "不可用（已回落旧存储）")
                line("结构版本", report.schema)
                line("占用空间", report.size)
                Text(report.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
    }

    private var countsCard: some View {
        card(title: "记录数", icon: "list.number") {
            VStack(spacing: 0) {
                ForEach(Array(report.counts.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().overlay(theme.cardStroke) }
                    HStack {
                        Text(row.name)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.text)
                        Spacer()
                        Text("\(row.count)")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var checkCard: some View {
        card(title: "一致性校验", icon: "checkmark.seal") {
            VStack(alignment: .leading, spacing: 8) {
                if !report.ready {
                    Text("数据库没有打开，本次运行使用旧存储。可以重启 App 再试；如果一直这样，说明磁盘写入有问题。")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                } else if report.mismatch.isEmpty {
                    Text("数据库与旧存储条数一致，双写正常。")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                    Text("旧数据在首次升级时已整包备份到 App 的 Application Support/VideoLinker 目录，文件名以 legacy-backup- 开头。")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                } else {
                    ForEach(report.mismatch, id: \.self) { row in
                        Text("· " + row)
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                    Text("库里比旧存储少，通常是旧存储已被裁剪或写入还没同步；数据不会因此丢失。")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(theme.text)
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
        }
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
}
