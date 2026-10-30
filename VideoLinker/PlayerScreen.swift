import SwiftUI
import AVKit
import AVFoundation
import MediaPlayer
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
    @State private var isTheater = false
    @State private var showControls = true
    @State private var showMore = false
    @State private var showSleep = false
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var hint: String?
    @State private var hintTask: DispatchWorkItem?
    @State private var pipController: AVPictureInPictureController?
    @State private var sleepTimer: Timer?
    @State private var sleepDeadline: Date?
    @State private var sleepLeft = ""

    // 手势过程状态
    @State private var dragMode = 0            // 0 未定 1 进度 2 音量
    @State private var dragBaseTime: Double = 0
    @State private var dragBaseVolume: Float = 0

    // 长按 2 倍速
    @State private var boostActive = false
    @State private var boostBase: Double = 1.0
    @State private var boostStart: Date?
    @State private var boostWork: DispatchWorkItem?
    @State private var boostTimer: Timer?

    @AppStorage(SettingsKey.rate) private var lastRate: Double = 1.0
    @AppStorage(SettingsKey.gestures) private var gesturesEnabled = true
    @AppStorage(SettingsKey.autoResume) private var autoResume = true

    private let rates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

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

    private var titleText: String {
        if let t = currentItem?.title, !t.isEmpty { return t }
        guard let u = currentURL else { return "播放中" }
        let name = u.lastPathComponent.removingPercentEncoding ?? ""
        return name.isEmpty ? (u.host ?? "播放中") : name
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerLayerView(player: model.player) { layer in
                setupPictureInPicture(layer)
            }
            .ignoresSafeArea()

            gestureLayer

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
                .allowsHitTesting(false)
            }

            if let message = model.errorMessage {
                errorCard(message)
            }

            controlsOverlay

            if boostActive {
                boostBadge
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            if let hint = hint {
                Text(hint)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .frame(maxHeight: .infinity, alignment: .center)
            }

            // 系统音量控件需要存在于视图层级里，滑动手势才能可靠地改音量
            SystemVolumeSlider()
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
        .statusBarHidden(true)
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            model.rate = lastRate
            loadCurrent()
        }
        .onDisappear {
            saveProgress()
            model.onFinished = nil
            model.onProgress = nil
            model.stop()
            sleepTimer?.invalidate()
            sleepTimer = nil
            boostTimer?.invalidate()
            boostTimer = nil
            cancelScheduledBoost()
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            isTheater = false
            OrientationLock.apply(.portrait)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
        ) { _ in
            if isTheater, UIDevice.current.orientation.isPortrait {
                leaveTheater()
            }
        }
        .confirmationDialog("更多操作", isPresented: $showMore, titleVisibility: .visible) {
            if request.items.count > 1 {
                Button("上一个") { step(by: -1) }.disabled(index == 0)
                Button("下一个") { step(by: 1) }.disabled(index >= request.items.count - 1)
            }
            Button("重新加载") { loadCurrent() }
            Button("复制链接") { copyCurrentLink() }
            Button("用 Safari 打开") { openInSafari() }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("睡眠定时", isPresented: $showSleep, titleVisibility: .visible) {
            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button("\(minutes) 分钟") { startSleep(minutes) }
            }
            if sleepDeadline != nil {
                Button("关闭定时", role: .destructive) { cancelSleep() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 手势层

    private var gestureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(doubleTapGesture)
            .gesture(dragGesture)
            .onTapGesture { toggleControls() }
            .onLongPressGesture(
                minimumDuration: 0.6,
                pressing: { pressing in
                    guard gesturesEnabled else { return }
                    if pressing {
                        scheduleBoost()
                    } else {
                        cancelScheduledBoost()
                        endBoost()
                    }
                },
                perform: {}
            )
    }

    /// 按住 0.45 秒后才进入 2 倍速，避免误触
    private func scheduleBoost() {
        boostWork?.cancel()
        let work = DispatchWorkItem { beginBoost() }
        boostWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func cancelScheduledBoost() {
        boostWork?.cancel()
        boostWork = nil
    }

    private func beginBoost() {
        guard !boostActive else { return }
        boostActive = true
        boostBase = model.rate
        boostStart = Date()
        model.forceRate(2.0)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // 缓冲或重新起播时系统会把 rate 重置，按住期间持续压住；
        // 万一手势中断没收到松手事件，60 秒后自动恢复
        boostTimer?.invalidate()
        boostTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            if let start = boostStart, Date().timeIntervalSince(start) > 60 {
                endBoost()
                return
            }
            model.forceRate(2.0)
        }
    }

    private func endBoost() {
        guard boostActive else { return }
        boostActive = false
        boostStart = nil
        boostTimer?.invalidate()
        boostTimer = nil
        model.forceRate(boostBase)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showHint("已恢复 \(rateText(boostBase))")
        hideHintSoon()
    }

    /// 长按时的醒目提示，让人一眼看出当前在快进
    private var boostBadge: some View {
        VStack(spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 15, weight: .bold))
                Text("2× 快进中")
                    .font(.system(size: 15, weight: .bold))
            }
            Text("松手恢复正常速度")
                .font(.system(size: 10, weight: .medium))
                .opacity(0.72)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
        )
    }

    private var doubleTapGesture: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                guard gesturesEnabled else { return }
                let isLeft = value.location.x < UIScreen.main.bounds.width / 2
                seekRelative(isLeft ? -10 : 10)
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard gesturesEnabled else { return }

                if dragMode == 0 {
                    if abs(value.translation.width) > abs(value.translation.height) {
                        dragMode = 1
                        dragBaseTime = model.currentTime
                    } else {
                        dragMode = 2
                        dragBaseVolume = SystemVolume.current()
                    }
                }

                let height = max(1, UIScreen.main.bounds.height)
                if dragMode == 1 {
                    let duration = model.duration > 0 ? model.duration : 0
                    guard duration > 0 else { return }
                    let delta = Double(value.translation.width) / Double(UIScreen.main.bounds.width) * duration
                    let target = min(max(0, dragBaseTime + delta), duration)
                    showHint("快进 / 快退至 \(Fmt.time(target))")
                    scrubValue = target
                } else if dragMode == 2 {
                    let delta = Float(-value.translation.height / height) * 1.2
                    let v = min(1, max(0, dragBaseVolume + delta))
                    SystemVolume.set(v)
                    showHint("音量 \(Int(v * 100))%")
                }
            }
            .onEnded { _ in
                if dragMode == 1 {
                    model.seek(to: scrubValue)
                }
                dragMode = 0
                hideHintSoon()
            }
    }

    // MARK: 控制条

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar

            Spacer(minLength: 0)

            HStack {
                Spacer()
                playPauseButton
                Spacer()
            }

            Spacer(minLength: 0)

            bottomBar
        }
        .padding(.horizontal, isTheater ? 28 : 18)
        .padding(.top, isTheater ? 14 : 6)
        .padding(.bottom, isTheater ? 18 : 10)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .opacity(showControls ? 1 : 0)
        .allowsHitTesting(showControls)
        .animation(.easeInOut(duration: 0.2), value: showControls)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(titleText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                if request.items.count > 1 {
                    Text("\(index + 1) / \(request.items.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                } else if !sleepLeft.isEmpty {
                    Text(sleepLeft)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Spacer(minLength: 4)

            if !sleepLeft.isEmpty && request.items.count > 1 {
                Text(sleepLeft)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Button {
                isTheater ? leaveTheater() : enterTheater()
            } label: {
                Image(systemName: isTheater
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var playPauseButton: some View {
        Button {
            model.togglePlay()
            scheduleAutoHide()
        } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 66, height: 66)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(showControls ? 1 : 0)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(Fmt.time(scrubbing ? scrubValue : model.currentTime))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 52, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { scrubbing ? scrubValue : model.currentTime },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(1, model.duration),
                    onEditingChanged: { editing in
                        if editing {
                            scrubbing = true
                            scrubValue = model.currentTime
                            showControls = true
                        } else {
                            scrubbing = false
                            model.seek(to: scrubValue)
                            scheduleAutoHide()
                        }
                    }
                )
                .tint(.white)
                .disabled(model.duration <= 0)

                Text(Fmt.time(model.duration))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 52, alignment: .trailing)
            }

            HStack(spacing: 22) {
                Menu {
                    ForEach(rates, id: \.self) { value in
                        Button {
                            selectRate(value)
                        } label: {
                            if abs(model.rate - value) < 0.001 {
                                Label(rateText(value), systemImage: "checkmark")
                            } else {
                                Text(rateText(value))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(rateLabel)
                            .font(.system(size: 13, weight: .bold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .opacity(0.7)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .menuStyle(.button)
                .tint(.white)
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { showControls = true })

                Button {
                    showSleep = true
                    showControls = true
                } label: {
                    Image(systemName: sleepDeadline == nil ? "moon.zzz" : "moon.zzz.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(.plain)

                Button {
                    togglePictureInPicture()
                } label: {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(.plain)

                RoutePickerView()
                    .frame(width: 30, height: 30)

                Spacer(minLength: 0)

                Button {
                    showMore = true
                    showControls = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var rateLabel: String {
        rateText(boostActive ? 2.0 : model.rate)
    }

    private func rateText(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.001 {
            return "\(Int(value))x"
        }
        return String(format: "%.2gx", value)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
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
                Button("用 Safari 打开") { openInSafari() }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(22)
        .frame(maxWidth: 300)
        .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: 提示

    private func showHint(_ text: String) {
        hintTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { hint = text }
    }

    private func hideHintSoon() {
        hintTask?.cancel()
        let task = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.2)) { hint = nil }
        }
        hintTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: task)
    }

    // MARK: 播放逻辑

    private func loadCurrent() {
        guard let url = currentURL else { return }

        model.onFinished = { advance() }
        model.onProgress = { time, duration in
            ResumeStore.save(url: url.absoluteString, position: time, duration: duration)
        }

        var startAt: Double?
        if autoResume, let saved = ResumeStore.position(for: url.absoluteString) {
            startAt = saved
        }

        model.rate = lastRate
        model.load(url, startAt: startAt)

        if let saved = startAt {
            showHint("从上次的 \(Fmt.time(saved)) 继续")
            hideHintSoon()
        }

        scheduleAutoHide()
    }

    private func saveProgress() {
        guard let url = currentURL else { return }
        ResumeStore.save(
            url: url.absoluteString,
            position: model.currentTime,
            duration: model.duration
        )
    }

    private func advance() {
        guard index + 1 < request.items.count else {
            showControls = true
            return
        }
        index += 1
        loadCurrent()
    }

    private func step(by offset: Int) {
        let target = index + offset
        guard request.items.indices.contains(target) else { return }
        index = target
        loadCurrent()
    }

    private func seekRelative(_ delta: Double) {
        let target = max(0, min(model.duration > 0 ? model.duration : .greatestFiniteMagnitude,
                                model.currentTime + delta))
        model.seek(to: target)
        showHint(delta > 0 ? "快进 10 秒" : "后退 10 秒")
        hideHintSoon()
    }

    private func selectRate(_ value: Double) {
        model.forceRate(value)
        lastRate = value
        showHint("\(rateText(value)) 倍速")
        hideHintSoon()
        scheduleAutoHide()
    }

    // MARK: 控制条显隐

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
        }
        if showControls { scheduleAutoHide() }
    }

    private func scheduleAutoHide() {
        guard model.isPlaying else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            if showControls && !scrubbing && model.isPlaying {
                withAnimation(.easeInOut(duration: 0.25)) { showControls = false }
            }
        }
    }

    // MARK: 画中画

    private func setupPictureInPicture(_ layer: AVPlayerLayer) {
        guard pipController == nil,
              AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let controller = AVPictureInPictureController(playerLayer: layer)
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller
    }

    private func togglePictureInPicture() {
        guard let controller = pipController else {
            showHint("这个视频不支持画中画")
            hideHintSoon()
            return
        }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
        scheduleAutoHide()
    }

    // MARK: 睡眠定时

    private func startSleep(_ minutes: Int) {
        sleepTimer?.invalidate()
        sleepDeadline = Date().addingTimeInterval(Double(minutes) * 60)
        sleepLeft = "睡眠 \(minutes) 分钟"

        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            guard let deadline = sleepDeadline else { return }
            let remain = Int(deadline.timeIntervalSinceNow.rounded())
            if remain <= 0 {
                model.pause()
                sleepTimer?.invalidate()
                sleepTimer = nil
                sleepDeadline = nil
                sleepLeft = ""
                showHint("定时结束，已暂停")
                hideHintSoon()
            } else {
                sleepLeft = String(format: "睡眠 %d:%02d", remain / 60, remain % 60)
            }
        }
    }

    private func cancelSleep() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepDeadline = nil
        sleepLeft = ""
    }

    // MARK: 全屏

    private func enterTheater() {
        guard currentURL != nil else { return }
        withAnimation(.easeInOut(duration: 0.2)) { isTheater = true }
        OrientationLock.apply(.landscape)
        scheduleAutoHide()
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

// MARK: - 视频渲染层

/// 直接用 AVPlayerLayer，才能拿到画中画控制器并叠自己的手势
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var onLayerReady: (AVPlayerLayer) -> Void = { _ in }

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        DispatchQueue.main.async { onLayerReady(view.playerLayer) }
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

// MARK: - AirPlay 按钮

struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .white
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - 系统音量

enum SystemVolume {
    static func current() -> Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    static func set(_ value: Float) {
        guard let slider = SystemVolumeSlider.shared.volumeSlider else { return }
        let clamped = min(1, max(0, value))
        DispatchQueue.main.async {
            slider.value = clamped
        }
    }
}

/// 隐藏的 MPVolumeView，只为了拿到底层的 UISlider
struct SystemVolumeSlider: UIViewRepresentable {
    static let shared = Holder()

    final class Holder {
        weak var volumeView: MPVolumeView?
        var volumeSlider: UISlider? {
            volumeView?.subviews.compactMap { $0 as? UISlider }.first
        }
    }

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.showsVolumeSlider = true
        view.alpha = 0.01
        SystemVolumeSlider.shared.volumeView = view
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        SystemVolumeSlider.shared.volumeView = uiView
    }
}

// MARK: - 播放状态管理

final class PlayerModel: ObservableObject {
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var rate: Double = 1.0 {
        didSet {
            player.defaultRate = Float(rate)
            if player.timeControlStatus == .playing {
                player.rate = Float(rate)
            }
        }
    }

    /// 当前视频自然播放结束时回调，用于队列连播
    var onFinished: (() -> Void)?
    /// 每秒回调一次进度，用于保存续播位置
    var onProgress: ((Double, Double) -> Void)?

    let player = AVPlayer()

    private var statusObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var timeControlObserver: NSKeyValueObservation?
    private var timeoutWorkItem: DispatchWorkItem?
    private var pendingSeek: Double?
    private var lastSavedSecond: Double = -100

    init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }
            let seconds = time.seconds
            if seconds.isFinite {
                self.currentTime = max(0, seconds)
            }
            let itemDuration = self.player.currentItem?.duration.seconds ?? 0
            if itemDuration.isFinite, itemDuration > 0 {
                self.duration = itemDuration
            }

            if self.currentTime - self.lastSavedSecond >= 5 {
                self.lastSavedSecond = self.currentTime
                self.onProgress?(self.currentTime, self.duration)
            }
        }

        timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }
    }

    deinit {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
        removeEndObserver()
    }

    func setRate(_ value: Double) {
        forceRate(value)
    }

    /// 强制生效：同时写 defaultRate 和当前 rate，缓冲中也能记住
    func forceRate(_ value: Double) {
        rate = value
        player.defaultRate = Float(value)
        switch player.timeControlStatus {
        case .playing, .waitingToPlayAtSpecifiedRate:
            player.rate = Float(value)
        case .paused:
            if isPlaying {
                player.playImmediately(atRate: Float(value))
            }
        @unknown default:
            break
        }
    }

    func load(_ url: URL, startAt: Double? = nil) {
        configureAudioSession()

        statusObserver?.invalidate()
        timeoutWorkItem?.cancel()
        removeEndObserver()

        isLoading = true
        errorMessage = nil
        currentTime = 0
        duration = 0
        lastSavedSecond = -100
        pendingSeek = startAt

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 4

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
                    self.applyPendingSeek()
                    self.player.play()
                    if self.isPlaying {
                        self.player.rate = Float(self.rate)
                    }
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
        player.rate = Float(rate)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isLoading else { return }
            self.isLoading = false
            self.errorMessage = "加载超时。链接可能已失效、需要登录，或该地址不允许被外部播放器访问。"
        }
        timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: workItem)
    }

    private func applyPendingSeek() {
        guard let target = pendingSeek, target > 1 else { return }
        pendingSeek = nil
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.currentTime = target
            }
        }
    }

    func play() {
        player.play()
        player.rate = Float(rate)
    }

    func pause() {
        player.pause()
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            if player.currentItem != nil {
                player.play()
                player.rate = Float(rate)
            }
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let clamped = max(0, duration > 0 ? min(seconds, duration) : seconds)
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
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
