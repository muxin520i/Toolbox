import Foundation
import Compression
import ZIPFoundation

// MARK: - 压缩包工具
//
// 支持 zip / tar / tar.gz / tgz 的浏览与解压：
//   zip      走 ZIPFoundation（SPM）
//   tar      手写 512 字节块解析
//   tar.gz   先用系统 Compression framework 把 gz 流解成临时 tar，再走上面的解析
//   rar / 7z 没有可用的公开库（rar5 尤其如此），检测到后给出说明，不解压
//
// 解压时逐条做路径清洗：拒绝绝对路径和「..」，防止恶意包写出自己的目录。

// MARK: - 条目

struct ArchiveEntryItem: Identifiable {
    let id = UUID()
    let path: String
    let isDirectory: Bool
    let size: Int64
}

// MARK: - 存储

final class ArchiveStore {
    static let shared = ArchiveStore()

    enum Format: Equatable {
        case zip
        case tar
        case unsupported(String)
    }

    /// 按扩展名认格式，不碰文件内容
    static func format(of url: URL) -> Format {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tar }
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".tar") { return .tar }
        if name.hasSuffix(".rar") { return .unsupported("rar") }
        if name.hasSuffix(".7z") { return .unsupported("7z") }
        return .unsupported("未知格式")
    }

    /// App 自己下载目录里现有的压缩包，按名字排
    static func archivesInApp() -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        var dirs: [URL] = [fm.urls(for: .documentDirectory, in: .userDomainMask)[0]]
        dirs.append(DownloadManager.directory())
        var seen = Set<String>()
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for f in files {
                switch Self.format(of: f) {
                case .unsupported: continue
                default: break
                }
                if seen.insert(f.path).inserted { result.append(f) }
            }
        }
        return result.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// 解压后的目标目录：Documents/Downloads/解压/<包名>
    static func extractDirectory(for archive: URL) -> URL {
        let base = DownloadManager.directory().appendingPathComponent("解压", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let name = archive.deletingPathExtension().lastPathComponent
        var dir = base.appendingPathComponent(name, isDirectory: true)
        var index = 1
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = base.appendingPathComponent("\(name)-\(index)", isDirectory: true)
            index += 1
        }
        return dir
    }

    // MARK: 浏览

    func list(url: URL) throws -> [ArchiveEntryItem] {
        switch Self.format(of: url) {
        case .zip:
            let archive = try Archive(url: url, accessMode: .read)
            return archive.map { entry in
                ArchiveEntryItem(path: entry.path,
                                 isDirectory: entry.type == .directory,
                                 size: Int64(entry.uncompressedSize))
            }
            .sorted { Self.sortKey($0.path, $0.isDirectory) < Self.sortKey($1.path, $1.isDirectory) }
        case .tar:
            return try listTar(url: url)
        case .unsupported(let what):
            throw NSError(domain: "Archive", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "暂不支持 \(what) 格式，请先在电脑上解压"])
        }
    }

    // MARK: 解压

    /// 解压到指定目录（目录不存在会创建）。逐条回报进度 0...1。
    func extract(url: URL, to dir: URL, progress: @escaping (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        switch Self.format(of: url) {
        case .zip:
            try await extractZip(url: url, to: dir, progress: progress)
        case .tar:
            try await extractTar(url: url, to: dir, progress: progress)
        case .unsupported(let what):
            throw NSError(domain: "Archive", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "暂不支持 \(what) 格式，请先在电脑上解压"])
        }
    }

    // MARK: zip

    private func extractZip(url: URL, to dir: URL, progress: @escaping (Double) -> Void) async throws {
        let archive = try Archive(url: url, accessMode: .read)
        let entries = archive.filter { $0.type == .file || $0.type == .directory }
        let total = max(1, entries.count)
        for (index, entry) in entries.enumerated() {
            // 路径清洗：zip 条目也可能带 ../ 或绝对路径
            guard let clean = Self.sanitized(entry.path) else {
                throw NSError(domain: "Archive", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "压缩包里有一条不安全的路径，已停止解压"])
            }
            if clean != entry.path {
                // ZIPFoundation 按 entry.path 解压，路径被清洗过就换不了，直接拒绝
                throw NSError(domain: "Archive", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "压缩包里有一条不安全的路径（\(entry.path)），已停止解压"])
            }
            try archive.extract(entry, to: dir)
            progress(Double(index + 1) / Double(total))
        }
    }

    // MARK: tar 浏览

    private func listTar(url: URL) throws -> [ArchiveEntryItem] {
        let tarURL: URL
        let tmp: URL?
        if url.lastPathComponent.lowercased().hasSuffix(".gz") || url.lastPathComponent.lowercased().hasSuffix(".tgz") {
            let t = FileManager.default.temporaryDirectory
                .appendingPathComponent("tar-\(UUID().uuidString).tar")
            try Self.gunzipFile(url, to: t)
            tmp = t
            tarURL = t
        } else {
            tmp = nil
            tarURL = url
        }
        defer { if let tmp { try? FileManager.default.removeItem(at: tmp) } }

        let handle = try FileHandle(forReadingFrom: tarURL)
        defer { try? handle.close() }

        var items: [ArchiveEntryItem] = []
        var offset: UInt64 = 0
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: tarURL.path)[.size] as? UInt64) ?? 0
        while offset + 512 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let block = try handle.read(upToCount: 512), block.count == 512 else { break }
            let bytes = [UInt8](block)
            if bytes.allSatisfy({ $0 == 0 }) { break }

            var name = Self.cString(bytes[0..<100])
            var size = Self.tarOctal(Array(bytes[124..<136]))
            let type = bytes[156]

            // GNU long name：下一块是完整文件名
            if type == UInt8(ascii: "L") {
                let len = Int(size)
                let blocks = (len + 511) / 512
                try handle.seek(toOffset: offset + 512)
                guard let nameBlock = try handle.read(upToCount: len) else { break }
                name = Self.cString([UInt8](nameBlock))
                offset += 512 + UInt64(blocks * 512)
                // 长名块后面紧跟真实条目块
                try handle.seek(toOffset: offset)
                guard let next = try handle.read(upToCount: 512), next.count == 512 else { break }
                let nb = [UInt8](next)
                size = Self.tarOctal(Array(nb[124..<136]))
                items.append(contentsOf: Self.entryFrom(nb, name: name, size: size))
                offset += 512 + Self.padded(size)
                continue
            }

            items.append(contentsOf: Self.entryFrom(bytes, name: name, size: size))
            offset += 512 + Self.padded(size)
        }
        return items.sorted { Self.sortKey($0.path, $0.isDirectory) < Self.sortKey($1.path, $1.isDirectory) }
    }

    private static func entryFrom(_ bytes: [UInt8], name: String, size: Int64) -> [ArchiveEntryItem] {
        let type = bytes.count > 156 ? bytes[156] : 0
        if name.isEmpty { return [] }
        switch type {
        case UInt8(ascii: "5"): // 目录
            return [ArchiveEntryItem(path: name.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                                     isDirectory: true, size: 0)]
        case 0, UInt8(ascii: "0"), UInt8(ascii: "7"): // 普通文件
            return [ArchiveEntryItem(path: name, isDirectory: false, size: size)]
        case UInt8(ascii: "x"), UInt8(ascii: "g"): // pax 扩展头，本体在数据块里，跳过
            return []
        default:
            return []
        }
    }

    // MARK: tar 解压

    private func extractTar(url: URL, to dir: URL, progress: @escaping (Double) -> Void) async throws {
        let tarURL: URL
        let tmp: URL?
        if url.lastPathComponent.lowercased().hasSuffix(".gz") || url.lastPathComponent.lowercased().hasSuffix(".tgz") {
            let t = FileManager.default.temporaryDirectory
                .appendingPathComponent("tar-\(UUID().uuidString).tar")
            try Self.gunzipFile(url, to: t)
            tmp = t
            tarURL = t
        } else {
            tmp = nil
            tarURL = url
        }
        defer { if let tmp { try? FileManager.default.removeItem(at: tmp) } }

        let fm = FileManager.default
        let handle = try FileHandle(forReadingFrom: tarURL)
        defer { try? handle.close() }

        let fileSize = (try? fm.attributesOfItem(atPath: tarURL.path)[.size] as? UInt64) ?? 0
        var offset: UInt64 = 0
        while offset + 512 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let block = try handle.read(upToCount: 512), block.count == 512 else { break }
            let bytes = [UInt8](block)
            if bytes.allSatisfy({ $0 == 0 }) { break }

            var name = Self.cString(bytes[0..<100])
            var size = Self.tarOctal(Array(bytes[124..<136]))
            let type = bytes[156]

            if type == UInt8(ascii: "L") {
                let len = Int(size)
                let blocks = (len + 511) / 512
                try handle.seek(toOffset: offset + 512)
                guard let nameBlock = try handle.read(upToCount: len) else { break }
                name = Self.cString([UInt8](nameBlock))
                offset += 512 + UInt64(blocks * 512)
                try handle.seek(toOffset: offset)
                guard let next = try handle.read(upToCount: 512), next.count == 512 else { break }
                let nb = [UInt8](next)
                size = Self.tarOctal(Array(nb[124..<136]))
                try Self.writeEntry(handle, bytes: nb, name: name, size: size, offset: offset + 512, to: dir)
                offset += 512 + Self.padded(size)
                continue
            }

            try Self.writeEntry(handle, bytes: bytes, name: name, size: size, offset: offset + 512, to: dir)
            offset += 512 + Self.padded(size)
            progress(min(1, Double(offset) / Double(max(1, fileSize))))
        }
        progress(1)
    }

    /// 写一个 tar 条目到目标目录（文件流式拷贝，目录只建）
    private static func writeEntry(_ handle: FileHandle, bytes: [UInt8], name: String, size: Int64,
                                   offset: UInt64, to dir: URL) throws {
        let fm = FileManager.default
        let type = bytes.count > 156 ? bytes[156] : 0
        guard let clean = sanitized(name), !clean.isEmpty else { return }

        switch type {
        case UInt8(ascii: "5"):
            let d = dir.appendingPathComponent(clean, isDirectory: true)
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        case 0, UInt8(ascii: "0"), UInt8(ascii: "7"):
            let target = dir.appendingPathComponent(clean)
            let parent = target.deletingLastPathComponent()
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            guard size > 0 else {
                fm.createFile(atPath: target.path, contents: nil)
                return
            }
            try handle.seek(toOffset: offset)
            guard fm.createFile(atPath: target.path, contents: nil) else { return }
            guard let out = FileHandle(forWritingAtPath: target.path) else { return }
            defer { try? out.close() }
            var remaining = size
            while remaining > 0 {
                let want = Int(min(remaining, 1 << 20))
                guard let data = try handle.read(upToCount: want) else { break }
                if data.isEmpty { break }
                try out.write(contentsOf: data)
                remaining -= Int64(data.count)
            }
        default:
            break
        }
    }

    // MARK: gz 解流

    /// 用系统 Compression framework 把 .gz 解成裸流写到 dst
    static func gunzipFile(_ src: URL, to dst: URL) throws {
        guard let input = InputStream(url: src) else {
            throw NSError(domain: "Archive", code: 3, userInfo: [NSLocalizedDescriptionKey: "打不开压缩包"])
        }
        guard let output = OutputStream(url: dst, append: false) else {
            throw NSError(domain: "Archive", code: 3, userInfo: [NSLocalizedDescriptionKey: "写不了临时文件"])
        }
        input.open()
        output.open()
        defer { input.close(); output.close() }

        var scratch = UInt8(0)
        var stream = compression_stream(dst_ptr: &scratch, dst_size: 0, src_ptr: &scratch, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw NSError(domain: "Archive", code: 3, userInfo: [NSLocalizedDescriptionKey: "解压引擎初始化失败"])
        }
        defer { compression_stream_destroy(&stream) }

        let chunk = 1 << 16
        var inBuf = [UInt8](repeating: 0, count: chunk)
        var outBuf = [UInt8](repeating: 0, count: chunk)

        stream.src_size = 0
        stream.dst_ptr = outBuf.withUnsafeMutableBufferPointer { $0.baseAddress }!
        stream.dst_size = chunk

        while true {
            if stream.src_size == 0 {
                let n = input.read(&inBuf, maxLength: chunk)
                guard n > 0 else { break }
                inBuf.withUnsafeMutableBufferPointer { buf in
                    stream.src_ptr = UnsafePointer(buf.baseAddress!)
                }
                stream.src_size = n
            }
            let status = compression_stream_process(&stream, 0)
            guard status != COMPRESSION_STATUS_ERROR else {
                throw NSError(domain: "Archive", code: 3, userInfo: [NSLocalizedDescriptionKey: "gzip 数据损坏"])
            }
            if stream.dst_size == 0 {
                outBuf.withUnsafeMutableBufferPointer { buf in
                    output.write(buf.baseAddress!, maxLength: chunk)
                }
                outBuf.withUnsafeMutableBufferPointer { buf in
                    stream.dst_ptr = buf.baseAddress!
                }
                stream.dst_size = chunk
            }
            if status == COMPRESSION_STATUS_END {
                let produced = chunk - stream.dst_size
                if produced > 0 {
                    outBuf.withUnsafeMutableBufferPointer { buf in
                        output.write(buf.baseAddress!, maxLength: produced)
                    }
                }
                break
            }
        }
    }

    // MARK: 工具

    private static func cString(_ bytes: ArraySlice<UInt8>) -> String {
        var data = Data(bytes)
        if let zero = data.firstIndex(of: 0) { data = data[..<zero] }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func cString(_ bytes: [UInt8]) -> String {
        cString(bytes[bytes.indices])
    }

    private static func tarOctal(_ bytes: [UInt8]) -> Int64 {
        var value: Int64 = 0
        for b in bytes {
            if b == 0 || b == 0x20 { continue }
            guard b >= 0x30, b <= 0x37 else { return 0 }
            value = value * 8 + Int64(b - 0x30)
        }
        return value
    }

    private static func padded(_ size: Int64) -> UInt64 {
        let r = size % 512
        return r == 0 ? 0 : UInt64(512 - r)
    }

    /// 清洗包内路径：拒绝绝对路径与「..」
    static func sanitized(_ raw: String) -> String? {
        var parts = raw.split(separator: "/", omittingEmptySubsequences: true)
        if raw.hasPrefix("/") || raw.contains("\\") { return nil }
        var out: [String] = []
        for p in parts {
            let s = String(p)
            if s == "." { continue }
            if s == ".." { return nil }
            out.append(s)
        }
        return out.joined(separator: "/")
    }

    private static func sortKey(_ path: String, _ isDir: Bool) -> String {
        (isDir ? "0-" : "1-") + path.lowercased()
    }
}
