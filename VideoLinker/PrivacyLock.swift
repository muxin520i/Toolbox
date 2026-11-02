import SwiftUI
import LocalAuthentication

// MARK: - App 锁
//
// 只做一件事：把整个 App 的内容盖住，验证通过才放出来。
// 用 .deviceOwnerAuthentication（Face ID / Touch ID，失败可退回设备密码），
// 设备上什么都没设时直接放行，避免用户把自己锁在外面。

enum AppLock {
    static let enabledKey = "privacy.lock.enabled"
    /// 0 立即、60 一分钟、300 五分钟
    static let timingKey = "privacy.lock.timing"

    static let lockNowNotification = Notification.Name("VideoLinker.lockNow")

    static func authenticate(reason: String = "解锁工具箱") async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        context.localizedFallbackTitle = "使用密码"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // 没设密码也没录生物识别，锁不上，只能放行
            return true
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    static let biometryName: String = {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID: return "面容 ID"
        case .touchID: return "触控 ID"
        default: return "设备密码"
        }
    }()
}

// MARK: - 遮罩层

struct PrivacyGate<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @AppStorage(AppLock.enabledKey) private var enabled = false
    @AppStorage(AppLock.timingKey) private var timing = 0
    @Environment(\.scenePhase) private var phase

    @State private var locked = false
    @State private var masked = false
    @State private var backgroundAt: Date?
    @State private var wentBackground = false
    @State private var authenticating = false
    @State private var failed = false

    var body: some View {
        ZStack {
            content()
                .blur(radius: locked ? 26 : 0)
                .allowsHitTesting(!locked)
                .accessibilityHidden(locked)

            if masked {
                // 切到后台时先盖一层纯色，多任务截图里看不到任何内容
                Color.black.ignoresSafeArea()
            }

            if locked && !masked {
                lockScreen
                    .transition(.opacity)
            }
        }
        .onAppear {
            if enabled {
                locked = true
                Task { await unlock() }
            }
        }
        .onChange(of: enabled) { on in
            locked = on ? true : false
            if on { Task { await unlock() } }
        }
        .onChange(of: phase) { newPhase in
            handle(newPhase)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppLock.lockNowNotification)) { _ in
            guard enabled else { return }
            locked = true
        }
    }

    private var lockScreen: some View {
        ZStack {
            (Color.black.opacity(0.92)).ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.bottom, 2)

                Text("工具箱 已锁定")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)

                Text(failed ? "没有通过验证，再试一次" : "用\(AppLock.biometryName)解锁")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))

                if authenticating {
                    ProgressView()
                        .tint(.white)
                        .padding(.top, 4)
                } else {
                    Button {
                        Task { await unlock() }
                    } label: {
                        Text("解锁")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 34)
                            .padding(.vertical, 11)
                            .background(Color.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        }
    }

    private func unlock() async {
        guard !authenticating else { return }
        await MainActor.run {
            authenticating = true
            failed = false
        }

        let ok = await AppLock.authenticate()

        await MainActor.run {
            authenticating = false
            if ok {
                withAnimation(.easeOut(duration: 0.22)) { locked = false }
            } else {
                failed = true
            }
        }
    }

    private func handle(_ newPhase: ScenePhase) {
        switch newPhase {
        case .active:
            masked = false
            guard enabled else {
                locked = false
                backgroundAt = nil
                wentBackground = false
                return
            }

            let elapsed = backgroundAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            let cameBack = wentBackground
            backgroundAt = nil
            wentBackground = false

            // 只是下拉通知栏 / 切到控制中心，不算离开，别动不动就要验证
            guard cameBack else { return }
            // 已经解锁、且离开时间没超过宽限期，也不打扰
            if !locked, timing > 0, elapsed < Double(timing) { return }
            locked = true
            Task { await unlock() }

        case .inactive:
            // 多任务截图发生在切后台前一瞬，这里先把画面盖住
            if enabled { masked = true }
            if backgroundAt == nil { backgroundAt = Date() }

        case .background:
            if enabled { masked = true }
            wentBackground = true
            if backgroundAt == nil { backgroundAt = Date() }

        @unknown default:
            break
        }
    }
}
