import SwiftUI
import UniformTypeIdentifiers

// MARK: - 换机备份

struct TransferView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var usePassword = false
    @State private var password = ""
    @State private var confirmPassword = ""

    @State private var includeWebData = true
    @State private var siteCount = 0
    @State private var loadingSites = true

    @State private var exportURL: URL?
    @State private var exportSummary: String?
    @State private var busy = false
    @State private var busyText = "正在打包…"
    @State private var toast: String?
    @State private var errorText: String?

    @State private var showPicker = false
    @State private var pendingFile: URL?
    @State private var importPassword = ""
    @State private var showImportSheet = false
    @State private var staged = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                ScrollView {
                    VStack(spacing: 16) {
                        introCard
                        exportCard
                        importCard
                        noteCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 40)
                }

                if busy {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        Text(busyText)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if let toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.78), in: Capsule())
                            .padding(.bottom, 30)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("换机备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showPicker) {
                DocumentPickerSheet(
                    contentTypes: pickerTypes,
                    allowsMultiple: false,
                    onPick: { urls in
                        showPicker = false
                        guard let url = urls.first else { return }
                        pendingFile = url
                        importPassword = ""
                        importError = nil

                        // 不加密的包直接导入，不再拦一道密码框
                        if TransferStore.isEncrypted(at: url) {
                            showImportSheet = true
                        } else {
                            runImport(file: url)
                        }
                    },
                    onCancel: { _ in
                        showPicker = false
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showImportSheet) {
                importSheet
            }
            .onAppear {
                CrashLog.mark("备份页 onAppear")
                loadSiteCount()
                DispatchQueue.main.async {
                    CrashLog.mark("备份页首帧完成")
                }
            }
        }
    }

    private var pickerTypes: [UTType] {
        var types: [UTType] = [.data]
        if let custom = UTType(filenameExtension: TransferStore.fileExtension) {
            types.insert(custom, at: 0)
        }
        if let legacy = UTType(filenameExtension: TransferStore.legacyFileExtension) {
            types.insert(legacy, at: 1)
        }
        return types
    }

    // MARK: 卡片

    private var introCard: some View {
        card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 6) {
                    Text("把整台设备的数据备份下来")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text("播放列表、观看进度、备忘、书签、脚本、设置，以及内置浏览器的网站数据（登录状态、本地存储）都会打包。视频文件本身不在包里，换机后用「本机视频」重新导入即可。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var exportCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("导出", symbol: "square.and.arrow.up")

                settingSwitch(
                    title: "包含网站数据",
                    subtitle: webDataSummary,
                    isOn: $includeWebData
                )

                Divider().overlay(theme.cardStroke)

                settingSwitch(
                    title: "用密码保护",
                    subtitle: usePassword ? "换机时输入同一个密码才能打开" : "不设密码，拿到文件就能直接导入",
                    isOn: $usePassword
                )

                if usePassword {
                    secureField("密码（至少 6 位）", text: $password)
                    secureField("再输一次", text: $confirmPassword)
                    Text("密码忘了包就解不开，没有找回入口。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if includeWebData {
                    warningRow("不设密码时，包里的登录 Cookie 是明文，谁拿到文件都能看到。请只通过可信方式传输。")
                }

                Button {
                    exportPackage()
                } label: {
                    Text("生成备份包")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(theme.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(busy)

                if let exportURL {
                    ShareLink(item: exportURL) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.badge.arrow.up")
                            Text("分享备份包")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(theme.field, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(exportURL.lastPathComponent)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)

                        if let exportSummary {
                            Text(exportSummary)
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.textTertiary)
                        }

                        Text("位置：「文件」App → 我的 iPhone → 工具箱 → 工具箱备份")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let errorText {
                    Text(errorText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(red: 0.95, green: 0.36, blue: 0.36))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var importCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("导入", symbol: "square.and.arrow.down")

                if staged {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color(red: 0.20, green: 0.78, blue: 0.45))
                        Text("数据已就绪，完全退出 App 再打开就会换上")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        TransferStore.discardPending()
                        staged = false
                        showToast("已取消这次导入")
                    } label: {
                        Text("取消导入")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("选一个备份包。设了密码的会要求输入，没设密码的直接导入。导入不会立刻覆盖，重启后才会生效，出错还能退回。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        importError = nil
                        showPicker = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                            Text("选择备份包")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(theme.field, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                if let importError {
                    Text(importError)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(red: 0.95, green: 0.36, blue: 0.36))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var noteCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("注意", symbol: "exclamationmark.triangle")

                bullet("导入会在下次启动时替换当前数据，替换前会自动留一份 restore-backup.sqlite 和 WebKit.restore-backup")
                bullet("换机后新设备上的旧数据会被覆盖，先导出自己的一份再做")
                bullet("备份包只含数据，不含视频文件，也不含 WebDAV 密码（它存在系统钥匙串里）")
                bullet("网站数据里有各站的登录 Cookie，备份包请像密码一样保管")
            }
        }
    }

    private var importSheet: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        Image(systemName: "lock.doc")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(theme.accent)
                        Text("输入备份包密码")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.text)
                        Text(pendingFile?.lastPathComponent ?? "")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }
                    .padding(.top, 8)

                    secureField("密码", text: $importPassword)

                    Button {
                        runImport()
                    } label: {
                        Text("开始导入")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(theme.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(importPassword.isEmpty || busy)

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showImportSheet = false
                        pendingFile = nil
                    }
                }
            }
        }
        .presentationDetents([.height(320)])
    }

    // MARK: 动作

    private func loadSiteCount() {
        guard loadingSites else { return }
        DispatchQueue.global(qos: .utility).async {
            let count = WebDataBackup.siteCountOnDisk()
            DispatchQueue.main.async {
                siteCount = count
                loadingSites = false
            }
        }
    }

    private var webDataSummary: String {
        if loadingSites {
            return "正在读取站点…"
        }
        if siteCount == 0 {
            return "浏览器还没产生网站数据"
        }
        return "\(siteCount) 个站点的登录状态、本地存储与 IndexedDB"
    }

    private func exportPackage() {
        errorText = nil

        if usePassword {
            guard password.count >= TransferStore.minPasswordLength else {
                errorText = "密码至少 6 位"
                return
            }
            guard password == confirmPassword else {
                errorText = "两次输入的密码不一样"
                return
            }
        }

        busy = true
        busyText = includeWebData ? "正在打包数据与网站数据…" : "正在打包数据…"
        let pwd = usePassword ? password : ""
        let withWeb = includeWebData

        Task.detached(priority: .userInitiated) {
            do {
                let result = try await TransferStore.writePackage(password: pwd, includeWebData: withWeb)
                await MainActor.run {
                    busy = false
                    exportURL = result.url
                    exportSummary = result.summaryText
                    CrashLog.mark("备份包已写入 \(result.url.lastPathComponent)")
                    showToast("已生成，位置写在按钮下方")
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    busy = false
                    errorText = message
                    CrashLog.mark("生成备份包失败：\(message)")
                    showToast("生成失败：\(message)")
                }
            }
        }
    }

    private func runImport(file: URL? = nil) {
        guard let file = file ?? pendingFile else { return }
        busy = true
        busyText = "正在导入…"
        let pwd = importPassword

        Task.detached(priority: .userInitiated) {
            do {
                try TransferStore.stageImport(from: file, password: pwd)
                await MainActor.run {
                    busy = false
                    showImportSheet = false
                    pendingFile = nil
                    staged = true
                    showToast("导入完成，重启后生效")
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    busy = false
                    importError = message
                    showToast(message)
                }
            }
        }
    }

    // MARK: 组件

    /// 自己画开关，不用系统 Toggle：这一页之前一打开就闪退，
    /// 换成纯 SwiftUI 基础图形后彻底避开系统控件的布局路径
    private func settingSwitch(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                isOn.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(theme.text)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                switchBadge(isOn.wrappedValue)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func switchBadge(_ on: Bool) -> some View {
        HStack(spacing: 0) {
            if on { Spacer(minLength: 0) }
            Circle()
                .fill(Color.white)
                .frame(width: 20, height: 20)
                .shadow(color: Color.black.opacity(0.14), radius: 1, y: 1)
            if !on { Spacer(minLength: 0) }
        }
        .padding(3)
        .frame(width: 46, height: 26)
        .background(
            Capsule().fill(on ? theme.accent : theme.field)
        )
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.cardStroke, lineWidth: 1)
            )
    }

    private func sectionTitle(_ text: String, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.text)
        }
    }

    private func secureField(_ placeholder: String, text: Binding<String>) -> some View {
        SecureField(placeholder, text: text)
            .font(.system(size: 14))
            .foregroundStyle(theme.text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(theme.field, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func warningRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5))
                .padding(.top, 1.5)
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color(red: 0.90, green: 0.58, blue: 0.16))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(theme.textTertiary)
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { toast = nil }
        }
    }
}
