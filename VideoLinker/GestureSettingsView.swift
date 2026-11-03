import SwiftUI

// MARK: - 手势选项

enum HorizontalGesture: String, CaseIterable, Identifiable {
    case seek, brightness, volume

    var id: String { rawValue }

    var title: String {
        switch self {
        case .seek: return "快进 / 快退"
        case .brightness: return "亮度"
        case .volume: return "音量"
        }
    }
}

enum VerticalGesture: String, CaseIterable, Identifiable {
    case volume, brightness

    var id: String { rawValue }

    var title: String {
        switch self {
        case .volume: return "音量"
        case .brightness: return "亮度"
        }
    }
}

enum DoubleTapAction: String, CaseIterable, Identifiable {
    case seek, playPause

    var id: String { rawValue }

    var title: String {
        switch self {
        case .seek: return "左右快进 / 快退"
        case .playPause: return "播放 / 暂停"
        }
    }
}

// MARK: - 手势与手感设置

struct GestureSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.gestureHorizontal) private var horizontal = HorizontalGesture.seek.rawValue
    @AppStorage(SettingsKey.gestureVertical) private var vertical = VerticalGesture.volume.rawValue
    @AppStorage(SettingsKey.gestureDoubleTap) private var doubleTap = DoubleTapAction.seek.rawValue
    @AppStorage(SettingsKey.gestureDoubleTapSeconds) private var doubleTapSeconds = 10
    @AppStorage(SettingsKey.gestureLongPressRate) private var longPressRate = 2.0
    @AppStorage(SettingsKey.haptics) private var haptics = true
    @AppStorage(SettingsKey.motion) private var motion = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("横向滑动", selection: $horizontal) {
                        ForEach(HorizontalGesture.allCases) { item in
                            Text(item.title).tag(item.rawValue)
                        }
                    }

                    Picker("纵向滑动", selection: $vertical) {
                        ForEach(VerticalGesture.allCases) { item in
                            Text(item.title).tag(item.rawValue)
                        }
                    }
                } header: {
                    Text("滑动")
                } footer: {
                    Text("横向默认调进度，纵向默认调音量。斜着划时按幅度大的那个方向算，不会两边一起动。")
                }

                Section {
                    Picker("双击画面", selection: $doubleTap) {
                        ForEach(DoubleTapAction.allCases) { item in
                            Text(item.title).tag(item.rawValue)
                        }
                    }

                    if doubleTap == DoubleTapAction.seek.rawValue {
                        Picker("每次跳", selection: $doubleTapSeconds) {
                            Text("5 秒").tag(5)
                            Text("10 秒").tag(10)
                            Text("15 秒").tag(15)
                            Text("30 秒").tag(30)
                        }
                    }
                } header: {
                    Text("双击")
                } footer: {
                    Text(doubleTap == DoubleTapAction.seek.rawValue
                         ? "双击左半屏后退、右半屏前进。刚调过音量后的 0.7 秒内不触发，避免误跳。"
                         : "双击任意位置暂停或继续，和点中间那颗按钮一样。")
                }

                Section {
                    Picker("按住画面", selection: $longPressRate) {
                        Text("关闭").tag(0.0)
                        Text("2 倍速").tag(2.0)
                        Text("3 倍速").tag(3.0)
                    }
                } header: {
                    Text("长按")
                } footer: {
                    Text("按住 0.45 秒后临时加速，松手恢复原来的速度。关掉后长按不会再改倍速。")
                }

                Section {
                    Toggle("触感反馈", isOn: $haptics)
                    Toggle("界面动效", isOn: $motion)
                } header: {
                    Text("手感")
                } footer: {
                    Text("关掉触感后按钮不再震动；关掉动效后弹层、按钮缩放等过渡会直接切换，省电一些。")
                }

                Section {
                    Button("恢复默认设置") {
                        horizontal = HorizontalGesture.seek.rawValue
                        vertical = VerticalGesture.volume.rawValue
                        doubleTap = DoubleTapAction.seek.rawValue
                        doubleTapSeconds = 10
                        longPressRate = 2.0
                        haptics = true
                        motion = true
                        Haptics.success()
                    }
                }
            }
            .navigationTitle("手势与手感")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
