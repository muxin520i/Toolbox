import Foundation

/// 沙盒里存下来的文件路径，跨安装会失效。
///
/// iOS 每次覆盖安装都会给 App 换一个数据容器：
///   /var/mobile/Containers/Data/Application/<UUID>/Documents/Downloads/xxx.mp4
/// 里面那份文件会被原样搬过去，但外面这层 `<UUID>` 变了。数据库里存的是绝对路径，
/// 装完新版本后旧路径指向一个不存在的目录，列表里的本机视频于是全部显示成
/// 「文件已删除」——其实文件好好躺在 Documents 里。
///
/// 这里统一把路径重新挂到当前容器上：先认「/Documents/ 之后」那一段，
/// 认不出来再按容器前缀替换。读列表、读下载记录时都过一遍。
enum MediaPath {
    /// 本次安装的文档目录（「文件」App → 我的 iPhone → 工具箱）
    static let documentsPath: String = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0].path

    /// 本次安装的容器根目录
    private static let containerPath: String = (documentsPath as NSString).deletingLastPathComponent

    private static let containerMarker = "/Containers/Data/Application/"
    private static let documentsMarker = "/Documents/"

    /// 把旧安装（或相对写法）的路径换成当前容器下的路径。
    /// 只做字符串替换，不检查文件在不在——没下完的临时文件也要能落回原位。
    static func rebase(_ stored: String?) -> String? {
        guard var raw = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        // 不依赖 URL(string:) 解析：路径里有空格、中文时它可能直接返回 nil
        if raw.lowercased().hasPrefix("file://") {
            let path = String(raw.dropFirst("file://".count))
            raw = path.removingPercentEncoding ?? path
        }

        // 相对写法：直接挂在文档目录下
        if !raw.hasPrefix("/") {
            return documentsPath + "/" + raw
        }

        // 老容器路径：/var/mobile/Containers/Data/Application/<UUID>/Documents/...
        if let range = raw.range(of: containerMarker) {
            let rest = raw[range.upperBound...]
            if let slash = rest.firstIndex(of: "/") {
                return containerPath + String(rest[slash...])
            }
        }

        // 兜底：只认 Documents 之后那一段
        if let range = raw.range(of: documentsMarker) {
            let tail = raw[range.upperBound...]
            if !tail.isEmpty { return documentsPath + "/" + tail }
        }

        return raw
    }

    /// 换成当前容器下的路径，并且确认文件真的在。找不到返回 nil
    static func resolve(_ stored: String?) -> String? {
        guard let candidate = rebase(stored) else { return nil }
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }
}
