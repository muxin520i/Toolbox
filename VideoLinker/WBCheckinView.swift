import SwiftUI

// MARK: - 签到页

struct WBCheckinView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = WBCheckinStore.shared

    /// 作为 tab 常驻时，只在自己被选中时刷新
    var active: Bool

    @State private var showLogin = false
    @State private var detail: WBAccount?
    @State private var autoOn = WBDefaults.autoEnabled

    init(active: Bool = true) {
        self.active = active
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                ScrollView {
                    VStack(spacing: 14) {
                        heroCard

                        if store.accounts.isEmpty {
                            emptyCard
                        } else {
                            accountsCard
                        }

                        if !store.logs.isEmpty {
                            logsCard
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 40)
                }
                .refreshable { await store.refreshAll() }
            }
            .navigationTitle("签到")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(theme.navBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showLogin = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
        }
        .task(id: active) {
            guard active else { return }
            await store.onAppear()
        }
        .sheet(isPresented: $showLogin) {
            WBLoginView { account in
                store.add(account)
                Task {
                    await store.refreshState(account.id)
                    await store.loadCredits(account.id)
                }
            }
        }
        .sheet(item: $detail) { account in
            WBAccountSheet(store: store, accountID: account.id)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                            if store.toast == toast {
                                withAnimation(.easeIn(duration: 0.2)) { store.toast = nil }
                            }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: store.toast)
    }

    // MARK: 顶部

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("今日签到")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(store.checkedCount)")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.text)
                        Text("/ \(store.accounts.count)")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.textTertiary)
                    }

                    Text(allChecked ? "\(dateText) · 已完成" : dateText)
                        .font(.system(size: 11))
                        .foregroundStyle(allChecked ? .green : theme.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 12)

                progressRing
            }

            Button {
                Task { await store.checkinAll() }
            } label: {
                HStack(spacing: 8) {
                    if store.runningAll {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: allChecked ? "checkmark.circle.fill" : "checkmark.seal.fill")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Text(store.runningAll ? "正在签到…" : (allChecked ? "今日已全部签到" : "一键签到"))
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(allChecked ? theme.textSecondary : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(allChecked ? AnyShapeStyle(theme.field) : AnyShapeStyle(theme.gradient))
                }
            }
            .buttonStyle(.plain)
            .disabled(store.runningAll || store.accounts.isEmpty || allChecked)

            if !store.accounts.isEmpty {
                Text(allChecked
                     ? "今天都签完了，明天打开会自动继续"
                     : "还有 \(pendingCount) 个账号没签到")
                    .font(.system(size: 11.5))
                    .foregroundStyle(allChecked ? theme.textTertiary : .orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle(isOn: $autoOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("每天首次打开自动签到")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.text)
                    Text("补签当天没签的账号，签过的不重复请求")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .tint(theme.accent)
            .onChange(of: autoOn) { value in
                WBDefaults.autoEnabled = value
            }
        }
        .padding(16)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private var progressRing: some View {
        let ratio: Double = store.accounts.isEmpty
            ? 0
            : Double(store.checkedCount) / Double(store.accounts.count)

        return ZStack {
            Circle()
                .stroke(theme.field, lineWidth: 5)
                .frame(width: 56, height: 56)

            if allChecked {
                Circle()
                    .stroke(Color.green, lineWidth: 5)
                    .frame(width: 56, height: 56)

                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.green)
            } else {
                Circle()
                    .trim(from: 0, to: max(0.001, ratio))
                    .stroke(theme.gradient, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 56, height: 56)
                    .rotationEffect(.degrees(-90))

                Text("\(Int(ratio * 100))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: Date())
    }

    private var allChecked: Bool {
        !store.accounts.isEmpty && store.checkedCount == store.accounts.count
    }

    private var pendingCount: Int {
        max(0, store.accounts.count - store.checkedCount)
    }

    // MARK: 账号

    private var accountsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 {
                    Rectangle()
                        .fill(theme.cardStroke)
                        .frame(height: 1)
                        .padding(.leading, 52)
                }
                accountRow(account)
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

    private func accountRow(_ account: WBAccount) -> some View {
        Button {
            detail = account
        } label: {
            HStack(spacing: 11) {
                avatar(account)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(account.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)

                        if account.isInternational {
                            Text("国际版")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(theme.field, in: Capsule())
                        }
                    }

                    Text(rowSubtitle(account))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if store.running.contains(account.id) {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    statusBadge(account)
                }
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await store.checkin(account.id) }
            } label: {
                Label("立即签到", systemImage: "checkmark.seal")
            }

            Button(role: .destructive) {
                store.delete(account.id)
            } label: {
                Label("删除账号", systemImage: "trash")
            }
        }
    }

    private func rowSubtitle(_ account: WBAccount) -> String {
        if account.needsRelogin {
            return account.reloginReason ?? "登录已失效，请重新登录"
        }
        return account.subtitle
    }

    private func avatar(_ account: WBAccount) -> some View {
        ZStack {
            Circle()
                .fill(theme.gradient)
                .frame(width: 38, height: 38)
            Text(account.initial)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private func statusBadge(_ account: WBAccount) -> some View {
        let state = store.states[account.id] ?? .unknown
        let color: Color

        switch state {
        case .checked:
            color = .green
        case .unchecked:
            color = .orange
        case .relogin:
            color = .red
        case .failed:
            color = .red
        case .unsupported, .unknown:
            color = theme.textTertiary
        }

        return Text(state.text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.13), in: Capsule())
    }

    // MARK: 空态

    private var emptyCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(theme.textTertiary)

            Text("还没有添加账号")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)

            Text("登录一次，之后每天打开 App 会自动帮你签到")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                showLogin = true
            } label: {
                Text("添加账号")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 40)
                    .background(theme.gradient, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 16)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    // MARK: 日志

    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近记录")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)

            ForEach(Array(store.logs.prefix(6))) { entry in
                HStack(spacing: 8) {
                    Circle()
                        .fill(color(for: entry.result))
                        .frame(width: 5, height: 5)

                    Text(entry.name)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)

                    Text(entry.resultText)
                        .font(.system(size: 11))
                        .foregroundStyle(color(for: entry.result))

                    Spacer(minLength: 6)

                    Text(entry.timeText)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private func color(for result: String) -> Color {
        switch result {
        case "success": return .green
        case "already": return theme.textSecondary
        case "skipped": return theme.textTertiary
        default: return .orange
        }
    }

}

// MARK: - 账号详情

struct WBAccountSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var store: WBCheckinStore
    let accountID: String

    @State private var confirmDelete = false

    private var account: WBAccount? {
        store.accounts.first { $0.id == accountID }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                if let account {
                    ScrollView {
                        VStack(spacing: 14) {
                            header(account)
                            infoCard(account)
                            creditCard(account)
                            actionCard(account)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 30)
                    }
                }
            }
            .navigationTitle("账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.navBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                if store.credits[accountID] == nil {
                    await store.loadCredits(accountID)
                }
            }
        }
    }

    private func header(_ account: WBAccount) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(theme.gradient)
                    .frame(width: 60, height: 60)
                Text(account.initial)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text(account.displayName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.text)

            Text(account.isInternational ? "国际版 workbuddy.ai" : "国内版 codebuddy.cn")
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.vertical, 8)
    }

    private func infoCard(_ account: WBAccount) -> some View {
        VStack(spacing: 0) {
            infoRow("邮箱", account.email?.isEmpty == false ? account.email! : "—")
            divider
            infoRow("UID", account.uid?.isEmpty == false ? account.uid! : "—")
            divider
            infoRow("企业", account.enterpriseName?.isEmpty == false ? account.enterpriseName! : "—")
            divider
            infoRow("凭证", account.tokenExpireText)
        }
        .padding(.horizontal, 14)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private var divider: some View {
        Rectangle().fill(theme.cardStroke).frame(height: 1)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 34, alignment: .leading)

            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(theme.text)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    private func creditCard(_ account: WBAccount) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("积分额度")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)

                Spacer()

                Button {
                    Task { await store.loadCredits(account.id) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
            }

            if let credit = store.credits[account.id] {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(credit.remainingText)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.text)
                    Text("/ " + credit.totalText)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                }

                if let expire = credit.expireText {
                    Text(expire + (credit.expiringSoonRemaining > 0
                                   ? "，其中 \(WBJson.amount(credit.expiringSoonRemaining)) 积分 7 天内过期"
                                   : ""))
                        .font(.system(size: 11))
                        .foregroundStyle(credit.expiringSoonRemaining > 0 ? Color.orange : theme.textSecondary)
                }
            } else {
                Text(account.isInternational ? "国际版暂不支持积分查询" : "点右上角刷新试试")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
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

    private func actionCard(_ account: WBAccount) -> some View {
        VStack(spacing: 10) {
            if account.needsRelogin {
                Text(account.reloginReason ?? "登录已失效")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 2)
            }

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Text("删除账号")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .confirmationDialog("删除后需要重新登录才能签到", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    store.delete(account.id)
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
}
