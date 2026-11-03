import SwiftUI
import UIKit

// MARK: - 主题

enum AppTheme: String, CaseIterable, Identifiable {
    case system, dark, light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

/// 一套随深浅色切换的语义化配色
struct Theme {
    let isDark: Bool

    init(_ scheme: ColorScheme) {
        isDark = scheme == .dark
    }

    var bg: Color {
        isDark ? Color(red: 0.05, green: 0.05, blue: 0.08)
               : Color(red: 0.96, green: 0.965, blue: 0.98)
    }

    var card: Color {
        isDark ? Color.white.opacity(0.05) : Color.white
    }

    var cardStroke: Color {
        isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.06)
    }

    var text: Color {
        isDark ? Color.white.opacity(0.93) : Color(red: 0.09, green: 0.09, blue: 0.12)
    }

    var textSecondary: Color {
        isDark ? Color.white.opacity(0.55) : Color.black.opacity(0.55)
    }

    var textTertiary: Color {
        isDark ? Color.white.opacity(0.32) : Color.black.opacity(0.38)
    }

    var field: Color {
        isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    var navBg: Color {
        isDark ? Color(red: 0.045, green: 0.045, blue: 0.06)
               : Color(red: 0.97, green: 0.97, blue: 0.98)
    }

    var accent: Color { Color(red: 1.0, green: 0.55, blue: 0.45) }

    var gradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 1.00, green: 0.42, blue: 0.31),
                     Color(red: 0.72, green: 0.20, blue: 0.85)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var gradientTopLeft: LinearGradient {
        LinearGradient(
            colors: [Color(red: 1.00, green: 0.42, blue: 0.31),
                     Color(red: 0.72, green: 0.20, blue: 0.85)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(.dark)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - 跨页通知

extension Notification.Name {
    /// 外观（夜间 / 无图 / 广告拦截）在设置页被改动，需要立刻应用到网页
    static let browserAppearanceChanged = Notification.Name("vl.browserAppearanceChanged")
}

// MARK: - 设置项的键

enum SettingsKey {
    static let theme = "settings.theme"
    static let rate = "settings.rate"
    static let gestures = "settings.gestures"
    static let autoResume = "settings.autoResume"
    static let desktopUA = "settings.desktopUA"
    static let adBlock = "settings.adBlock"
    static let sleepMinutes = "settings.sleepMinutes"
    static let downloadConcurrency = "settings.downloadConcurrency"
    static let subtitleSize = "settings.subtitleSize"

    // 手势与手感
    static let gestureHorizontal = "gesture.horizontal"
    static let gestureVertical = "gesture.vertical"
    static let gestureDoubleTap = "gesture.doubletap"
    static let gestureDoubleTapSeconds = "gesture.doubletap.seconds"
    static let gestureLongPressRate = "gesture.longpress.rate"
    static let haptics = "feel.haptics"
    static let motion = "feel.motion"

    // 列表
    static let gridView = "list.grid"

    // 浏览器
    static let uaMode = "browser.uaMode"
    static let customUA = "browser.customUA"
    static let searchEngine = "browser.searchEngine"
    static let customSearch = "browser.customSearch"
    static let homePage = "browser.homePage"
    static let nightMode = "browser.nightMode"
    static let noImage = "browser.noImage"
    static let fabX = "browser.fab.x"
    static let fabY = "browser.fab.y"
}

// MARK: - 浏览器：UA 与搜索引擎

enum UAMode: String, CaseIterable, Identifiable {
    case mobile, desktop, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mobile: return "移动版"
        case .desktop: return "桌面版"
        case .custom: return "自定义"
        }
    }

    var symbol: String {
        switch self {
        case .mobile: return "iphone"
        case .desktop: return "desktopcomputer"
        case .custom: return "slider.horizontal.3"
        }
    }
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case baidu, bing, google, duckduckgo, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .baidu: return "百度"
        case .bing: return "必应"
        case .google: return "谷歌"
        case .duckduckgo: return "DuckDuckGo"
        case .custom: return "自定义"
        }
    }

    /// 查询词会拼在末尾，自定义模板用 %s 占位
    var template: String {
        switch self {
        case .baidu: return "https://www.baidu.com/s?wd="
        case .bing: return "https://cn.bing.com/search?q="
        case .google: return "https://www.google.com/search?q="
        case .duckduckgo: return "https://duckduckgo.com/?q="
        case .custom: return ""
        }
    }

    static func searchURL(engine: String, custom: String, query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? trimmed

        let mode = SearchEngine(rawValue: engine) ?? .baidu
        if mode == .custom {
            let tpl = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tpl.isEmpty else { return nil }
            if tpl.contains("%s") {
                return tpl.replacingOccurrences(of: "%s", with: encoded)
            }
            return tpl + encoded
        }
        return mode.template + encoded
    }
}

// MARK: - 通用背景

struct BackgroundView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.bg

            Circle()
                .fill(Color(red: 0.85, green: 0.22, blue: 0.35).opacity(theme.isDark ? 0.35 : 0.16))
                .frame(width: 320, height: 320)
                .blur(radius: 110)
                .offset(x: -120, y: -300)

            Circle()
                .fill(Color(red: 0.35, green: 0.20, blue: 0.95).opacity(theme.isDark ? 0.30 : 0.14))
                .frame(width: 300, height: 300)
                .blur(radius: 120)
                .offset(x: 140, y: 120)

            if theme.isDark {
                Color.black.opacity(0.25)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 小工具

enum Fmt {
    /// 秒数转 0:00 / 1:02:03
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// 字节数转 320.5 MB / 1.2 GB
    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "0 MB" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
