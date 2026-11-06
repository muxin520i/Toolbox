import SwiftUI
import UniformTypeIdentifiers

// MARK: - 换机搬家

struct TransferView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var exportURL: URL?
    @State private var busy = false
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
                    ProgressView()
                        .tint(.white)
                        .padding(22)
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
            .navigationTitle("换机搬家")
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
                        showImportSheet = true
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
        }
    }

    private var pickerTypes: [UTType] {
        var types: [UTType] = [.data]
        if let custom = UTType(filenameExtension: TransferStore.fileExtension) {
            types.insert(custom, at: 0)
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
                    Text("把整台设备的数据搬过去")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text("播放列表、观看进度、备忘、书签、脚本和设置都会打包。视频文件本身不在包里，换机后用「本机视频」重新导入即可。")
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

                Text("设一个密码，换机时在新设备上输入同一个密码才能打开。密码忘了包就解不开，没有找回入口。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                secureField("密码（至少 6 位）", text: $password)
                secureField("再输一次", text: $confirmPassword)

                Button {
                    exportPackage()
                } label: {
                    Text("生成搬家包")
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
                            Text("分享搬家包")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(theme.field, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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
                    Text("选一个搬家包，输入导出时设的密码。导入不会立刻覆盖，重启后才会生效，出错还能退回。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        importError = nil
                        showPicker = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                            Text("选择搬家包")
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

                bullet("导入会在下次启动时替换当前数据，替换前会自动留一份 restore-backup.sqlite")
                bullet("换机后新设备上的旧数据会被覆盖，先导出自己的一份再做")
                bullet("搬家包只含数据，不含视频文件，也不含 WebDAV 密码（它存在系统钥匙串里）")
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
                        Text("输入搬家包密码")
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
                    .disabled(importPassword.count < TransferStore.minPasswordLength || busy)

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

    private func exportPackage() {
        errorText = nil
        guard password.count >= TransferStore.minPasswordLength else {
            errorText = "密码至少 6 位"
            return
        }
        guard password == confirmPassword else {
            errorText = "两次输入的密码不一样"
            return
        }

        busy = true
        let pwd = password
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try TransferStore.writePackage(password: pwd)
                DispatchQueue.main.async {
                    busy = false
                    exportURL = url
                    showToast("搬家包已生成")
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func runImport() {
        guard let file = pendingFile else { return }
        busy = true
        let pwd = importPassword

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try TransferStore.stageImport(from: file, password: pwd)
                DispatchQueue.main.async {
                    busy = false
                    showImportSheet = false
                    pendingFile = nil
                    staged = true
                    showToast("导入完成，重启后生效")
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    showToast(importError ?? "导入失败")
                }
            }
        }
    }

    // MARK: 组件

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
