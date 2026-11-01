import SwiftUI

// MARK: - 派猫猫旅行

struct WBTravelView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = WBTravelStore.shared

    /// 作为 tab 常驻时，只在自己被选中时刷新
    var active: Bool
    /// 嵌入签到中心时，背景与导航栏由外层提供
    var embedded: Bool

    init(active: Bool = true, embedded: Bool = false) {
        self.active = active
        self.embedded = embedded
    }

    var body: some View {
        Group {
            if embedded {
                contentBody
            } else {
                contentBody
                    .navigationTitle("派猫猫旅行")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(theme.navBg, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                Task { await store.load() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .disabled(store.loading || store.running)
                        }
                    }
            }
        }
        .task(id: active) {
            guard active else { return }
            await store.load()
            // 停留期间自动刷新：猫猫到达时间各不相同，只查一次会和列表脱节
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                if Task.isCancelled { break }
                await store.load()
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 26)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                            if store.toast == toast {
                                withAnimation(.easeIn(duration: 0.2)) { store.toast = nil }
                            }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: store.toast)
    }

    private var contentBody: some View {
        ZStack {
            if !embedded {
                BackgroundView()
            }

            ScrollView {
                VStack(spacing: 14) {
                    summaryCard

                    if store.rows.isEmpty {
                        emptyCard
                    } else {
                        listCard
                        footerHint
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 40)
            }
            .refreshable { await store.load() }
        }
    }

    // MARK: 顶部

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(theme.gradient)
                        .frame(width: 46, height: 46)
                    Text("🐱")
                        .font(.system(size: 23))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(store.headline)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Text(store.updateText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
            }

            HStack(spacing: 0) {
                statBlock("可派发", store.canDispatch, .orange)
                statDivider
                statBlock("可领奖", store.canClaim, .green)
                statDivider
                statBlock("旅行中", store.traveling, theme.textSecondary)
            }

            Button {
                Task { await store.runAll() }
            } label: {
                HStack(spacing: 8) {
                    if store.running {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: store.canClaim > 0 ? "gift.fill" : "airplane")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Text(store.running ? "处理中…" : store.modeText)
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(theme.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .opacity(store.buttonEnabled || store.running ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!store.buttonEnabled)

            Text("一次点击会把所有可操作的账号一起处理，只处理国内版")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(16)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private func statBlock(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(value > 0 ? color : theme.textTertiary)
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(theme.cardStroke)
            .frame(width: 1, height: 26)
    }

    // MARK: 账号列表

    private var listCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("账号状态")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer()
                Text("\(store.rows.count) 个")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 13)
            .padding(.bottom, 4)

            ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(theme.cardStroke)
                        .frame(height: 1)
                        .padding(.leading, 52)
                }
                rowView(row)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private func rowView(_ row: WBTravelRow) -> some View {
        HStack(spacing: 11) {
            avatar(row)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(row.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)

                    if row.international {
                        Text("国际版")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(theme.field, in: Capsule())
                    }
                }

                Text(row.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            badge(row)
        }
        .padding(.vertical, 11)
    }

    private func avatar(_ row: WBTravelRow) -> some View {
        ZStack {
            Circle()
                .fill(theme.gradient)
                .frame(width: 38, height: 38)
            Text(row.initial)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private func badge(_ row: WBTravelRow) -> some View {
        let kind = row.kind
        let color = badgeColor(kind)

        return Text(kind.badge)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.13), in: Capsule())
    }

    private func badgeColor(_ kind: WBTravelKind) -> Color {
        switch kind {
        case .canDispatch:
            return .orange
        case .canClaim:
            return .green
        case .failed:
            return .red
        case .traveling, .dailyLimit, .unsupported, .querying:
            return theme.textSecondary
        }
    }

    // MARK: 空态 / 说明

    private var emptyCard: some View {
        VStack(spacing: 12) {
            Text("🐱")
                .font(.system(size: 34))
            Text("还没有账号")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("回到签到页，点右上角 + 登录一个账号")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private var footerHint: some View {
        VStack(spacing: 4) {
            Text("派发后猫猫会出门旅行，到达后回来领积分")
                .font(.system(size: 10.5))
            Text("旅行协议来自社区实现，请求只发往 WorkBuddy 官方域名")
                .font(.system(size: 10.5))
        }
        .foregroundStyle(theme.textTertiary)
        .multilineTextAlignment(.center)
        .padding(.top, 6)
    }
}
