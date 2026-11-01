import SwiftUI
import UIKit
import WebKit

// MARK: - 添加账号（网页登录 + 轮询换 token）

struct WBLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var onFinish: (WBAccount) -> Void

    @StateObject private var model = WBLoginModel()
    @State private var variant = "cn"

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                VStack(spacing: 0) {
                    statusBar
                    picker
                    content
                }
            }
            .navigationTitle("添加账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.navBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let url = model.url {
                        Button("浏览器打开") {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
        }
        .task {
            model.start(variant: variant) { account in
                onFinish(account)
                dismiss()
            }
        }
        .onDisappear { model.stop() }
    }

    private var statusBar: some View {
        HStack(spacing: 9) {
            Image(systemName: model.failed ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.failed ? Color.orange : theme.accent)

            Text(model.status)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.card)
    }

    private var picker: some View {
        Picker("", selection: $variant) {
            Text("国内版").tag("cn")
            Text("国际版").tag("ai")
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.card)
        .onChange(of: variant) { value in
            model.start(variant: value) { account in
                onFinish(account)
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let url = model.url {
            WBWebView(url: url)
                .ignoresSafeArea(edges: .bottom)
        } else {
            VStack(spacing: 12) {
                if model.failed {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(theme.textTertiary)

                    Button {
                        model.start(variant: variant) { account in
                            onFinish(account)
                            dismiss()
                        }
                    } label: {
                        Text("重试")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .frame(height: 40)
                            .background(theme.gradient, in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 登录流程

@MainActor
final class WBLoginModel: ObservableObject {
    @Published var url: URL?
    @Published var status = "正在申请登录链接…"
    @Published var failed = false

    private var task: Task<Void, Never>?

    func start(variant: String, onFinish: @escaping (WBAccount) -> Void) {
        task?.cancel()
        url = nil
        failed = false
        status = "正在申请登录链接…"
        task = Task { await run(variant: variant, onFinish: onFinish) }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func run(variant: String, onFinish: @escaping (WBAccount) -> Void) async {
        guard let start = await WBApi.oauthStart(variant: variant) else {
            status = "申请登录链接失败，检查网络后重试"
            failed = true
            return
        }
        if Task.isCancelled { return }

        url = URL(string: start.authUrl)
        status = "在下面用手机号验证码登录，成功后会自动添加，不用手动关"

        // 官方登录页在桌面端是轮询换 token，这里照搬：2.5 秒一次，最多 10 分钟
        for _ in 0..<240 {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if Task.isCancelled { return }

            guard let tokenData = await WBApi.oauthPollToken(variant: variant, state: start.state) else {
                continue
            }

            var token = WBJson.string(tokenData["accessToken"])
            if token.isEmpty { token = WBJson.string(tokenData["access_token"]) }
            let domain = WBJson.string(tokenData["domain"])
            let profile = await WBApi.fetchProfile(
                variant: variant,
                state: start.state,
                token: token,
                domain: domain
            )

            if let account = WBApi.makeAccount(variant: variant, tokenData: tokenData, profile: profile) {
                status = "登录成功，正在保存…"
                onFinish(account)
                return
            }
        }

        status = "等了 10 分钟还没完成登录，关掉重开这一页再试一次"
        failed = true
    }
}

// MARK: - WKWebView 包装

struct WBWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let web = WKWebView(frame: .zero, configuration: config)
        web.allowsBackForwardNavigationGestures = true
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .clear
        context.coordinator.loaded = url
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 只在地址真的换了才重新加载，避免面板刷新把用户填到一半的表单冲掉
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        uiView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: URL?
    }
}
