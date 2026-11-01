import SwiftUI
import UIKit
import CoreImage

/// 设置 → 局域网投屏：开一个只读 HTTP 服务，电脑浏览器就能看手机里的视频
struct LANShareView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @ObservedObject private var server = LANShareServer.shared
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                ScrollView {
                    VStack(spacing: 16) {
                        statusCard
                        permissionCard
                        if server.running {
                            addressCard
                        }
                        tipsCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("局域网投屏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.navBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .padding(.bottom, 28)
                    .transition(.opacity)
            }
        }
        .onAppear {
            // 进来就问一次权限，别等用户开了服务才发现电脑连不上
            if server.permission == .unknown {
                server.probePermission()
            }
        }
    }

    // MARK: 卡片

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(server.running ? theme.accent.opacity(0.16) : theme.field)
                        .frame(width: 42, height: 42)
                    Image(systemName: server.running ? "wifi.router.fill" : "wifi.router")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(server.running ? theme.accent : theme.textTertiary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(server.running ? "正在广播" : "未开启")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text(server.running
                         ? "\(server.fileCount) 个视频 · \(server.clientCount) 台设备连着"
                         : "打开后电脑浏览器就能看手机里的视频")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.textSecondary)
                }

                Spacer(minLength: 8)

                Toggle("", isOn: Binding(
                    get: { server.running },
                    set: { on in
                        if on {
                            server.start()
                        } else {
                            server.stop()
                        }
                    }
                ))
                .labelsHidden()
                .tint(theme.accent)
            }

            if !server.errorText.isEmpty {
                Text(server.errorText)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: server.permission.isOK ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(server.permission.isOK ? Color.green : Color.orange)

                Text("本地网络权限")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)

                Spacer(minLength: 8)

                Text(server.permission.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(server.permission.isOK ? Color.green : theme.textSecondary)
            }

            if !server.permission.isOK {
                Text(permissionHint)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    server.probePermission()
                } label: {
                    actionLabel(
                        server.permission == .checking ? "等待你点弹窗…" : "点这里申请权限",
                        icon: "hand.raised",
                        filled: false
                    )
                }
                .buttonStyle(.plain)
                .disabled(server.permission == .checking)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private var permissionHint: String {
        switch server.permission {
        case .granted:
            return ""
        case .checking:
            return "已经在请求系统权限，如果屏幕中间弹出「允许访问本地网络」，点「允许」。"
        case .denied:
            return "权限被拒绝了，电脑会连不上。去 设置 → 隐私与安全性 → 本地网络，把「视频链接播放器」打开（iOS 17 及更早在 设置 → 视频链接播放器 最下面）。打开后回来点一次下面的按钮重新检测。"
        case .timeout, .unknown:
            return "只开监听端口系统不会弹窗，必须主动问一次。点下面按钮会触发系统弹窗；如果一直没反应，说明之前被静默拒绝过，需要去 设置 → 隐私与安全性 → 本地网络 里手动打开。"
        }
    }

    private var selfCheckText: String {
        switch server.selfCheck {
        case .idle:
            return ""
        case .running:
            return "自检中：手机正在访问自己的地址…"
        case .ok:
            return "自检通过：手机自己请求了一次，页面正常返回"
        case .failed:
            return "自检失败：手机自己都读不到页面，先看上面的本地网络权限"
        }
    }

    private var addressCard: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("在电脑浏览器里打开")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)

                Text(server.address)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.accent)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .padding(.top, 18)

            if server.selfCheck != .idle {
                HStack(spacing: 6) {
                    Circle()
                        .fill(server.selfCheck == .ok
                              ? Color.green
                              : (server.selfCheck == .failed ? Color.orange : theme.textTertiary))
                        .frame(width: 6, height: 6)

                    Text(selfCheckText)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, -8)
            }

            if let image = qrImage(server.address) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 150, height: 150)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = server.address
                    showToast("地址已复制")
                } label: {
                    actionLabel("复制地址", icon: "doc.on.doc", filled: true)
                }
                .buttonStyle(.plain)

                Button {
                    server.refresh()
                    showToast("已刷新，现在 \(server.fileCount) 个视频")
                } label: {
                    actionLabel("刷新列表", icon: "arrow.clockwise", filled: false)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            tip("wifi", "手机和电脑要在同一个 Wi-Fi，访客网络经常互相隔离")
            tip("iphone.gen3", "保持 App 在前台，切到后台系统会挂起服务")
            tip("lock.shield", "电脑开了防火墙或代理，可能要先放行局域网访问")
            tip("play.rectangle", "MP4 / MOV 在浏览器里直接播；MKV、FLV 可能只给下载")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    // MARK: 零件

    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
                .frame(width: 16)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func actionLabel(_ text: String, icon: String, filled: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(filled ? .white : theme.text)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(
            filled ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(theme.field),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func qrImage(_ text: String) -> UIImage? {
        guard !text.isEmpty, let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext(options: nil)
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toast == text {
                withAnimation(.easeIn(duration: 0.2)) { toast = nil }
            }
        }
    }
}
