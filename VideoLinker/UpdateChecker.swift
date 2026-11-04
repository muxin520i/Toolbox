import Foundation
import SwiftUI
import UIKit

// MARK: - 版本检查
//
// 包是本地签的，没法走 App Store 更新，所以直接读仓库里的工程文件：
// MARKETING_VERSION / CURRENT_PROJECT_VERSION 每次发包都会跟着改，读它最准。
// 走 raw.githubusercontent.com，不要 token，也不吃 API 限流。

final class UpdateChecker: ObservableObject {

    static let shared = UpdateChecker()

    struct Release {
        let version: String
        let build: Int
        let notes: [String]
    }

    @Published private(set) var latest: Release?
    @Published private(set) var checking = false
    @Published private(set) var errorText = ""
    @Published private(set) var checkedAt: Date?

    private let projectURL = URL(string: "https://raw.githubusercontent.com/muxin520i/Toolbox/main/VideoLinker.xcodeproj/project.pbxproj")!
    private let readmeURL = URL(string: "https://raw.githubusercontent.com/muxin520i/Toolbox/main/README.md")!
    static let repoURL = URL(string: "https://github.com/muxin520i/Toolbox/actions/workflows/build-unsigned-ipa.yml")!

    private let lastCheckKey = "update.lastCheck.v1"
    private let cachedBuildKey = "update.latestBuild.v1"
    private let cachedVersionKey = "update.latestVersion.v1"

    private init() {}

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1") ?? 1
    }

    var currentText: String { "\(currentVersion) (\(currentBuild))" }

    var hasUpdate: Bool {
        guard let latest = latest else { return false }
        return latest.build > currentBuild
    }

    var latestText: String {
        guard let latest = latest else { return "" }
        return "\(latest.version) (\(latest.build))"
    }

    /// 一天最多自动查一次，别每次进设置都发请求
    func checkIfNeeded() {
        if let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 6 * 3600 {
            // 命中缓存也把上次的结果显示出来
            let build = UserDefaults.standard.integer(forKey: cachedBuildKey)
            let version = UserDefaults.standard.string(forKey: cachedVersionKey) ?? ""
            if build > 0, latest == nil {
                latest = Release(version: version, build: build, notes: [])
            }
            return
        }
        Task { await check() }
    }

    func check() async {
        guard !checking else { return }
        await MainActor.run {
            self.checking = true
            self.errorText = ""
        }

        do {
            let text = try await fetch(projectURL)
            guard let version = Self.value(of: "MARKETING_VERSION", in: text),
                  let buildText = Self.value(of: "CURRENT_PROJECT_VERSION", in: text),
                  let build = Int(buildText) else {
                throw UpdateError.parse
            }

            var notes: [String] = []
            if build > currentBuild {
                notes = (try? await fetchNotes(version: version)) ?? []
            }

            let release = Release(version: version, build: build, notes: notes)
            await MainActor.run {
                self.latest = release
                self.checkedAt = Date()
                self.checking = false
                UserDefaults.standard.set(Date(), forKey: self.lastCheckKey)
                UserDefaults.standard.set(build, forKey: self.cachedBuildKey)
                UserDefaults.standard.set(version, forKey: self.cachedVersionKey)
            }
        } catch {
            await MainActor.run {
                self.errorText = (error as? LocalizedError)?.errorDescription ?? "检查失败，稍后再试"
                self.checking = false
            }
        }
    }

    private func fetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Toolbox-iOS", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else {
            throw UpdateError.network
        }
        return text
    }

    /// README 里第一段 `### vX.Y.Z` 就是这个版本改了什么
    private func fetchNotes(version: String) async throws -> [String] {
        let text = try await fetch(readmeURL)
        let lines = text.components(separatedBy: .newlines)

        var collecting = false
        var notes: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("### ") {
                if collecting { break }
                if trimmed.contains(version) { collecting = true }
                continue
            }
            if trimmed.hasPrefix("## ") {
                if collecting { break }
                continue
            }
            guard collecting, !trimmed.isEmpty else { continue }

            var body = trimmed
            if body.hasPrefix("- ") { body = String(body.dropFirst(2)) }
            notes.append(body.replacingOccurrences(of: "**", with: ""))
            if notes.count >= 8 { break }
        }

        return notes
    }

    private static func value(of key: String, in text: String) -> String? {
        guard let range = text.range(of: "\(key) = ") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: ";") else { return nil }
        return String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum UpdateError: LocalizedError {
        case network
        case parse

        var errorDescription: String? {
            switch self {
            case .network: return "连不上仓库，检查一下网络再试"
            case .parse: return "没读到版本号，仓库结构可能变了"
            }
        }
    }
}

// MARK: - 界面

struct UpdateSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var checker = UpdateChecker.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    versionCard
                    if checker.checking {
                        checkingCard
                    } else if checker.hasUpdate {
                        notesCard
                    } else if !checker.errorText.isEmpty {
                        errorCard
                    } else {
                        upToDateCard
                    }
                    actionCard
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("版本更新")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onAppear {
            Task { await checker.check() }
        }
    }

    private var versionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("当前版本")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(checker.currentText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }

            if !checker.latestText.isEmpty {
                HStack {
                    Text("仓库最新")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(checker.latestText)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(checker.hasUpdate ? theme.accent : .secondary)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var checkingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("正在读取仓库里的版本号…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("这一版改了什么")
                .font(.system(size: 14, weight: .semibold))

            if checker.latest?.notes.isEmpty ?? true {
                Text("仓库里没有写更新说明，点下面的按钮去看构建记录。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array((checker.latest?.notes ?? []).enumerated()), id: \.offset) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(theme.accent)
                            .frame(width: 4, height: 4)
                            .padding(.top, 7)
                        Text(entry.element)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var upToDateCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 26))
                .foregroundStyle(.green.opacity(0.8))
            Text("已经是最新的")
                .font(.system(size: 14, weight: .semibold))
            Text("仓库里的版本号和你手上的一样")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var errorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(checker.errorText)
                .font(.system(size: 12))
                .foregroundStyle(.red.opacity(0.85))
            Text("也可以直接去仓库的构建记录里看有没有新包。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var actionCard: some View {
        VStack(spacing: 10) {
            Button {
                Task { await checker.check() }
            } label: {
                Text(checker.checking ? "检查中…" : "重新检查")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(checker.checking)

            Button {
                UIApplication.shared.open(UpdateChecker.repoURL)
            } label: {
                HStack(spacing: 6) {
                    Text(checker.hasUpdate ? "去下载新包" : "打开构建记录")
                        .font(.system(size: 14, weight: .semibold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(theme.accent)
                )
            }
            .buttonStyle(.plain)

            Text("包是未签名的，下载后还得用 Sideloadly / AltStore 自己签一下，直接覆盖安装会保留数据。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
