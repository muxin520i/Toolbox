import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - 局域网互传

struct LANTransferView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var transfer = LANTransfer.shared
    @ObservedObject private var inbox = LANInbox.shared

    @State private var showPicker = false
    @State private var pendingPeer: LANTransfer.Peer?
    @State private var preparing = false
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                ScrollView {
                    VStack(spacing: 14) {
                        receiveCard
                        sendCard
                        deviceSection
                        if !transfer.jobs.isEmpty { jobSection }
                        tipsCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 40)
                }

                if preparing {
                    Color.black.opacity(0.28).ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在准备文件…")
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                    }
                    .padding(20)
                    .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if let toast = toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.8), in: Capsule())
                            .padding(.bottom, 30)
                    }
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("局域网互传")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showPicker,
                allowedContentTypes: [.audiovisualContent, .data],
                allowsMultipleSelection: true
            ) { result in
                guard let peer = pendingPeer else { return }
                pendingPeer = nil
                switch result {
                case .success(let urls):
                    prepareAndSend(urls, to: peer)
                case .failure(let error):
                    showToast(error.localizedDescription)
                }
            }
        }
        .onAppear {
            transfer.startBrowsing()
            if !inbox.running {
                // 打开页面就先广播，不然对方那边看不到自己
                inbox.start()
            }
        }
        .onDisappear {
            transfer.stopBrowsing()
        }
    }

    // MARK: 接收

    private var receiveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(inbox.running ? theme.accent.opacity(0.16) : theme.field)
                        .frame(width: 42, height: 42)
                    Image(systemName: inbox.running ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(inbox.running ? theme.accent : theme.textTertiary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(inbox.running ? "可以让对方发给我" : "接收已关闭")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text(inbox.running
                         ? "本机在附近设备里显示为「\(deviceName)」"
                         : "打开后另一台手机才能在列表里看到这台")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 6)

                Toggle("", isOn: Binding(
                    get: { inbox.running },
                    set: { on in
                        on ? inbox.start() : inbox.stop()
                        Haptics.light()
                    }
                ))
                .labelsHidden()
                .tint(theme.accent)
            }

            if inbox.running, !inbox.address.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accent)
                    Text(inbox.address)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Text("电脑也能用")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(10)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if !inbox.errorText.isEmpty {
                Text(inbox.errorText)
                    .font(.system(size: 11))
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

    // MARK: 发送

    private var sendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text("发文件")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer()
                if transfer.browsing {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                        Text("搜索中")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }

            Text("先在上面把「接收」打开，然后点某个设备右边的「发送」，选视频或文件。两台手机要连同一个 Wi-Fi。")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !transfer.errorText.isEmpty {
                Text(transfer.errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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

    // MARK: 设备

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("附近的设备")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .padding(.leading, 2)

            if transfer.peers.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textTertiary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("还没看到别的设备")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                        Text("让对方打开工具箱 → 设置 → 局域网互传，并打开「接收」")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ForEach(transfer.peers) { peer in
                    peerRow(peer)
                }
            }
        }
    }

    private func peerRow(_ peer: LANTransfer.Peer) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 18))
                .foregroundStyle(theme.accent)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(peer.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text("\(peer.host):\(peer.port)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer(minLength: 6)

            Button {
                pendingPeer = peer
                showPicker = true
            } label: {
                Text("发送")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Capsule().fill(theme.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(13)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
    }

    // MARK: 传输记录

    private var jobSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("传输记录")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button("清空已结束") {
                    transfer.clearFinished()
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.accent)
            }
            .padding(.horizontal, 2)

            ForEach(transfer.jobs) { job in
                jobRow(job)
            }
        }
    }

    private func jobRow(_ job: LANTransfer.Job) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: symbol(for: job.state))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color(for: job.state))

                Text(job.fileName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(job.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(color(for: job.state))
            }

            if job.state == .sending {
                ProgressView(value: min(max(job.progress, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(theme.accent)
            }

            Text("→ \(job.peerName)")
                .font(.system(size: 10))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(12)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func symbol(for state: LANTransfer.Job.State) -> String {
        switch state {
        case .waiting: return "clock"
        case .sending: return "arrow.up.circle"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private func color(for state: LANTransfer.Job.State) -> Color {
        switch state {
        case .waiting: return theme.textTertiary
        case .sending: return theme.accent
        case .done: return .green
        case .failed: return .red
        }
    }

    // MARK: 底部说明

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("说明")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)

            tip("收到的文件会直接进「下载」列表，和浏览器下载的一样可以播放、导出。")
            tip("传输时两台手机都要留在前台，锁屏会断。")
            tip("大文件走的是局域网直连，不经过服务器，也不耗流量。")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(theme.textTertiary)
                .frame(width: 3.5, height: 3.5)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 处理

    private var deviceName: String {
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "工具箱" : name
    }

    private func prepareAndSend(_ urls: [URL], to peer: LANTransfer.Peer) {
        guard !urls.isEmpty else { return }
        preparing = true

        Task.detached(priority: .userInitiated) {
            var local: [URL] = []
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("LANOut", isDirectory: true)

            for url in urls {
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }

                let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let dest = folder.appendingPathComponent(url.lastPathComponent)

                try? FileManager.default.copyItem(at: url, to: dest)
                if FileManager.default.fileExists(atPath: dest.path) {
                    local.append(dest)
                } else if url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
                    // 已经在沙箱里（比如从下载列表进来）就不用复制
                    local.append(url)
                }
            }

            await MainActor.run {
                preparing = false
                if local.isEmpty {
                    showToast("文件读不出来，换一个试试")
                } else {
                    transfer.send(urls: local, to: peer)
                    Haptics.medium()
                    showToast("开始发送 \(local.count) 个文件")
                }
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if toast == text {
                withAnimation(.easeIn(duration: 0.2)) { toast = nil }
            }
        }
    }
}
