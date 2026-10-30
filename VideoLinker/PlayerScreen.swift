import SwiftUI
import AVKit
import AVFoundation
import UIKit

// MARK: - 播放请求

/// 队列里的一个条目
struct PlaybackItem: Identifiable, Hashable {
    var id: String { url }
    let url: String
    let title: String?
}

/// 一次播放请求：单条链接，或者一个带起始位置的队列
struct PlayRequest: Identifiable {
    let id = UUID()
    let items: [PlaybackItem]
    let startIndex: Int

    init(url: URL) {
        self.items = [PlaybackItem(url: url.absoluteString, title: nil)]
        self.startIndex = 0
    }

    init(items: [PlaybackItem], startIndex: Int) {
        self.items = items.isEmpty ? [] : items
        let safeCount = max(1, items.count)
        self.startIndex = min(max(0, startIndex), safeCount - 1)
    }
}

// MARK: - 播放页

struct PlayerScreen: View {
    let request: PlayRequest

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PlayerModel()
    @State private var index: Int
    @State private var showMoreActions = false
    @State private var isTheater = false

    init(request: PlayRequest) {
        self.request = request
        _index = State(initialValue: request.startIndex)
    }

    private var currentItem: PlaybackItem? {
        request.items.indices.contains(index) ? request.items[index] : nil
    }

    private var currentURL: URL? {
        guard let string = currentItem?.url else { return nil }
        return URL(string: string)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerViewControllerView(player: model.player)
                .ignoresSafeArea()

            if model.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.3)
                    Text("正在加载…")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            if let message = model.errorMessage {
                errorCard(message)
            }

            VStack {
                topBar
                Spacer()
            }
        }
        .statusBarHidden(true)
        .onAppear {
            loadCurrent()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        .onDisappear {
            model.onFinished = nil
            model.stop()
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            // 离开播放页必须解锁，否则整个 App 会卡在横屏
            isTheater = false
            OrientationLock.apply(.portrait)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
        ) { _ in
            // 用户自己把手机竖回来时，退出全屏状态
            if isTheater, UIDevice.current.orientation.isPortrait {
                leaveTheater()
            }
        }
        .confirmationDialog("更多操作", isPresented: $showMoreActions, titleVisibility: .visible) {
            if request.items.count > 1 {
                Button("上一个") { step(by: -1) }
                    .disabled(index == 0)
                Button("下一个") { step(by: 1) }
                    .disabled(index >= request.items.count - 1)
            }
            Button("用 Safari 打开原始链接") { openInSafari() }
            Button("复制链接") { copyCurrentLink() }
            Button("重新加载") { loadCurrent() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 顶部控制条

    private var topBar: some View {
        ZStack {
            if isTheater {
                HStack(spacing: 12) {
                    Spacer()
                    circleButton("arrow.down.right.and.arrow.up.left") { leaveTheater() }
                }
            } else {
                HStack(spacing: 12) {
                    circleButton("xmark") { dismiss() }
                    Spacer()
                    circleButton("arrow.up.left.and.arrow.down.right") { enterTheater() }
                    circleButton("ellipsis") { showMoreActions = true }
                }
            }

            if request.items.count > 1 && !isTheater {
                VStack(spacing: 2) {
                    Text("\(index + 1) / \(request.items.count)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    if let title = currentItem?.title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                            .frame(maxWidth: 180)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.yellow)
            Text("无法播放")
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("重试") { loadCurrent() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.14), in: Capsule())

                Button("用 Safari 打开") { openInSafari() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(22)
        .frame(maxWidth: 300)
        .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: 播放控制

    private func loadCurrent() {
        guard let url = currentURL else { return }
        model.onFinished = { advance() }
        model.load(url)
    }

    private func advance() {
        guard index + 1 < request.items.count else { return }
        index += 1
        loadCurrent()
    }

    private func step(by offset: Int) {
        let target = index + offset
        guard request.items.indices.contains(target) else { return }
        index = target
        loadCurrent()
    }

    // MARK: 全屏

    /// 点一下直接把画面铺满并转成横屏，退出时再转回来
    private func enterTheater() {
        guard currentURL != nil else { return }
        withAnimation(.easeInOut(duration: 0.2)) { isTheater = true }
        OrientationLock.apply(.landscape)
    }

    private func leaveTheater() {
        withAnimation(.easeInOut(duration: 0.2)) { isTheater = false }
        OrientationLock.apply(.portrait)
    }

    private func openInSafari() {
        guard let url = currentURL else { return }
        UIApplication.shared.open(url)
    }

    private func copyCurrentLink() {
        guard let url = currentURL else { return }
        UIPasteboard.general.string = url.absoluteString
    }
}

// MARK: - AVPlayerViewController 封装

/// 用系统播放器而不是 SwiftUI 的 VideoPlayer，
/// 这样才拿得到画中画、AirPlay、外挂字幕和完整的播放控制条。
struct PlayerViewControllerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.videoGravity = .resizeAspect
        controller.updatesNowPlayingInfoCenter = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}

// MARK: - 播放状态管理

final class PlayerModel: ObservableObject {
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?

    /// 当前视频自然播放结束时回调，用于队列连播
    var onFinished: (() -> Void)?

    let player = AVPlayer()

    private var statusObserver: NSKeyValueObservation?
    private var timeoutWorkItem: DispatchWorkItem?
    private var endObserver: NSObjectProtocol?

    init() {
        player.actionAtItemEnd = .pause
    }

    func load(_ url: URL) {
        configureAudioSession()

        statusObserver?.invalidate()
        timeoutWorkItem?.cancel()
        removeEndObserver()

        isLoading = true
        errorMessage = nil

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 4

        // KVO 回调可能在任意线程，统一切回主线程改 @Published
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            let status = observedItem.status
            let failureReason = observedItem.error
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch status {
                case .readyToPlay:
                    self.isLoading = false
                    self.errorMessage = nil
                    self.timeoutWorkItem?.cancel()
                    self.player.play()
                case .failed:
                    self.isLoading = false
                    self.errorMessage = Self.describe(failureReason)
                default:
                    break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.onFinished?()
        }

        player.replaceCurrentItem(with: item)
        player.play()

        // 有些链接会一直卡在等待状态，兜一个超时提示
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isLoading else { return }
            self.isLoading = false
            self.errorMessage = "加载超时。链接可能已失效、需要登录，或该地址不允许被外部播放器访问。"
        }
        timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: workItem)
    }

    func stop() {
        timeoutWorkItem?.cancel()
        statusObserver?.invalidate()
        statusObserver = nil
        removeEndObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func removeEndObserver() {
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    private static func describe(_ error: Error?) -> String {
        guard let error = error as NSError? else {
            return "这个地址没能识别出视频内容。"
        }
        switch error.code {
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorFileDoesNotExist:
            return "服务器找不到这个文件，可能链接已失效。"
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "网络连接异常，请检查网络后重试。"
        case NSURLErrorTimedOut:
            return "连接超时，服务器没有响应。"
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "这是 http 明文链接，已被系统安全策略拦截。"
        default:
            return "视频格式不受支持，或链接不是可直接播放的媒体地址。\n（\(error.localizedDescription)）"
        }
    }
}
