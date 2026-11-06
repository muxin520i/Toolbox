import SwiftUI

// MARK: - 多设备同步

struct SyncView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @ObservedObject private var sync = SyncStore.shared

    @State private var toast: String?
    @State private var errorText: String?
    @State private var showWebDAV = false
    @State private var confirmDownload = false

    private var configured: Bool {
        WebDAVConfig.load().isUsable
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                ScrollView {
                    VStack(spacing: 16) {
                        statusCard
                        actionCard
                        rulesCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 40)
                }

                if let toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.78), in: Capsule())
                            .padding(.bottom, 28)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("多设备同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showWebDAV) {
                WebDAVView()
            }
            .confirmationDialog("用远端覆盖本机？", isPresented: $confirmDownload, titleVisibility: .visible) {
                Button("拉取并合并", role: .destructive) {
                    run { try await sync.downloadOnly() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只把 WebDAV 上的数据合并进来，不会上传本机内容。")
            }
            .task {
                if !configured {
                    showWebDAV = true
                }
            }
        }
    }

    private var statusCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(configured ? Color(red: 0.20, green: 0.78, blue: 0.45)
                                         : Color(red: 0.95, green: 0.65, blue: 0.25))
                        .frame(width: 8, height: 8)
                    Text(configured ? "已连接 WebDAV" : "还没有配置 WebDAV")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Spacer(minLength: 0)
                    Button(configured ? "修改" : "去配置") {
                        showWebDAV = true
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.accent)
                }

                if configured {
                    Text(WebDAVConfig.load().baseURL)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }

                Divider().overlay(theme.cardStroke)

                HStack {
                    Text("上次同步")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    Text(lastSyncText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.text)
                }

                if let message = sync.lastMessage, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var actionCard: some View {
        card {
            VStack(spacing: 12) {
                Button {
                    run { try await sync.sync() }
                } label: {
                    HStack(spacing: 7) {
                        if sync.syncing {
                            ProgressView().tint(.white).scaleEffect(0.85)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(sync.syncing ? "同步中…" : "立即同步")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(theme.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(sync.syncing || !configured)

                HStack(spacing: 10) {
                    smallButton("只上传本机", symbol: "arrow.up.circle") {
                        run { try await sync.uploadOnly() }
                    }
                    smallButton("只拉取远端", symbol: "arrow.down.circle") {
                        confirmDownload = true
                    }
                }

                if let errorText {
                    Text(errorText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(red: 0.95, green: 0.36, blue: 0.36))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var rulesCard: some View {
        card {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.accent)
                    Text("怎么合并")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.text)
                }

                bullet("同一条内容两边都有时，取时间更新的那份")
                bullet("播放列表按条目合并，两边不同集数会拼到一起")
                bullet("删除不会同步：一端删掉的东西，另一端同步后会回来")
                bullet("视频文件不传，只同步列表、备忘、书签和进度")
            }
        }
    }

    // MARK: 动作

    private func run(_ task: @escaping () async throws -> String) {
        guard !sync.syncing else { return }
        errorText = nil
        Task {
            do {
                let message = try await task()
                showToast(message)
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                showToast("同步失败")
            }
        }
    }

    private var lastSyncText: String {
        guard let date = sync.lastSync else { return "还没同步过" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: 组件

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.cardStroke, lineWidth: 1)
            )
    }

    private func smallButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(theme.text)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(sync.syncing || !configured)
        .opacity(sync.syncing || !configured ? 0.5 : 1)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(theme.textTertiary)
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation { toast = nil }
        }
    }
}
