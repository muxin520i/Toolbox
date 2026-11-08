import SwiftUI
import UIKit

// MARK: - 媒体服务器面板
//
// 打开后手机变成一台 DLNA 媒体服务器，电视 / 投影 / 电脑播放器
// 在同一 Wi-Fi 下的「媒体服务器」列表里能看到「工具箱影库」，
// 直接浏览 App 里的视频并播放。离开这一页不会自动关，方便投着看完。

struct MediaServerView: View {
    @ObservedObject private var server = MediaLibraryServer.shared
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var enabled = false
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                List {
                    Section {
                        Toggle("开启媒体服务器", isOn: $enabled)
                            .tint(theme.accent)
                            .onChange(of: enabled) { value in
                                if value {
                                    LocalNetworkPermission.probe { _ in }
                                    server.start()
                                } else {
                                    server.stop()
                                }
                            }

                        if server.running {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 7, height: 7)
                                Text("正在共享 \(server.sharedCount) 个视频")
                                    .font(.system(size: 13))
                                    .foregroundStyle(theme.text)
                                Spacer()
                            }
                        }

                        if !server.errorText.isEmpty {
                            Text(server.errorText)
                                .font(.system(size: 12))
                                .foregroundStyle(.orange)
                        }
                    } header: {
                        Text("状态")
                    } footer: {
                        Text("离开这一页不会自动关闭，电视正在播也能继续供片；不用时回来关掉即可。")
                    }

                    if server.running {
                        Section {
                            Button {
                                UIPasteboard.general.string = server.address
                                toast = "地址已复制"
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("设备描述地址")
                                            .font(.system(size: 13))
                                            .foregroundStyle(theme.text)
                                        Text(server.address)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(theme.textTertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 13))
                                        .foregroundStyle(theme.accent)
                                }
                            }
                            .buttonStyle(.plain)

                            Button {
                                server.refresh()
                                toast = "正在重新扫描媒体库"
                            } label: {
                                HStack {
                                    Text("刷新媒体库")
                                        .font(.system(size: 13))
                                        .foregroundStyle(theme.text)
                                    Spacer()
                                    Text("\(server.sharedCount) 个")
                                        .font(.system(size: 11))
                                        .foregroundStyle(theme.textTertiary)
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 12))
                                        .foregroundStyle(theme.accent)
                                }
                            }
                            .buttonStyle(.plain)
                        } header: {
                            Text("连接信息")
                        } footer: {
                            Text("电视搜不到时，可以在电视的「手动添加媒体服务器」里填上面的地址（去掉 http:// 和路径，只填 IP:端口）。")
                        }

                        Section {
                            Label("电视 / 投影仪打开「媒体服务器」或「网络播放器」", systemImage: "1.circle")
                            Label("列表里选「工具箱影库」", systemImage: "2.circle")
                            Label("进「全部视频」或按文件夹浏览，点开即播", systemImage: "3.circle")
                        } header: {
                            Text("怎么用")
                        } footer: {
                            Text("手机和电视必须在同一个 Wi-Fi；第一次连接时系统会问「允许访问本地网络」，要点允许。只共享 App 文档目录里的视频，不会碰相册和别的地方。")
                        }

                        Section {
                            Text("mp4 / mov / mkv / ts / avi / webm / mp3 等常见格式都列出来。电视能不能播，取决于它自己支持的编码；放不了的话换 mp4 通常就行。")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textTertiary)
                        } header: {
                            Text("说明")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)

                if let toast {
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
                    .transition(.opacity)
                }
            }
            .navigationTitle("媒体服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.navBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(theme.accent)
                }
            }
            .onAppear {
                enabled = server.running
                if !server.running {
                    enabled = true
                    LocalNetworkPermission.probe { _ in }
                    server.start()
                }
            }
            .onChange(of: toast) { value in
                guard value != nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    toast = nil
                }
            }
        }
    }
}
