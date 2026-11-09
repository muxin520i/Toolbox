import Foundation

/// 写 zip 文件：只用 store（不压缩）+ 可选的传统 ZipCrypto 密码。
///
/// 为什么不压缩：这个工具打包的多数是视频、字幕、封面，视频本身已经压不动，
/// store 模式几乎是纯拷贝，速度最快，兼容性也最好（Windows / macOS / 各类解压 App 都认）。
///
/// 加密只是「别让人随手点开」的程度，不是强加密；真要保密请用别的工具。
final class ZipWriter {
    enum WriteError: LocalizedError {
        case tooLarge(String)
        case unreadable(String)
        case tooManyFiles

        var errorDescription: String? {
            switch self {
            case .tooLarge(let name):
                return "「\(name)」超过 4 GB，这个打包器暂不支持这么大的文件"
            case .unreadable(let name):
                return "读不了「\(name)」，可能已被移动或删除"
            case .tooManyFiles:
                return "一次最多打包 60000 个文件"
            }
        }
    }

    private struct Entry {
        let name: String
        let crc: UInt32
        let size: UInt32
        let compressedSize: UInt32
        let offset: UInt32
        let encrypted: Bool
    }

    private let output: URL
    private let password: String?
    private var handle: FileHandle?
    private var offset: UInt32 = 0
    private var entries: [Entry] = []
    private(set) var finished = false

    private var dosTime: UInt16 = 0
    private var dosDate: UInt16 = 0

    init(output: URL, password: String? = nil) {
        self.output = output
        self.password = (password?.isEmpty ?? true) ? nil : password
        prepare()
    }

    private func prepare() {
        let fm = FileManager.default
        try? fm.removeItem(at: output)
        fm.createFile(atPath: output.path, contents: nil)
        handle = try? FileHandle(forWritingTo: output)

        let comps = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())

        let hour = UInt16(comps.hour ?? 0)
        let minute = UInt16(comps.minute ?? 0)
        let second = UInt16(comps.second ?? 0)
        dosTime = (hour << 11) | (minute << 5) | (second / 2)

        let year = UInt16(max(1980, comps.year ?? 1980) - 1980)
        let month = UInt16(comps.month ?? 1)
        let day = UInt16(comps.day ?? 1)
        dosDate = (year << 9) | (month << 5) | day
    }

    // MARK: 写入

    func addFile(at url: URL, entryName: String? = nil) throws {
        guard entries.count < 60_000 else { throw WriteError.tooManyFiles }

        let name = entryName ?? url.lastPathComponent
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attrs[.size] as? NSNumber else {
            throw WriteError.unreadable(name)
        }
        let byteSize = number.int64Value
        guard byteSize >= 0 else { throw WriteError.unreadable(name) }
        guard byteSize <= 0xFFFF_FFFF else { throw WriteError.tooLarge(name) }

        let crc = try checksum(url, name: name)
        let size = UInt32(byteSize)
        let encrypted = password != nil
        // 传统加密的「压缩后大小」要把 12 字节加密头算进去，否则系统解压会读少一截
        let compressedSize = size + (encrypted ? 12 : 0)
        let flags: UInt16 = 0x0800 | (encrypted ? 0x0001 : 0)
        let headerOffset = offset

        // 本地文件头
        try write(UInt32(0x04034b50))
        try write(UInt16(20))
        try write(flags)
        try write(UInt16(0))          // store
        try write(dosTime)
        try write(dosDate)
        try write(crc)
        try write(compressedSize)
        try write(size)
        let nameData = Data(name.utf8)
        try write(UInt16(nameData.count))
        try write(UInt16(0))
        try write(nameData)

        // 加密头：11 字节随机 + 1 字节 CRC 校验
        var crypto: ZipCrypto?
        if let password = password {
            var engine = ZipCrypto(password: password)
            var head = (0..<11).map { _ in UInt8.random(in: 0...255) }
            head.append(UInt8((crc >> 24) & 0xFF))
            var encrypted = Data(capacity: 12)
            for byte in head { encrypted.append(engine.encrypt(byte)) }
            try write(encrypted)
            crypto = engine
        }

        try stream(url, name: name) { chunk in
            if var engine = crypto {
                var data = Data(capacity: chunk.count)
                for byte in chunk { data.append(engine.encrypt(byte)) }
                crypto = engine
                try self.write(data)
            } else {
                try self.write(chunk)
            }
        }

        entries.append(Entry(name: name, crc: crc, size: size,
                             compressedSize: compressedSize,
                             offset: headerOffset, encrypted: encrypted))
    }

    func finish() throws {
        guard !finished else { return }
        let cdStart = offset

        for entry in entries {
            try write(UInt32(0x02014b50))
            try write(UInt16(20))                  // version made by
            try write(UInt16(20))                  // version needed
            try write(UInt16(0x0800 | (entry.encrypted ? 0x0001 : 0)))
            try write(UInt16(0))                   // store
            try write(dosTime)
            try write(dosDate)
            try write(entry.crc)
            try write(entry.compressedSize)
            try write(entry.size)
            let nameData = Data(entry.name.utf8)
            try write(UInt16(nameData.count))
            try write(UInt16(0))                   // extra
            try write(UInt16(0))                   // comment
            try write(UInt16(0))                   // disk
            try write(UInt16(0))                   // internal attrs
            try write(UInt32(0))                   // external attrs
            try write(entry.offset)
            try write(nameData)
        }

        let cdSize = offset - cdStart
        try write(UInt32(0x06054b50))
        try write(UInt16(0))
        try write(UInt16(0))
        try write(UInt16(entries.count))
        try write(UInt16(entries.count))
        try write(cdSize)
        try write(cdStart)
        try write(UInt16(0))

        try handle?.close()
        handle = nil
        finished = true
    }

    func abort() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: output)
    }

    // MARK: 底层

    private func stream(_ url: URL, name: String, handler: (Data) throws -> Void) throws {
        guard let input = try? FileHandle(forReadingFrom: url) else {
            throw WriteError.unreadable(name)
        }
        defer { try? input.close() }

        while true {
            let data: Data?
            do { data = try input.read(upToCount: 1 << 20) } catch { break }
            guard let chunk = data, !chunk.isEmpty else { break }
            try handler(chunk)
        }
    }

    private func checksum(_ url: URL, name: String) throws -> UInt32 {
        guard let input = try? FileHandle(forReadingFrom: url) else {
            throw WriteError.unreadable(name)
        }
        defer { try? input.close() }

        var crc: UInt32 = 0xFFFF_FFFF
        while true {
            let data: Data?
            do { data = try input.read(upToCount: 1 << 20) } catch { break }
            guard let chunk = data, !chunk.isEmpty else { break }
            for byte in chunk { crc = ZipCrypto.crc32(crc, byte) }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private func write(_ value: UInt16) throws {
        try write(Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]))
    }

    private func write(_ value: UInt32) throws {
        try write(Data([UInt8(value & 0xFF),
                        UInt8((value >> 8) & 0xFF),
                        UInt8((value >> 16) & 0xFF),
                        UInt8((value >> 24) & 0xFF)]))
    }

    private func write(_ data: Data) throws {
        guard let handle else {
            throw WriteError.unreadable("输出文件")
        }
        guard UInt64(offset) + UInt64(data.count) <= 0xFFFF_FFFF else {
            throw WriteError.tooLarge("压缩包")
        }
        try handle.write(contentsOf: data)
        offset &+= UInt32(data.count)
    }
}

// MARK: - ZipCrypto

/// 传统 PKZIP 加密，密码错了会在解压时 CRC 报错。
/// 算法就这几行，兼容所有常见解压工具。
struct ZipCrypto {
    private var key0: UInt32 = 0x1234_5678
    private var key1: UInt32 = 0x2345_6789
    private var key2: UInt32 = 0x3456_7890

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func crc32(_ crc: UInt32, _ byte: UInt8) -> UInt32 {
        table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }

    init(password: String) {
        for byte in password.utf8 { update(byte) }
    }

    mutating func encrypt(_ byte: UInt8) -> UInt8 {
        let temp = UInt16(truncatingIfNeeded: key2 | 2)
        let mask = UInt8(((UInt32(temp) &* UInt32(temp ^ 1)) >> 8) & 0xFF)
        update(byte)
        return byte ^ mask
    }

    private mutating func update(_ byte: UInt8) {
        key0 = Self.crc32(key0, byte)
        // 标准 ZipCrypto 是加上「key0 的低字节」，不是原始明文字节；
        // 写错的话自己解自己没问题，但 Windows / macOS 会报密码错误
        key1 = (key1 &+ UInt32(key0 & 0xFF)) &* 134_775_813 &+ 1
        key2 = Self.crc32(key2, UInt8((key1 >> 24) & 0xFF))
    }
}
