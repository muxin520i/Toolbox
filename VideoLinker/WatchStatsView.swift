import SwiftUI

// MARK: - 观看统计页

struct WatchStatsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var summary = WatchStats.Summary()
    @State private var request: PlayRequest?
    @State private var confirmClear = false

    private var maxDaily: Double {
        max(summary.daily.map { $0.seconds }.max() ?? 0, 1)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                ScrollView {
                    VStack(spacing: 16) {
                        overviewCard
                        weekCard

                        if !summary.topSites.isEmpty {
                            siteCard
                        }

                        if !summary.topItems.isEmpty {
                            topItemsCard
                        }

                        if !summary.neverOpened.isEmpty {
                            unopenedCard
                        }

                        clearCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("观看统计")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.navBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(theme.accent)
                }
            }
        }
        .onAppear { summary = WatchStats.summary() }
        .fullScreenCover(item: $request) { req in
            PlayerScreen(request: req)
        }
        .confirmationDialog("清空观看统计？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                WatchStats.clear()
                summary = WatchStats.summary()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清掉统计明细，不影响观看进度和播放历史。")
        }
    }

    // MARK: 概览

    private var overviewCard: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                bigStat("本周", value: WatchStats.span(summary.week), tint: theme.accent)
                bigStat("今天", value: WatchStats.span(summary.today), tint: theme.text)
                bigStat("累计", value: WatchStats.span(summary.total), tint: theme.text)
            }

            if !summary.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 11))
                    Text("共 \(summary.sessions) 次播放")
                        .font(.system(size: 12))
                }
                .foregroundStyle(theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(theme.cardStroke, lineWidth: 1)
        )
    }

    private func bigStat(_ title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textTertiary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 近 7 天

    private var weekCard: some View {
        card(title: "近 7 天", icon: "chart.bar.fill") {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(summary.daily.enumerated()), id: \.offset) { _, entry in
                    VStack(spacing: 6) {
                        Text(entry.seconds > 0 ? WatchStats.shortSpan(entry.seconds) : "")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)

                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(
                                entry.seconds > 0
                                    ? AnyShapeStyle(theme.gradient)
                                    : AnyShapeStyle(theme.field)
                            )
                            .frame(height: barHeight(entry.seconds))

                        Text(weekday(entry.day))
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 130, alignment: .bottom)

            if summary.isEmpty {
                Text("还没有播放记录，随便放一个视频就会开始统计。")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    private func barHeight(_ seconds: Double) -> CGFloat {
        guard seconds > 0 else { return 4 }
        let ratio = seconds / maxDaily
        return max(8, CGFloat(ratio) * 78)
    }

    private func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }

    // MARK: 常看站点

    private var siteCard: some View {
        card(title: "常看来源", icon: "globe") {
            VStack(spacing: 10) {
                ForEach(summary.topSites) { item in
                    let ratio = summary.topSites.first.map { item.seconds / max($0.seconds, 1) } ?? 0
                    VStack(spacing: 5) {
                        HStack {
                            Text(item.title)
                                .font(.system(size: 13))
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                            Spacer()
                            Text("\(WatchStats.span(item.seconds)) · \(item.count) 次")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textTertiary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(theme.field)
                                Capsule()
                                    .fill(theme.gradient)
                                    .frame(width: max(4, geo.size.width * ratio))
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
    }

    // MARK: 看得最多

    private var topItemsCard: some View {
        card(title: "看得最多", icon: "flame.fill") {
            VStack(spacing: 0) {
                ForEach(Array(summary.topItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().overlay(theme.cardStroke)
                    }
                    Button {
                        guard let url = URL(string: item.url) else { return }
                        request = PlayRequest(url: url)
                    } label: {
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.textTertiary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 13))
                                    .foregroundStyle(theme.text)
                                    .lineLimit(1)
                                Text("\(WatchStats.span(item.seconds)) · \(item.count) 次")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.textTertiary)
                            }
                            Spacer()
                            Image(systemName: "play.circle")
                                .font(.system(size: 16))
                                .foregroundStyle(theme.accent)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 下载了没看

    private var unopenedCard: some View {
        card(title: "下了没看", icon: "tray.and.arrow.down.fill") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(summary.neverOpened.enumerated()), id: \.offset) { index, row in
                    if index > 0 {
                        Divider().overlay(theme.cardStroke)
                    }
                    HStack(spacing: 10) {
                        Text(row.name)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        Spacer()
                        if row.size > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file))
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                    .padding(.vertical, 9)
                }
                if summary.neverOpened.count >= 6 {
                    Text("还有更多…")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                        .padding(.top, 4)
                }
            }
        }
    }

    // MARK: 清空

    private var clearCard: some View {
        Button {
            confirmClear = true
        } label: {
            HStack {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                Text("清空观看统计")
                    .font(.system(size: 14))
                Spacer()
            }
            .foregroundStyle(.red.opacity(0.85))
            .padding(16)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(theme.cardStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: 卡片外壳

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
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(theme.cardStroke, lineWidth: 1)
        )
    }
}
