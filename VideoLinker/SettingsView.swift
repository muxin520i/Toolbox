import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.theme) private var theme

    @AppStorage(SettingsKey.theme) private var themeRaw = AppTheme.system.rawValue
    @AppStorage(SettingsKey.rate) private var rate = 1.0
    @AppStorage(SettingsKey.autoResume) private var autoResume = true
    @AppStorage(SettingsKey.gestures) private var gestures = true

    @State private var confirmClearResume = false
    @State private var confirmClearHistory = false
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
        .confirmationDialog("清除所有观看进度？", isPresented: $confirmClearResume, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                UserDefaults.standard.removeObject(forKey: "video.resume.v1")
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
                Text("支持 MP4 / MOV / M4V 直链与 HLS（.m3u8）流。网页链接不是直链，需要在「嗅探」里抓取真实地址。\n浏览器相关的 UA、广告拦截、夜间模式等都挪到嗅探页的「菜单 → 浏览器设置」里了。")
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
