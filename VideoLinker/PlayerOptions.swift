import SwiftUI
import UIKit
import AVFoundation

// MARK: - 手感
//
// 震动和动效都做成可关的：有人嫌手机在手里老是“哒哒”响，
// 也有人开省电模式或者对动画敏感。默认都开，行为跟以前一样。

enum Haptics {
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.haptics) as? Bool ?? true
    }

    static func light() {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func medium() {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func soft() {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    static func success() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

enum AppMotion {
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.motion) as? Bool ?? true
    }
}

// MARK: - 系统亮度
//
// 播放器里上下滑调亮度只能改屏幕亮度（iOS 不给 App 单独调某个视图的亮度）。
// 退出时要还原，不然用户回到桌面会发现屏幕被 App 调暗了。

enum SystemBrightness {
    static var current: CGFloat { UIScreen.main.brightness }

    static func set(_ value: CGFloat) {
        let clamped = min(1, max(0, value))
        if abs(UIScreen.main.brightness - clamped) > 0.001 {
            UIScreen.main.brightness = clamped
        }
    }
}

// MARK: - 蓝牙音画同步
//
// 蓝牙耳机普遍比画面晚 100–300 ms，看剧时口型对不上。
// 不同耳机延迟不一样，所以按「当前输出设备」分开存。
// 补偿只对 VLC 内核生效（VLC 有 audio-desync 选项），
// 系统播放器没有公开的延迟接口，设置非零偏移时会自动切到 VLC。

enum AudioSyncStore {
    private static let key = "audio.sync.offsets"

    static var device: (id: String, name: String) {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let out = outputs.first else { return ("builtin", "本机扬声器") }
        let id = out.uid.isEmpty ? out.portType.rawValue : out.uid
        return (id, out.portName)
    }

    static var offsets: [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return map
    }

    static func offset() -> Int {
        offsets[device.id] ?? 0
    }

    static func set(_ value: Int) {
        let clamped = max(-300, min(300, value))
        var map = offsets
        if clamped == 0 {
            map.removeValue(forKey: device.id)
        } else {
            map[device.id] = clamped
        }
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - 二维码分享

struct QRShareSheet: View {
    let title: String
    let text: String

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var copied = false
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                QRCodeView(text: text, size: 230)
                    .padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(theme.cardStroke, lineWidth: 1)
                    )

                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = text
                        copied = true
                        Haptics.success()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                    } label: {
                        Label(copied ? "已复制" : "复制链接", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.text)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        showShare = true
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(theme.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)

                Text("另一台手机用相机扫一下就能打开")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)

                Spacer(minLength: 0)
            }
            .padding(.top, 22)
            .background(theme.bg.ignoresSafeArea())
            .navigationTitle("二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $showShare) {
                ActivityView(items: [text])
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - 音画同步面板

struct AudioSyncSheet: View {
    /// 应用时把毫秒数回传给播放页，由播放页决定是否切 VLC 重载
    let onApply: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var value: Double = 0
    @State private var deviceName = "本机扬声器"

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    Text("当前输出")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                    Text(deviceName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                }
                .padding(.top, 8)

                Text(value == 0 ? "0 ms" : String(format: "%+.0f ms", value))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(value == 0 ? theme.textSecondary : theme.accent)

                Slider(value: $value, in: -300...300, step: 50)
                    .tint(theme.accent)
                    .padding(.horizontal, 24)

                HStack(spacing: 10) {
                    quick("-100")
                    quick("-50")
                    quick("归零")
                    quick("+50")
                    quick("+100")
                }
                .padding(.horizontal, 20)

                VStack(alignment: .leading, spacing: 8) {
                    Label("声音比画面晚，就调正数把声音再往后推；声音比画面早，调负数。", systemImage: "ear")
                    Label("设置非零偏移后会自动用 VLC 内核重新加载本视频。", systemImage: "arrow.triangle.2.circlepath")
                    Label("偏移按当前耳机 / 音箱分别记住，换设备互不影响。", systemImage: "headphones")
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 24)
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button {
                    AudioSyncStore.set(Int(value))
                    Haptics.success()
                    onApply(Int(value))
                    dismiss()
                } label: {
                    Text("应用并重新加载")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(theme.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            .background(theme.bg.ignoresSafeArea())
            .navigationTitle("音画同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                value = Double(AudioSyncStore.offset())
                deviceName = AudioSyncStore.device.name
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func quick(_ text: String) -> some View {
        Button {
            switch text {
            case "归零": value = 0
            case "-100": value = max(-300, value - 100)
            case "-50": value = max(-300, value - 50)
            case "+50": value = min(300, value + 50)
            case "+100": value = min(300, value + 100)
            default: break
            }
            Haptics.light()
        } label: {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
