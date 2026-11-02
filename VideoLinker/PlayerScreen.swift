import SwiftUI
import AVKit
import AVFoundation
import MediaPlayer
import UIKit
import UniformTypeIdentifiers

// MARK: - 播放请求

/// 队列里的一个条目
struct PlaybackItem: Identifiable, Hashable {
    var id: String { url }
    let url: String
    let title: String?
    /// WebDAV 这类需要认证的源，传 "用户名:密码"，播放器自己转成请求头
    var credential: String? = nil
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
    /// 跟着系统音量变化走的提示条（侧键调音量时显示）
    @StateObject private var volumeMonitor = VolumeMonitor()

    @State private var index: Int
    @State private var isTheater = false
    @State private var showControls = true
    @State private var showMore = false
    @State private var showMediaInfo = false
    @State private var showSleep = false
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    /// 拖动进度条时显示的画面预览
    @State private var scrubPreview: UIImage?
    @State private var previewCache: [Int: UIImage] = [:]
    @State private var previewRequestID = UUID()
    @State private var previewSecond = -1
    @State private var hint: String?
    @State private var hintTask: DispatchWorkItem?
    @State private var pipController: AVPictureInPictureController?
    @State private var sleepTimer: Timer?
    @State private var sleepDeadline: Date?
    @State private var sleepLeft = ""

    // 外挂字幕
    @State private var subtitleCues: [SubtitleCue] = []
    @State private var subtitleName = ""
    @State private var subtitleText = ""
    @State private var subtitleTicker: Timer?
    @State private var showSubtitlePicker = false
    /// 字幕时间轴偏移：正数表示字幕整体往后延，负数表示提前
    @State private var subtitleOffset: Double = 0
    @AppStorage(SettingsKey.subtitleSize) private var subtitleSize = 17.0

    // 观看时长（统计页用）：本次播放累计看了多少秒
    @State private var watchedSeconds: Double = 0
    @State private var lastWatchTime: Double = 0

    // 手势过程状态
    @State private var dragMode = 0            // 0 未定 1 进度 2 音量
    @State private var dragBaseTime: Double = 0
    @State private var dragBaseVolume: Float = 0
    /// 本轮拖动的起点，用来判断是不是新手势
    @State private var dragStartPoint: CGPoint?
    /// 最近一次因为拖动改音量的时间，用来压掉误触发的双击快进
    @State private var lastVolumeTouch: Date?

    // 长按 2 倍速
    @State private var boostActive = false
    @State private var boostBase: Double = 1.0
    @State private var boostStart: Date?
    @State private var boostWork: DispatchWorkItem?
    @State private var boostTimer: Timer?
    /// 长按快进时露 2 秒的提示，之后自己收掉，不一直挡画面
    @State private var boostBadgeVisible = false
    @State private var boostBadgeHideWork: DispatchWorkItem?
    /// 这一按已经被长按快进接管：之后的滑动都当手指抖动，不再调音量/进度
    @State private var boostLocked = false
    /// 这一按里出现过滑动，用来决定松手时由谁收尾
    @State private var boostDragSeen = false

    /// 设置里的「默认播放速度」，只读不写：播放页调倍速不能反过来改默认值
    @AppStorage(SettingsKey.rate) private var defaultRate: Double = 1.0
    /// 本次播放会话的速度。只活在播放页里，退出就丢，下次仍按默认速度起播
    @State private var sessionRate: Double?
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

            // VLC 兜底时用它的画面层盖住 AVPlayerLayer
            if let engine = model.vlcEngine {
                VLCVideoView(engine: engine)
                    .ignoresSafeArea()
            }

            gestureLayer

            subtitleOverlay

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

            // 中间的播放按钮单独一层：缓冲时即使控制条收起来，也要能看到转圈
            centerPlayButton

            if boostBadgeVisible {
                boostBadge
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            // 音量提示：按手机侧键时系统 HUD 被隐藏的 MPVolumeView 顶掉了，这里自己画一个
            if volumeMonitor.visible, dragMode != 2 {
                volumeHUD
                    .padding(.top, isTheater ? 64 : 74)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
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
            model.rate = currentRate
            loadCurrent()
            startSubtitleTicker()
            volumeMonitor.refresh()
        }
        .onDisappear {
            saveProgress()
            flushWatch()
            model.onFinished = nil
            model.onProgress = nil
            model.stop()
            sleepTimer?.invalidate()
            sleepTimer = nil
            boostTimer?.invalidate()
            boostTimer = nil
            cancelScheduledBoost()
            subtitleTicker?.invalidate()
            subtitleTicker = nil
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
            Button("技术信息") { showMediaInfo = true }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showMediaInfo) {
            if let url = currentURL {
                MediaInfoSheet(url: url, engine: engineName, durationHint: model.duration)
            }
        }
        .fileImporter(
            isPresented: $showSubtitlePicker,
            allowedContentTypes: subtitleTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                do {
                    let cues = try SubtitleLoader.load(url: url)
                    subtitleCues = cues
                    subtitleName = url.lastPathComponent
                    subtitleText = ""
                    subtitleOffset = 0
                    toast("已加载字幕：\(url.lastPathComponent)")
                } catch {
                    toast(error.localizedDescription)
                }
            case .failure(let error):
                toast(error.localizedDescription)
            }
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

    // MARK: 字幕

    private var subtitleTypes: [UTType] {
        var types: [UTType] = [.plainText]
        for ext in SubtitleLoader.extensions {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }

    private var subtitleOverlay: some View {
        VStack {
            Spacer()
            if !subtitleText.isEmpty {
                Text(subtitleText)
                    .font(.system(size: CGFloat(subtitleSize), weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.horizontal, 24)
                    .padding(.bottom, showControls ? 150 : 72)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: subtitleText)
        .allowsHitTesting(false)
    }

    private var subtitleOffsetLabel: String {
        if subtitleOffset == 0 { return "无偏移" }
        let value = String(format: "%.1f 秒", abs(subtitleOffset))
        return subtitleOffset > 0 ? "延后 \(value)" : "提前 \(value)"
    }

    /// 字幕音画不同步时手动校准，每次 0.5 秒，上限 30 秒
    private func nudgeSubtitle(_ delta: Double) {
        subtitleOffset = max(-30, min(30, subtitleOffset + delta))
        subtitleText = ""
        showControls = true
        toast("字幕偏移：\(subtitleOffsetLabel)")
    }

    private func startSubtitleTicker() {
        subtitleTicker?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            guard !subtitleCues.isEmpty else {
                if !subtitleText.isEmpty { subtitleText = "" }
                return
            }
            if let cue = SubtitleLoader.cue(at: model.currentTime - subtitleOffset, in: subtitleCues) {
                if cue.text != subtitleText { subtitleText = cue.text }
            } else if !subtitleText.isEmpty {
                subtitleText = ""
            }
        }
        subtitleTicker = timer
    }

    private func autoLoadSubtitle(for url: URL) {
        subtitleOffset = 0
        guard url.isFileURL, let sidecar = SubtitleLoader.findSidecar(for: url) else {
            subtitleCues = []
            subtitleName = ""
            subtitleText = ""
            return
        }
        if let cues = try? SubtitleLoader.load(url: sidecar) {
            subtitleCues = cues
            subtitleName = sidecar.lastPathComponent
            subtitleText = ""
        }
    }

    private func clearSubtitle() {
        subtitleCues = []
        subtitleName = ""
        subtitleText = ""
        subtitleOffset = 0
        toast("已关闭字幕")
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
                        // 新的一次按下：上一按要是没收到松手，先把速度恢复
                        if boostActive { endBoost() }
                        // 清掉上一轮可能残留的锁
                        boostLocked = false
                        boostDragSeen = false
                        scheduleBoost()
                    } else {
                        cancelScheduledBoost()
                        if boostDragSeen {
                            // 手指还在滑，系统可能把长按判成取消。
                            // 这时候先别收，等这一按结束；万一拖动结束事件也没来，0.3 秒后兜底收掉
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                if boostDragSeen { endBoost() }
                            }
                        } else {
                            endBoost()
                        }
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
        // 手指已经在划了（多半是在调音量），不要进 2 倍速
        guard !boostActive, dragMode == 0 else { return }
        boostActive = true
        // 这一按归长按快进管，后面滑动不再响应音量/进度
        boostLocked = true
        boostBase = model.rate
        boostStart = Date()
        model.forceRate(2.0)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // 提示只露 2 秒，之后自己淡出；2 倍速继续生效，不用一直挡着画面
        boostBadgeHideWork?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) { boostBadgeVisible = true }
        let hide = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.3)) { boostBadgeVisible = false }
        }
        boostBadgeHideWork = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: hide)

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
        // 松手就收：提示和 2 倍速一起结束
        boostBadgeHideWork?.cancel()
        boostBadgeHideWork = nil
        withAnimation(.easeInOut(duration: 0.18)) { boostBadgeVisible = false }
        model.forceRate(boostBase)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showHint("已恢复 \(rateText(boostBase))")
        hideHintSoon()
    }

    /// 音量提示条：喇叭图标 + 进度 + 百分比，跟系统 HUD 一个意思
    private var volumeHUD: some View {
        HStack(spacing: 10) {
            Image(systemName: volumeSymbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 22)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.24))
                    .frame(width: 108, height: 5)
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(2, 108 * CGFloat(volumeMonitor.value)), height: 5)
            }

            Text("\(Int((volumeMonitor.value * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(width: 40, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
    }

    private var volumeSymbol: String {
        let v = volumeMonitor.value
        if v <= 0.001 { return "speaker.slash.fill" }
        if v < 0.34 { return "speaker.wave.1.fill" }
        if v < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    /// 长按时的醒目提示，让人一眼看出当前在快进
    private var boostBadge: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 13, weight: .bold))
                Text("2× 快进中")
                    .font(.system(size: 13, weight: .bold))
            }
            Text("松手恢复正常速度")
                .font(.system(size: 9, weight: .medium))
                .opacity(0.72)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
        )
    }

    private var doubleTapGesture: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                guard gesturesEnabled else { return }
                // 刚在调音量：连着两下上下划很容易被认成双击，这时不要跳进度
                if let touch = lastVolumeTouch, Date().timeIntervalSince(touch) < 0.7 { return }
                let isLeft = value.location.x < UIScreen.main.bounds.width / 2
                seekRelative(isLeft ? -10 : 10)
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard gesturesEnabled else { return }

                // 长按 2 倍速已经接管这一按：上下左右怎么滑都不算数，
                // 否则按住快进时音量、进度会跟着乱跳
                if boostLocked {
                    if boostActive {
                        boostDragSeen = true
                        return
                    }
                    // 长按其实已经结束（松手事件丢了），这次滑动按正常处理
                    boostLocked = false
                }

                // 每次新的拖动都重新判方向。用起点区分：上一轮万一被系统打断、没收到 onEnded，
                // dragMode 会留在旧值上，接着滑就会拿旧的模式去快进
                if dragStartPoint != value.startLocation {
                    dragStartPoint = value.startLocation
                    dragMode = 0
                    // 拖起来了就不要再触发长按 2 倍速
                    cancelScheduledBoost()
                    if boostActive { endBoost() }
                }

                if dragMode == 0 {
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    // 留出 1.5 倍余量：斜着划、手抖一下都不会被判成快进
                    if dx > dy * 1.5 {
                        dragMode = 1
                        dragBaseTime = model.currentTime
                        scrubValue = model.currentTime
                    } else if dy > dx * 1.5 {
                        dragMode = 2
                        dragBaseVolume = SystemVolume.current()
                    } else {
                        // 方向还没定下来，这一帧什么都不做
                        return
                    }
                }

                // 方向一旦定下来就是真在划了，长按 2 倍速立刻退出
                if dragMode != 0, boostActive {
                    endBoost()
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
                    lastVolumeTouch = Date()
                    showHint("音量 \(Int(v * 100))%")
                }
            }
            .onEnded { _ in
                if dragMode == 1 {
                    model.seek(to: scrubValue)
                }
                if dragMode == 2 {
                    lastVolumeTouch = Date()
                }
                dragMode = 0
                dragStartPoint = nil
                // 这一按结束：按住快进的 2 倍速在这里收，锁也一起放开
                if boostActive, boostDragSeen { endBoost() }
                boostDragSeen = false
                boostLocked = false
                hideHintSoon()
            }
    }

    // MARK: 控制条

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar

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
            // 渐变只做视觉，不参与点击，避免把整屏点击都吃掉
            .allowsHitTesting(false)
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
                downloadCurrent()
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

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
        // 顶部这一条属于控件区，点空白也不切换显隐（用几乎透明的底把点击拦下来）
        .background(Color.black.opacity(0.001))
    }

    /// 屏幕中间的按钮层。控制条显示时出现；缓冲时不管控制条在不在都显示
    private var centerPlayButton: some View {
        playPauseButton
            .opacity(model.isLoading ? 0 : (showControls || model.isStalling ? 1 : 0))
            .allowsHitTesting(!model.isLoading && (showControls || model.isStalling))
            .animation(.easeInOut(duration: 0.2), value: showControls)
            .animation(.easeInOut(duration: 0.2), value: model.isStalling)
    }

    private var playPauseButton: some View {
        Button {
            let wasBuffering = model.isStalling
            model.togglePlay()
            // 缓冲时按钮本来就露着（控制条可能收起了），点完把控制条带出来，
            // 不然一暂停按钮就消失，屏幕上什么都不剩
            if wasBuffering && !showControls {
                withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 72, height: 72)
                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)

                // 网络卡顿、等数据时换成转圈，别再显示暂停图标，看着像能点却没反应
                if model.isStalling {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.25)
                } else {
                    Image(systemName: model.didReachEnd
                          ? "arrow.counterclockwise"
                          : (model.isPlaying ? "pause.fill" : "play.fill"))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 72, height: 72)
        }
        .buttonStyle(.plain)
    }

    /// 拖动进度条时冒出来的画面预览，松手就收
    private var scrubPreviewCard: some View {
        ZStack {
            if let image = scrubPreview {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.black.opacity(0.4)
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(width: 160, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(0.25), lineWidth: 0.8)
        )
        .overlay(alignment: .bottomTrailing) {
            Text(Fmt.time(scrubValue))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(6)
        }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .allowsHitTesting(false)
    }

    /// 用当前视频的 asset 取指定时间点的画面，按秒缓存，拖动时不至于一卡一卡
    private func requestScrubPreview(at seconds: Double) {
        guard model.duration > 0, !model.usingVLC,
              let asset = model.player.currentItem?.asset else {
            scrubPreview = nil
            return
        }

        let key = Int(seconds.rounded())
        if let cached = previewCache[key] {
            scrubPreview = cached
            return
        }

        let token = UUID()
        previewRequestID = token
        let clamped = max(0, min(seconds, model.duration))
        let time = CMTime(seconds: clamped, preferredTimescale: 600)

        DispatchQueue.global(qos: .userInitiated).async {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 180)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

            guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else {
                DispatchQueue.main.async {
                    // 只清掉这次请求对应的那张，别把用户已经拖到的下一张也清了
                    if previewRequestID == token, previewSecond == key {
                        scrubPreview = nil
                    }
                }
                return
            }

            let image = UIImage(cgImage: cg)
            DispatchQueue.main.async {
                guard previewRequestID == token else { return }
                if previewCache.count > 80 { previewCache.removeAll() }
                previewCache[key] = image
                scrubPreview = image
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if scrubbing {
                scrubPreviewCard
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }

            HStack(spacing: 10) {
                Text(Fmt.time(scrubbing ? scrubValue : model.currentTime))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 52, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { scrubbing ? scrubValue : model.currentTime },
                        set: { value in
                            scrubValue = value
                            let second = Int(value.rounded())
                            if second != previewSecond {
                                previewSecond = second
                                requestScrubPreview(at: value)
                            }
                        }
                    ),
                    in: 0...max(1, model.duration),
                    onEditingChanged: { editing in
                        if editing {
                            scrubbing = true
                            scrubValue = model.currentTime
                            previewSecond = Int(model.currentTime.rounded())
                            requestScrubPreview(at: model.currentTime)
                            showControls = true
                        } else {
                            scrubbing = false
                            previewSecond = -1
                            model.seek(to: scrubValue)
                            withAnimation(.easeOut(duration: 0.15)) { scrubPreview = nil }
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
                    Button {
                        showSubtitlePicker = true
                        showControls = true
                    } label: {
                        Label("载入字幕文件…", systemImage: "doc.text")
                    }

                    if !subtitleCues.isEmpty {
                        Divider()
                        Button {
                            nudgeSubtitle(-0.5)
                        } label: {
                            Label("字幕提前 0.5 秒", systemImage: "gobackward")
                        }
                        Button {
                            nudgeSubtitle(0.5)
                        } label: {
                            Label("字幕延后 0.5 秒", systemImage: "goforward")
                        }
                        if subtitleOffset != 0 {
                            Button {
                                subtitleOffset = 0
                                subtitleText = ""
                                toast("字幕偏移已重置")
                            } label: {
                                Label("重置偏移（\(subtitleOffsetLabel)）", systemImage: "arrow.counterclockwise")
                            }
                        }

                        Divider()
                        Button(role: .destructive) {
                            clearSubtitle()
                        } label: {
                            Label("关闭字幕", systemImage: "xmark.circle")
                        }
                    }
                } label: {
                    Image(systemName: subtitleCues.isEmpty ? "captions.bubble" : "captions.bubble.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 30)
                }
                .menuStyle(.button)
                .tint(.white)
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { showControls = true })

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
        .background(Color.black.opacity(0.001))
    }

    private var rateLabel: String {
        rateText(boostActive ? 2.0 : model.rate)
    }

    /// 当前实际在用的播放内核，技术信息面板里要标明
    private var engineName: String {
        model.vlcEngine == nil ? "AVPlayer" : "VLC"
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

    /// 两秒后自动消失的提示（下载用）
    private func toast(_ text: String) {
        hintTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { hint = text }
        let task = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.2)) { hint = nil }
        }
        hintTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: task)
    }

    /// 下载当前正在播的这个（m3u8 会分片下载再拼成一个文件）
    private func downloadCurrent() {
        guard let item = currentItem, !item.url.isEmpty else { return }

        if item.url.lowercased().hasPrefix("file://") {
            toast("这是本机文件，已经保存在「下载」列表里了")
            return
        }

        switch DownloadManager.shared.start(from: item.url, title: titleText) {
        case .started(let record):
            toast("已加入下载：\(record.fileName)")
        case .failed(let reason):
            toast(reason)
        }
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
            // 只累计正常前进的播放量，拖进度条造成的大跳变不计入
            let delta = time - lastWatchTime
            if delta > 0, delta < 20 { watchedSeconds += delta }
            lastWatchTime = time
        }

        var startAt: Double?
        if autoResume, let saved = ResumeStore.position(for: url.absoluteString) {
            startAt = saved
        }

        model.rate = currentRate
        model.load(url, startAt: startAt, credential: currentItem?.credential)
        lastWatchTime = startAt ?? 0

        // 本地视频旁边有同名 srt/vtt 就自动挂上
        autoLoadSubtitle(for: url)

        if let saved = startAt {
            showHint("从上次的 \(Fmt.time(saved)) 继续")
            hideHintSoon()
        }

    }

    private func saveProgress() {
        guard let url = currentURL else { return }
        ResumeStore.save(
            url: url.absoluteString,
            position: model.currentTime,
            duration: model.duration
        )
    }

    /// 把本次播放的时长记进统计表，切集或退出时调用
    private func flushWatch() {
        let seconds = watchedSeconds
        watchedSeconds = 0
        lastWatchTime = 0
        guard seconds >= 5, let url = currentURL else { return }
        WatchStats.record(url: url.absoluteString, title: titleText, seconds: seconds)
    }

    private func advance() {
        guard index + 1 < request.items.count else {
            showControls = true
            return
        }
        flushWatch()
        index += 1
        loadCurrent()
    }

    private func step(by offset: Int) {
        let target = index + offset
        guard request.items.indices.contains(target) else { return }
        flushWatch()
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

    /// 当前生效的倍速：本次会话改过就用会话值，否则用设置里的默认值
    private var currentRate: Double {
        sessionRate ?? defaultRate
    }

    private func selectRate(_ value: Double) {
        model.forceRate(value)
        sessionRate = value
        showHint("\(rateText(value)) 倍速")
        hideHintSoon()
    }

    // MARK: 控制条显隐

    /// 点一下显示、再点一下隐藏，不做定时自动消失
    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
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
        if model.usingVLC {
            showHint("VLC 兜底的视频暂不支持画中画")
            hideHintSoon()
            return
        }
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

// MARK: - 音量监听

/// 盯着系统音量：按侧键时系统 HUD 因为藏着 MPVolumeView 不显示，改由播放页自己弹一条
final class VolumeMonitor: ObservableObject {
    @Published private(set) var value: Float = 0
    @Published private(set) var visible = false

    private var observation: NSKeyValueObservation?
    private var sliderObservation: NSKeyValueObservation?
    private var hideWork: DispatchWorkItem?

    init() {
        value = AVAudioSession.sharedInstance().outputVolume
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
            let now = session.outputVolume
            DispatchQueue.main.async {
                self?.apply(now, flash: true)
            }
        }
    }

    /// 进播放页时先把当前音量读进来（不弹提示），顺便把滑块也盯上
    func refresh() {
        apply(AVAudioSession.sharedInstance().outputVolume, flash: false)
        observeSliderIfNeeded()
        // MPVolumeView 的滑块是布局之后才生出来的，晚一点再找一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.observeSliderIfNeeded()
        }
    }

    /// 有些系统版本上 outputVolume 的 KVO 不吭声，滑块的 value 变化补上
    private func observeSliderIfNeeded() {
        guard sliderObservation == nil,
              let slider = SystemVolumeSlider.shared.volumeSlider else { return }
        sliderObservation = slider.observe(\.value, options: [.new]) { [weak self] slider, _ in
            let now = slider.value
            DispatchQueue.main.async {
                self?.apply(now, flash: true)
            }
        }
    }

    private func apply(_ raw: Float, flash: Bool) {
        value = min(1, max(0, raw))
        guard flash else { return }

        withAnimation(.easeOut(duration: 0.12)) { visible = true }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) { self?.visible = false }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }
}

// MARK: - 播放状态管理

final class PlayerModel: ObservableObject {
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPlaying = false
    /// 播放中卡住等数据（不是用户自己暂停），中间按钮换成转圈
    @Published private(set) var isStalling = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    /// 当前是不是在用 VLC 兜底
    @Published private(set) var usingVLC = false
    /// 这条已经播到结尾，中间按钮改成「重播」
    @Published private(set) var didReachEnd = false
    @Published var rate: Double = 1.0 {
        didSet {
            if usingVLC {
                vlcEngine?.setRate(rate)
                return
            }
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

    private(set) var vlcEngine: VLCPlayback?

    /// 播的是本机文件：磁盘读取没有网络缓冲那回事，不要显示缓冲转圈
    private(set) var isLocalFile = false

    private var statusObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var timeControlObserver: NSKeyValueObservation?
    private var stallWatch: Timer?
    private var timeoutWorkItem: DispatchWorkItem?
    private var pendingSeek: Double?
    private var lastSavedSecond: Double = -100
    /// 上一拍的时间点，用来判断画面是不是真的在往前走
    private var lastTickSecond: Double = -1

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

            // 兜底校正状态：timeControlStatus 的 KVO 偶尔会漏掉「缓冲结束」这一下，
            // 结果画面已经在播了，中间的转圈还挂着不消失。
            // 时间确实在往前走，就说明已经恢复播放，顺手把转圈收掉。
            if !self.usingVLC, seconds.isFinite {
                let advancing = seconds > self.lastTickSecond + 0.02
                self.lastTickSecond = seconds
                if advancing {
                    if self.isStalling { self.isStalling = false }
                    if !self.isPlaying { self.isPlaying = true }
                }
                // 本机文件永远不显示缓冲转圈
                if self.isLocalFile, self.isStalling { self.isStalling = false }
                // 片子已经准备好了，还挂着整页「正在加载」就是状态回调漏了，直接收掉
                if self.player.currentItem?.status == .readyToPlay, self.isLoading {
                    self.isLoading = false
                }
                // 用户自己按了暂停（或播完停住）：转圈也不该留着
                if self.player.timeControlStatus == .paused,
                   self.isStalling || self.isPlaying {
                    self.isStalling = false
                    self.isPlaying = false
                }
            }

            if self.currentTime - self.lastSavedSecond >= 5 {
                self.lastSavedSecond = self.currentTime
                self.onProgress?(self.currentTime, self.duration)
            }
        }

        timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPlaying = player.timeControlStatus == .playing
                // waitingToPlayAtSpecifiedRate = 想播但数据没跟上，就是缓冲
                // 本机文件不显示缓冲转圈，打开瞬间那一下等待不算卡顿
                self.isStalling = !self.isLocalFile
                    && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self.syncStallWatch()
            }
        }
    }

    deinit {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
        stallWatch?.invalidate()
        removeEndObserver()
    }

    /// 缓冲状态的看门狗：KVO 偶尔会漏掉「缓冲结束」，
    /// 每 0.5 秒对着 player 的真实状态核一次，避免中间的转圈一直挂着
    private func syncStallWatch() {
        guard isStalling, !isLocalFile else {
            stallWatch?.invalidate()
            stallWatch = nil
            return
        }
        guard stallWatch == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard !self.usingVLC else {
                self.stallWatch?.invalidate()
                self.stallWatch = nil
                return
            }
            guard self.player.timeControlStatus != .waitingToPlayAtSpecifiedRate else { return }
            self.isStalling = false
            self.isPlaying = self.player.timeControlStatus == .playing
            self.stallWatch?.invalidate()
            self.stallWatch = nil
        }
        stallWatch = timer
    }

    func setRate(_ value: Double) {
        forceRate(value)
    }

    /// 强制生效：同时写 defaultRate 和当前 rate，缓冲中也能记住
    func forceRate(_ value: Double) {
        rate = value
        if usingVLC {
            vlcEngine?.setRate(value)
            return
        }
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

    func load(_ url: URL, startAt: Double? = nil, credential: String? = nil) {
        configureAudioSession()

        teardownVLC()
        statusObserver?.invalidate()
        timeoutWorkItem?.cancel()
        removeEndObserver()

        isLoading = true
        errorMessage = nil
        isStalling = false
        isLocalFile = url.isFileURL
        stallWatch?.invalidate()
        stallWatch = nil
        currentTime = 0
        duration = 0
        lastSavedSecond = -100
        lastTickSecond = -1
        pendingSeek = startAt
        didReachEnd = false

        // mkv / flv / avi 这些系统播放器基本没戏，直接交给 VLC，省一次失败等待
        if VLCPlayback.isAvailable,
           Self.vlcOnlyExtensions.contains(url.pathExtension.lowercased()) {
            startVLC(url: url, startAt: startAt, credential: credential)
            return
        }

        let item = AVPlayerItem(asset: Self.makeAsset(url: url, credential: credential))
        item.preferredForwardBufferDuration = 4

        statusObserver = item.observe(\.status, options: [.new, .initial]) { [weak self] observedItem, _ in
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
                    if failureReason != nil {
                        print("AVPlayer failed:", failureReason!.localizedDescription)
                    }
                    // 系统播放器不认这个容器，换 VLC 再试一次
                    self.switchToVLC(url: url, startAt: self.pendingSeek, credential: credential)
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
            self?.didReachEnd = true
            self?.onFinished?()
        }

        player.replaceCurrentItem(with: item)
        // 本机文件可能已经准备好了（状态回调不一定赶得上），补一刀，别让「正在加载…」一直转
        if item.status == .readyToPlay {
            isLoading = false
            timeoutWorkItem?.cancel()
            applyPendingSeek()
        }
        player.play()
        player.rate = Float(rate)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isLoading else { return }
            // 超时不直接判死，VLC 对某些流更宽容
            self.switchToVLC(url: url, startAt: self.pendingSeek, credential: credential)
        }
        timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: workItem)
    }

    /// 需要认证的源（WebDAV）走 AVURLAsset，把 Basic 头挂在 asset 上，
    /// AVPlayer 请求主文件和各分片时都会带上。
    private static func makeAsset(url: URL, credential: String?) -> AVURLAsset {
        guard let credential, !credential.isEmpty else { return AVURLAsset(url: url) }
        let token = "Basic " + Data(credential.utf8).base64EncodedString()
        let headers: [String: Any] = ["Authorization": token]
        return AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
        )
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
        if usingVLC {
            vlcEngine?.play()
            return
        }
        player.play()
        player.rate = Float(rate)
    }

    func pause() {
        if usingVLC {
            vlcEngine?.pause()
            return
        }
        // 暂停是明确的用户动作，转圈立刻收掉，不等 KVO
        isStalling = false
        isPlaying = false
        stallWatch?.invalidate()
        stallWatch = nil
        player.pause()
    }

    func togglePlay() {
        // 已经播到结尾：中间按钮点下去就是从 0 重来，而不是在末尾空按一下
        if didReachEnd {
            restart()
            return
        }
        if usingVLC {
            vlcEngine?.togglePlay()
            return
        }
        // 缓冲中也算「在播」，点一下是暂停，不能当成没播去调 play() 白点一下
        if isPlaying || isStalling {
            pause()
        } else {
            if player.currentItem != nil {
                player.play()
                player.rate = Float(rate)
            }
        }
    }

    /// 从头重播当前这条
    func restart() {
        didReachEnd = false
        currentTime = 0
        lastSavedSecond = -100

        if usingVLC {
            vlcEngine?.seek(to: 0)
            vlcEngine?.play()
            return
        }
        player.seek(
            to: .zero,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.player.play()
                self.player.rate = Float(self.rate)
            }
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let clamped = max(0, duration > 0 ? min(seconds, duration) : seconds)
        currentTime = clamped
        // 拖回去一点就不再算「已播完」，中间按钮回到播放/暂停
        if duration <= 0 || clamped < duration - 0.5 {
            didReachEnd = false
        }

        if usingVLC {
            vlcEngine?.seek(to: clamped)
            return
        }
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
        teardownVLC()
        isStalling = false
        isPlaying = false
        stallWatch?.invalidate()
        stallWatch = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - VLC 兜底

    /// 系统播放器处理不了的容器：直接走 VLC 更稳，也更快
    private static let vlcOnlyExtensions: Set<String> = [
        "mkv", "flv", "avi", "rmvb", "rm", "wmv", "webm",
        "m2ts", "mts", "ts", "mpg", "mpeg", "ogv", "3gp", "asf", "vob", "f4v"
    ]

    private func switchToVLC(url: URL, startAt: Double?, credential: String? = nil) {
        guard VLCPlayback.isAvailable else {
            isLoading = false
            errorMessage = "视频格式不受支持，或链接不是可直接播放的媒体地址。"
            return
        }
        guard vlcEngine == nil else {
            isLoading = false
            errorMessage = "这个地址没能识别出视频内容，换台设备或换个源试试。"
            return
        }
        timeoutWorkItem?.cancel()
        statusObserver?.invalidate()
        statusObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        startVLC(url: url, startAt: startAt, credential: credential)
    }

    private func startVLC(url: URL, startAt: Double?, credential: String? = nil) {
        isLoading = true
        errorMessage = nil
        duration = 0
        currentTime = max(0, startAt ?? 0)

        let engine = VLCPlayback()
        engine.onTime = { [weak self] time, total in
            guard let self = self else { return }
            self.currentTime = time
            if total > 0 { self.duration = total }
            if self.currentTime - self.lastSavedSecond >= 5 {
                self.lastSavedSecond = self.currentTime
                self.onProgress?(self.currentTime, self.duration)
            }
        }
        engine.onState = { [weak self] playing, buffering in
            guard let self = self else { return }
            self.isPlaying = playing
            // 首次加载由整页「正在加载…」负责，这里只管播起来之后的卡顿；
            // 本机文件不走网络，不显示缓冲转圈
            self.isStalling = buffering && !self.isLoading && !self.isLocalFile
            if !buffering { self.isLoading = false }
        }
        engine.onEnded = { [weak self] in
            self?.didReachEnd = true
            self?.onFinished?()
        }
        engine.onFailed = { [weak self] message in
            guard let self = self else { return }
            self.isLoading = false
            self.errorMessage = message
        }

        vlcEngine = engine
        usingVLC = true
        engine.load(url, rate: rate, startAt: startAt, credential: credential)
    }

    private func teardownVLC() {
        vlcEngine?.stop()
        vlcEngine = nil
        usingVLC = false
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
