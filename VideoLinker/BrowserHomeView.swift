import SwiftUI
import UIKit

// MARK: - 主页（Logo + 搜索框 + 常用网站）

struct BrowserHomeView: View {
    @Binding var query: String
    var onSubmit: () -> Void
    var onOpen: (String) -> Void
    var onOpenHistory: () -> Void
    var onOpenBookmarks: () -> Void
    var onAddShortcut: () -> Void
    var onEditShortcut: (Shortcut) -> Void

    @ObservedObject private var shortcuts = ShortcutLibrary.shared
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool
    @State private var hint: String?

    private var isDark: Bool { scheme == .dark }
    private var textColor: Color { FirefoxStyle.text(isDark) }
    private var subColor: Color { FirefoxStyle.sub(isDark) }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 14), count: 4)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 26) {
                logo
                searchField
                topSites

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 20)
            .padding(.top, 30)
            .padding(.bottom, 30)
        }
        .background(FirefoxStyle.bg(isDark))
        .scrollDismissesKeyboard(.interactively)
        .overlay(alignment: .bottom) {
            if let hint = hint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black.opacity(0.8))
                    )
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
    }

    // MARK: Logo

    private var logo: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 1.0, green: 0.45, blue: 0.32),
                                     Color(red: 0.72, green: 0.20, blue: 0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 66, height: 66)
            .shadow(color: Color.black.opacity(isDark ? 0.45 : 0.14), radius: 12, y: 6)

            Text("视频链接")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(textColor)
        }
        .padding(.bottom, 2)
    }

    // MARK: 搜索框

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(subColor)

            TextField(
                "",
                text: $query,
                prompt: Text("搜索或输入网址").foregroundColor(subColor)
            )
            .focused($focused)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .font(.system(size: 16))
            .foregroundStyle(textColor)
            .onSubmit { onSubmit() }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(subColor.opacity(0.7))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    pasteFromClipboard()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 16))
                        .foregroundStyle(subColor)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FirefoxStyle.field(isDark))
        )
    }

    // MARK: 常用网站

    private var topSites: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("常用网站")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(textColor)
                Spacer()
            }

            LazyVGrid(columns: columns, spacing: 18) {
                builtinCell("历史", "clock.fill", Color(red: 0.20, green: 0.78, blue: 0.72), onOpenHistory)
                builtinCell("书签", "book.fill", Color(red: 0.98, green: 0.45, blue: 0.55), onOpenBookmarks)

                ForEach(shortcuts.items) { item in
                    shortcutCell(item)
                }

                addCell
            }
        }
    }

    private func builtinCell(_ title: String, _ symbol: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(color.opacity(isDark ? 0.92 : 1))
                    Image(systemName: symbol)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(height: 56)

                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(subColor)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private func shortcutCell(_ item: Shortcut) -> some View {
        Button {
            onOpen(item.url)
        } label: {
            VStack(spacing: 7) {
                iconTile(item)
                Text(item.displayTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(subColor)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onOpen(item.url)
            } label: {
                Label("打开", systemImage: "arrow.up.right")
            }
            Button {
                onEditShortcut(item)
            } label: {
                Label("编辑", systemImage: "square.and.pencil")
            }
            Button {
                ShortcutLibrary.shared.moveToFront(item)
            } label: {
                Label("移到最前", systemImage: "arrow.up.to.line")
            }
            Button(role: .destructive) {
                ShortcutLibrary.shared.remove(item)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func iconTile(_ item: Shortcut) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FirefoxStyle.card(isDark))

            AsyncImage(url: item.iconURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    Text(item.initial)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BrowserHomeView.color(item.colorIndex))
                }
            }
        }
        .frame(height: 56)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(FirefoxStyle.line(isDark), lineWidth: 0.8)
        )
    }

    private var addCell: some View {
        Button {
            onAddShortcut()
        } label: {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(FirefoxStyle.field(isDark))
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(subColor)
                }
                .frame(height: 56)

                Text("添加")
                    .font(.system(size: 11))
                    .foregroundStyle(subColor)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 动作

    private func pasteFromClipboard() {
        let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            show("剪贴板是空的")
            return
        }
        query = text
        focused = false
        onSubmit()
    }

    private func show(_ text: String) {
        hint = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if hint == text { hint = nil }
        }
    }

    // MARK: 配色

    private static let palette: [Color] = [
        Color(red: 0.20, green: 0.78, blue: 0.72),
        Color(red: 0.98, green: 0.45, blue: 0.55),
        Color(red: 0.72, green: 0.35, blue: 0.24),
        Color(red: 0.96, green: 0.64, blue: 0.22),
        Color(red: 0.36, green: 0.62, blue: 0.90),
        Color(red: 0.55, green: 0.36, blue: 0.86),
        Color(red: 0.25, green: 0.65, blue: 0.45),
        Color(red: 0.85, green: 0.36, blue: 0.42)
    ]

    static func color(_ index: Int) -> Color {
        palette[abs(index) % palette.count]
    }
}
