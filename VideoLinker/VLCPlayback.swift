import Foundation
import SwiftUI

#if canImport(VLCKit)
import VLCKit
#elseif canImport(MobileVLCKit)
import MobileVLCKit
#endif

#if canImport(VLCKit) || canImport(MobileVLCKit)

/// AVPlayer 认不出的容器（mkv / flv / avi / rmvb / 老式 ts 等）交给 VLC 兜底。
/// 只负责播放，下载、嗅探、油猴都还走原来的逻辑。
final class VLCPlayback: NSObject, VLCMediaPlayerDelegate {

    static let isAvailable = true

    private(set) var player: VLCMediaPlayer?

    /// 播放进度（秒）：(当前, 总长)
    var onTime: ((Double, Double) -> Void)?
    /// 播放状态：是否在播、是否在缓冲
    var onState: ((Bool, Bool) -> Void)?
    var onEnded: (() -> Void)?
    var onFailed: ((String) -> Void)?

    private var pendingSeek: Double?

    func load(_ url: URL, rate: Double, startAt: Double?) {
        stop()

        let engine = VLCMediaPlayer()
        engine.delegate = self

        let media = VLCMedia(url: url)
        // 尽量别丢帧，画面更顺
        media.addOption("--no-drop-late-frames")
        media.addOption("--no-skip-frames")

        engine.media = media
        engine.rate = Float(rate)
        player = engine

        pendingSeek = startAt
        engine.play()
    }

    func play() {
        guard let player = player, !player.isPlaying else { return }
        player.play()
    }

    func pause() {
        player?.pause()
    }

    func togglePlay() {
        guard let player = player else { return }
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    func seek(to seconds: Double) {
        guard let player = player else { return }
        let clamped = max(0, seconds)
        player.time = VLCTime(int: Int32(clamped * 1000))
    }

    func setRate(_ value: Double) {
        player?.rate = Float(value)
    }

    func stop() {
        player?.delegate = nil
        player?.stop()
        player?.drawable = nil
        player = nil
        pendingSeek = nil
    }

    /// 画面宿主交给 VLC
    func attach(to view: UIView) {
        guard let player = player else { return }
        if (player.drawable as? UIView) !== view {
            player.drawable = view
        }
    }

    // MARK: - VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = player else { return }

        switch player.state {
        case .opening, .buffering:
            onState?(player.isPlaying, true)
        case .playing:
            onState?(true, false)
            if let target = pendingSeek, target > 1 {
                pendingSeek = nil
                seek(to: target)
            }
        case .paused:
            onState?(false, false)
        case .ended:
            onState?(false, false)
            onEnded?()
        case .error:
            onState?(false, false)
            onFailed?("VLC 也打不开这个文件，可能文件损坏或格式特殊。")
        default:
            onState?(false, false)
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard let player = player else { return }
        let current = Double(player.time.intValue) / 1000.0
        let total = Double(player.media.length.intValue) / 1000.0
        onTime?(max(0, current), max(0, total))
    }
}

/// VLC 的画面输出层
struct VLCVideoView: UIViewRepresentable {
    let engine: VLCPlayback

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        engine.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        engine.attach(to: uiView)
    }
}

#else

/// 没把 VLCKit 打进包里时的空实现：不影响编译，兜底功能自动关闭
final class VLCPlayback {

    static let isAvailable = false

    var onTime: ((Double, Double) -> Void)?
    var onState: ((Bool, Bool) -> Void)?
    var onEnded: (() -> Void)?
    var onFailed: ((String) -> Void)?

    func load(_ url: URL, rate: Double, startAt: Double?) {}
    func play() {}
    func pause() {}
    func togglePlay() {}
    func seek(to seconds: Double) {}
    func setRate(_ value: Double) {}
    func stop() {}
}

struct VLCVideoView: View {
    let engine: VLCPlayback
    var body: some View { Color.black }
}

#endif
