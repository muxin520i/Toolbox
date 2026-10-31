import SwiftUI
import UIKit

/// 播放页「技术信息」：容器、编码、码率、帧率、色彩，能读多少显示多少
struct MediaInfoSheet: View {
    let url: URL
    let engine: String
    var durationHint: Double?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var spec: MediaSpec?
    @State private var loading = true
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()
                content
            }
            .navigationTitle("技术信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.navBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        guard let spec else { return }
                        UIPasteboard.general.string = spec.plainText
                        showToast("已复制全部信息")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .disabled(spec == nil)
                }
            }
        }
        .task {
            spec = await MediaSpecReader.read(url: url, engine: engine, durationHint: durationHint)
            loading = false
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .padding(.bottom, 26)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在读取轨道信息…")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let spec {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summaryCard(spec)

                    ForEach(spec.video) { track in
                        videoCard(track)
                    }

                    ForEach(spec.audio) { track in
                        audioCard(track)
                    }

                    if let note = spec.note {
                        noteCard(note)
                    }

                    sourceCard(spec)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 34)
            }
        } else {
            Text("读不出信息")
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 卡片

    private func summaryCard(_ spec: MediaSpec) -> some View {
        card(title: "概览", icon: "film") {
            VStack(spacing: 0) {
                infoRow("文件", spec.fileName)
                divider
                infoRow("容器", spec.container)
                divider
                infoRow("引擎", spec.engine)
                if let size = spec.sizeText {
                    divider
                    infoRow("大小", size)
                }
                if let duration = spec.durationText {
                    divider
                    infoRow("时长", duration)
                }
            }
        }
    }

    private func videoCard(_ track: MediaSpec.VideoTrack) -> some View {
        card(title: "视频轨 \(track.index)", icon: "video") {
            VStack(spacing: 0) {
                infoRow("编码", track.codec)
                divider
                infoRow("分辨率", track.sizeText, highlight: true)
                if let fps = track.fpsText {
                    divider
                    infoRow("帧率", fps)
                }
                if let bitrate = track.bitrateText {
                    divider
                    infoRow("码率", bitrate)
                }
                if let profile = track.profile {
                    divider
                    infoRow("Profile", profile)
                }
                if let color = track.color {
                    divider
                    infoRow("色彩", color)
                }
                if let hdr = track.hdr {
                    divider
                    infoRow("动态范围", hdr, highlight: hdr.contains("HDR") || hdr == "HLG")
                }
                if track.rotation != 0 {
                    divider
                    infoRow("旋转", "\(track.rotation)°")
                }
            }
        }
    }

    private func audioCard(_ track: MediaSpec.AudioTrack) -> some View {
        card(title: "音频轨 \(track.index)", icon: "waveform") {
            VStack(spacing: 0) {
                infoRow("编码", track.codec)
                if let channel = track.channelText {
                    divider
                    infoRow("声道", channel)
                }
                if let sample = track.sampleText {
                    divider
                    infoRow("采样率", sample)
                }
                if let bitrate = track.bitrateText {
                    divider
                    infoRow("码率", bitrate)
                }
                if let language = track.language, !language.isEmpty {
                    divider
                    infoRow("语言", language)
                }
            }
        }
    }

    private func noteCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(theme.textTertiary)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func sourceCard(_ spec: MediaSpec) -> some View {
        card(title: "来源", icon: "link") {
            VStack(alignment: .leading, spacing: 8) {
                Text(spec.urlText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if spec.otherTrackCount > 0 {
                    Text("另有 \(spec.otherTrackCount) 条字幕 / 数据轨")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.vertical, 11)
        }
    }

    // MARK: 小零件

    private func card<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(theme.textSecondary)
            .padding(.leading, 4)

            content()
                .padding(.horizontal, 14)
                .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(theme.cardStroke, lineWidth: 1)
                )
        }
    }

    private var divider: some View {
        Divider().overlay(theme.cardStroke)
    }

    private func infoRow(_ key: String, _ value: String, highlight: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(key)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 72, alignment: .leading)

            Text(value)
                .font(.system(size: 13, weight: highlight ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(highlight ? theme.accent : theme.text)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 11)
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
