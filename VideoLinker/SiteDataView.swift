import SwiftUI
import WebKit

// MARK: - 站点数据管理
//
// 浏览器把 Cookie、缓存、本地存储都交给 WebKit 统一管。平时出问题（登录态错乱、
// 某个站一直跳验证）只需要清那一个站，不用整锅端掉。

struct SiteDataView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var sites: [SiteRecord] = []
    @State private var loading = true
    @State private var confirmAll = false
    @State private var toast: String?
    @State private var pendingDelete: SiteRecord?

    struct SiteRecord: Identifiable, Equatable {
        let id: String
        let name: String
        let types: [String]

        var typeText: String {
            types.map(SiteDataView.label(for:)).joined(separator: " · ")
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                if loading {
                    ProgressView().tint(theme.accent)
                } else if sites.isEmpty {
                    emptyView
                } else {
                    listView
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
                            .padding(.bottom, 28)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("网站数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            Task { await load() }
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) {
                            confirmAll = true
                        } label: {
                            Label("清除全部网站数据", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("清除全部网站数据？", isPresented: $confirmAll, titleVisibility: .visible) {
                Button("全部清除", role: .destructive) {
                    Task { await removeAll() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("所有网站的登录状态、缓存、本地存储都会清掉。下次打开要重新登录。")
            }
            .confirmationDialog(
                pendingDelete.map { "清除「\($0.name)」的数据？" } ?? "",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let site = pendingDelete {
                    Button("清除", role: .destructive) {
                        Task { await remove(site) }
                    }
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("这个站的 Cookie、缓存和本地存储都会清掉，其它站不受影响。")
            }
            .task { await load() }
        }
    }

    private var listView: some View {
        List {
            Section {
                ForEach(sites) { site in
                    Button {
                        pendingDelete = site
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(theme.field)
                                    .frame(width: 38, height: 38)
                                Text(initial(of: site.name))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(theme.accent)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(site.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(theme.text)
                                    .lineLimit(1)
                                Text(site.typeText)
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.textTertiary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(theme.textTertiary)
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("共 \(sites.count) 个站点，点一条单独清除")
            } footer: {
                Text("清完之后回到浏览器刷新一下，需要重新登录的会跳登录页。")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "globe.badge.chevron.backward")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(theme.textTertiary)
            Text("还没有网站数据")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Text("内置浏览器打开过网页之后，这里会出现对应站点")
                .font(.system(size: 12))
                .foregroundStyle(theme.textTertiary)
        }
    }

    // MARK: 数据

    private func load() async {
        loading = true
        let records = await withCheckedContinuation { (continuation: CheckedContinuation<[WKWebsiteDataRecord], Never>) in
            WKWebsiteDataStore.default().fetchDataRecords(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()
            ) { records in
                continuation.resume(returning: records)
            }
        }

        let mapped = records
            .map { record in
                SiteRecord(
                    id: record.displayName,
                    name: record.displayName,
                    types: record.dataTypes.sorted()
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        await MainActor.run {
            sites = mapped
            loading = false
        }
    }

    private func remove(_ site: SiteRecord) async {
        let records = await withCheckedContinuation { (continuation: CheckedContinuation<[WKWebsiteDataRecord], Never>) in
            WKWebsiteDataStore.default().fetchDataRecords(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()
            ) { records in
                continuation.resume(returning: records)
            }
        }

        let targets = records.filter { $0.displayName == site.id }
        guard !targets.isEmpty else {
            pendingDelete = nil
            await load()
            return
        }

        let types = targets.reduce(into: Set<String>()) { result, record in
            result.formUnion(record.dataTypes)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.default().removeData(ofTypes: types, for: targets) {
                continuation.resume()
            }
        }

        pendingDelete = nil
        showToast("已清除「\(site.name)」")
        await load()
    }

    private func removeAll() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
        showToast("网站数据已全部清除")
        await load()
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation { toast = nil }
        }
    }

    private func initial(of name: String) -> String {
        let cleaned = name.hasPrefix("www.") ? String(name.dropFirst(4)) : name
        return String(cleaned.prefix(1)).uppercased()
    }

    // MARK: 类型名

    static func label(for type: String) -> String {
        switch type {
        case WKWebsiteDataTypeCookies: return "Cookie"
        case WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache: return "缓存"
        case WKWebsiteDataTypeLocalStorage: return "本地存储"
        case WKWebsiteDataTypeSessionStorage: return "会话存储"
        case WKWebsiteDataTypeIndexedDBDatabases: return "IndexedDB"
        case WKWebsiteDataTypeWebSQLDatabases: return "WebSQL"
        case WKWebsiteDataTypeOfflineWebApplicationCache: return "离线缓存"
        case WKWebsiteDataTypeFetchCache: return "Fetch 缓存"
        case WKWebsiteDataTypeServiceWorkerRegistrations: return "Service Worker"
        case WKWebsiteDataTypeFileSystem: return "文件系统"
        case WKWebsiteDataTypeMediaKeys: return "媒体密钥"
        case WKWebsiteDataTypeHashSalt: return "哈希盐"
        default: return "其它"
        }
    }
}
