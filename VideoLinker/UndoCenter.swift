import Foundation
import Combine

/// 从播放列表里删掉的条目先在这里挂六秒，底部给一条「撤销」。
/// 真删已经发生了，撤销就是把这几条按原位置插回去，不涉及回收站和文件。
final class UndoCenter: ObservableObject {
    static let shared = UndoCenter()

    struct Pending: Identifiable {
        let id = UUID()
        /// 被删的条目和它原来在列表里的位置
        let entries: [(item: PlaylistItem, index: Int)]
        let playlistID: UUID
        let playlistName: String

        var count: Int { entries.count }

        var title: String {
            if entries.count == 1 {
                return entries[0].item.displayTitle
            }
            return "\(entries.count) 个视频"
        }
    }

    @Published private(set) var pending: Pending?

    private var work: DispatchWorkItem?

    private init() {}

    /// 后一次删除会顶掉前一次的撤销机会，避免攒一堆
    func stage(_ entries: [(item: PlaylistItem, index: Int)],
               playlistID: UUID,
               playlistName: String) {
        guard !entries.isEmpty else { return }
        work?.cancel()

        let sorted = entries.sorted { $0.index < $1.index }
        let record = Pending(entries: sorted, playlistID: playlistID, playlistName: playlistName)
        onMain { self.pending = record }

        let task = DispatchWorkItem { [weak self] in
            guard let self = self, self.pending?.id == record.id else { return }
            onMain { self.pending = nil }
        }
        work = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: task)
    }

    func stage(_ item: PlaylistItem, index: Int, playlistID: UUID, playlistName: String) {
        stage([(item: item, index: index)], playlistID: playlistID, playlistName: playlistName)
    }

    func undo() {
        guard let record = pending else { return }
        work?.cancel()
        pending = nil
        // 位置小的先插回去，后面的位置才不会被挤错
        for entry in record.entries.sorted(by: { $0.index < $1.index }) {
            PlaylistStore.insert(entry.item, at: entry.index, into: record.playlistID)
        }
    }

    func dismiss() {
        work?.cancel()
        pending = nil
    }

    /// 调用点都在主线程，这里只是防一手，别让 @Published 从后台改
    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
