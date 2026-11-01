import SwiftUI

// MARK: - 积分页

struct WBPointsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = WBCheckinStore.shared

    /// 作为 tab 常驻时，只在自己被选中时刷新
    var active: Bool
    /// 嵌入签到中心时，背景与导航栏由外层提供
    var embedded: Bool

    @State private var refreshing = false

    init(active: Bool = true, embedded: Bool = false) {
        self.active = active
        self.embedded = embedded
    }

    private var accounts: [WBAccount] { store.accounts }

    private var totalRemaining: Double {
        accounts.reduce(0) { $0 + (store.credits[$1.id]?.remaining ?? 0) }
    }

    private var totalCapacity: Double {
        accounts.reduce(0) { $0 + (store.credits[$1.id]?.total ?? 0) }
    }

    private var expiringSoon: Double {
        accounts.reduce(0) { $0 + (store.credits[$1.id]?.expiringSoonRemaining ?? 0) }
    }

    private var soonestExpire: Double? {
        accounts.compactMap { store.credits[$0.id]?.soonestExpire }.min()
    }

    private var loadedCount: Int {
        accounts.filter { store.credits[$0.id] != nil }.count
    }

    var body: some View {
        Group {
            if embedded {
                contentBody
            } else {
                NavigationStack {
                    contentBody
                        .navigationTitle("积分")
                        .navigationBarTitleDisplayMode(.large)
                        .toolbarBackground(theme.navBg, for: .navigationBar)
                        .toolbarBackground(.visible, for: .navigationBar)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button {
                                    Task { await reload() }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 15, weight: .semibold))
                                }
                                .disabled(refreshing)
                            }
                        }
                }
            }
        }
        .task(id: active) {
            guard active else { return }
            await reload()
        }
    }

    private var contentBody: some View {
        ZStack {
            if !embedded {
                BackgroundView()
            }

            ScrollView {
                VStack(spacing: 14) {
                    heroCard

                    if accounts.isEmpty {
                        emptyCard
                    } else {
                        accountsCard
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 40)
            }
            .refreshable { await reload() }
        }
    }

    // MARK: 总览

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("总积分")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))

                Spacer()

                Text(accounts.isEmpty ? "—" : "\(loadedCount)/\(accounts.count) 个账号")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.7))
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(WBJson.amount(totalRemaining))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("/ " + WBJson.amount(totalCapacity))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
            }

            progressBar

            if let text = expireSummary {
                HStack(spacing: 4) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 9.5))
                    Text(text)
                        .font(.system(size: 10.5))
                }
                .foregroundStyle(.white.opacity(0.86))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var progressBar: some View {
        let ratio: Double = totalCapacity > 0
            ? min(1, max(0, totalRemaining / totalCapacity))
            : 0

        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                Capsule()
                    .fill(Color.white)
                    .frame(width: geo.size.width * ratio)
            }
        }
        .frame(height: 5)
        .padding(.vertical, 2)
    }

    private var expireSummary: String? {
        var parts: [String] = []
        if let soonest = soonestExpire {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日"
            parts.append("最近 " + formatter.string(from: Date(timeIntervalSince1970: soonest / 1000)) + " 到期")
        }
        if expiringSoon > 0 {
            parts.append(WBJson.amount(expiringSoon) + " 积分 7 天内过期")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: 账号

    private var accountsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 {
                    Rectangle()
                        .fill(theme.cardStroke)
                        .frame(height: 1)
                        .padding(.leading, 52)
                }
                creditRow(account)
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

    private func creditRow(_ account: WBAccount) -> some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(theme.gradient)
                    .frame(width: 38, height: 38)
                Text(account.initial)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(account.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)

                Text(account.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let credit = store.credits[account.id] {
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(credit.remainingText)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.text)
                        Text("/ " + credit.totalText)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textTertiary)
                    }

                    if let expire = credit.expireText {
                        Text(expire)
                            .font(.system(size: 10))
                            .foregroundStyle(credit.expiringSoonRemaining > 0 ? .orange : theme.textTertiary)
                    } else {
                        Text("\(credit.packages) 个套餐")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            } else if account.needsRelogin {
                Text("需重新登录")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.red)
            } else if refreshing {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Text("未获取")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.vertical, 11)
    }

    // MARK: 空态

    private var emptyCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "creditcard")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(theme.textTertiary)

            Text("还没有账号")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)

            Text("先去「签到」页右上角添加账号，这里就会显示积分")
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

    // MARK: 加载

    private func reload() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await store.loadAllCredits()
    }
}
