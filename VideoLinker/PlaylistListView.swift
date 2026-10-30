import SwiftUI
import UIKit

// MARK: - 列表总览

struct PlaylistListView: View {
    @State private var playlists: [Playlist] = PlaylistStore.load()
    @State private var showCreateSheet = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                ScrollView {
                    VStack(spacing: 10) {
                        if playlists.isEmpty {
                            emptyState
                        } else {
                            ForEach(playlists) { playlist in
                                NavigationLink {
                                    PlaylistDetailView(playlistID: playlist.id)
                                } label: {
                                    row(playlist)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            playlists = PlaylistStore.delete(playlist.id)
                                        }
                                    } label: {
                                        Label("删除列表", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("播放列表")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color(red: 0.045, green: 0.045, blue: 0.06), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        newName = ""
                        showCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { playlists = PlaylistStore.load() }
        .sheet(isPresented: $showCreateSheet) {
            createSheet
                .presentationDetents([.height(230)])
                .presentationDragIndicator(.visible)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.18))
            Text("还没有播放列表")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text("点右上角 + 新建一个，把常看的视频放进去")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.3))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    private func row(_ playlist: Playlist) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 1.0, green: 0.42, blue: 0.31).opacity(0.85),
                                 Color(red: 0.55, green: 0.28, blue: 0.85).opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 46, height: 46)
                .overlay(
                    Image(systemName: "list.bullet")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                Text(playlist.items.isEmpty ? "空列表" : "\(playlist.items.count) 个视频")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.38))
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.22))
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建播放列表")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 22)

            TextField("", text: $newName, prompt: Text("给列表起个名字").foregroundColor(.white.opacity(0.3)))
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            Button {
                playlists = PlaylistStore.create(named: newName)
                showCreateSheet = false
            } label: {
                Text("创建")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 1.0, green: 0.42, blue: 0.31),
                                     Color(red: 0.55, green: 0.28, blue: 0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
    }
}

// MARK: - 列表详情

struct PlaylistDetailView: View {
    let playlistID: UUID

    @State private var playlist: Playlist?
    @State private var request: PlayRequest?
    @State private var showAddSheet = false
    @State private var addURL = ""
    @State private var addTitle = ""

    var body: some View {
        ZStack {
            BackgroundView()

            ScrollView {
                VStack(spacing: 8) {
                    if let playlist = playlist {
                        if playlist.items.isEmpty {
                            emptyState
                        } else {
                            ForEach(Array(playlist.items.enumerated()), id: \.element.id) { index, item in
                                row(item, index: index)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle(playlist?.name ?? "列表")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(red: 0.045, green: 0.045, blue: 0.06), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    addURL = ""
                    addTitle = ""
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
        .onAppear { reload() }
        .sheet(isPresented: $showAddSheet) {
            addSheet
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $request) { req in
            PlayerScreen(request: req)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.white.opacity(0.18))
            Text("列表是空的")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text("点右上角 + 把视频链接加进来")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    private func row(_ item: PlaylistItem, index: Int) -> some View {
        Button {
            guard let playlist = playlist else { return }
            let playbackItems = playlist.items.map {
                PlaybackItem(url: $0.url, title: $0.displayTitle)
            }
            request = PlayRequest(items: playbackItems, startIndex: index)
        } label: {
            HStack(spacing: 13) {
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.28))
                    .frame(width: 26, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.32))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.07), in: Circle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                UIPasteboard.general.string = item.url
            } label: {
                Label("复制链接", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                PlaylistStore.removeItem(item.id, from: playlistID)
                reload()
            } label: {
                Label("从列表移除", systemImage: "minus.circle")
            }
        }
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加视频")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 22)

            TextField("", text: $addURL, prompt: Text("视频链接").foregroundColor(.white.opacity(0.3)))
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            TextField("", text: $addTitle, prompt: Text("标题（可留空）").foregroundColor(.white.opacity(0.3)))
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            HStack(spacing: 10) {
                Button {
                    if let s = UIPasteboard.general.string {
                        addURL = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Text("粘贴")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    saveNewItem()
                } label: {
                    Text("添加")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 1.0, green: 0.42, blue: 0.31),
                                         Color(red: 0.55, green: 0.28, blue: 0.85)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                        .opacity(normalizedURL == nil ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .disabled(normalizedURL == nil)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
    }

    private var normalizedURL: String? {
        var s = addURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        guard let u = URL(string: s), let host = u.host, host.contains(".") else { return nil }
        return u.absoluteString
    }

    private func saveNewItem() {
        guard let url = normalizedURL else { return }
        let item = PlaylistItem(url: url, title: addTitle)
        playlist = PlaylistStore.add(item, to: playlistID)
        showAddSheet = false
    }

    private func reload() {
        playlist = PlaylistStore.load().first { $0.id == playlistID }
    }
}
