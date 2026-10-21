import CZip
import Foundation

/// Minimal ZIP reader/writer – enough for 3MF packages (stored + deflate).
public struct ZipArchive {
    public struct Entry {
        public let path: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    public let entries: [Entry]
    private let data: Data

    public init(data: Data) throws {
        // Re-base slices so integer offsets start at zero.
        let data = Data(data)
        self.data = data
        entries = try ZipArchive.readCentralDirectory(data)
    }

    public func entry(_ path: String) -> Entry? {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return entries.first { $0.path == normalized }
            ?? entries.first { $0.path.lowercased() == normalized.lowercased() }
    }

    public func contents(of path: String) throws -> Data? {
        guard let entry = entry(path) else { return nil }
        return try extract(entry)
    }

    public func extract(_ entry: Entry) throws -> Data {
        let o = entry.localHeaderOffset
        guard o + 30 <= data.count, data.readUInt32LE(at: o) == 0x04034b50 else {
            throw ModelImportError.corrupted("ungültiger ZIP-Eintrag \(entry.path)")
        }
        let nameLen = Int(data.readUInt16LE(at: o + 26))
        let extraLen = Int(data.readUInt16LE(at: o + 28))
        let start = o + 30 + nameLen + extraLen
        guard start + entry.compressedSize <= data.count else {
            throw ModelImportError.corrupted("ZIP-Eintrag \(entry.path) abgeschnitten")
        }
        let compressed = data.subdata(in: start..<(start + entry.compressedSize))
        switch entry.method {
        case 0:
            return compressed
        case 8:
            var out = Data(count: entry.uncompressedSize)
            let written = compressed.withUnsafeBytes { src in
                out.withUnsafeMutableBytes { dst in
                    czip_inflate_raw(
                        src.bindMemory(to: UInt8.self).baseAddress, compressed.count,
                        dst.bindMemory(to: UInt8.self).baseAddress, entry.uncompressedSize
                    )
                }
            }
            guard written == entry.uncompressedSize else {
                throw ModelImportError.corrupted("Entpacken von \(entry.path) fehlgeschlagen")
            }
            return out
        default:
            throw ModelImportError.corrupted("ZIP-Kompression \(entry.method) nicht unterstützt")
        }
    }

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw ModelImportError.corrupted("keine ZIP-Datei") }
        // Find the end-of-central-directory record (may be followed by a comment).
        var eocd = -1
        var i = data.count - 22
        let lowest = max(0, data.count - 22 - 0xFFFF)
        while i >= lowest {
            if data.readUInt32LE(at: i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ModelImportError.corrupted("ZIP-Verzeichnis fehlt") }
        var count = Int(data.readUInt16LE(at: eocd + 10))
        var offset = Int(data.readUInt32LE(at: eocd + 16))

        // ZIP64: sizes/offsets stored in the ZIP64 end-of-central-directory record.
        if offset == 0xFFFFFFFF || count == 0xFFFF, eocd >= 20, data.readUInt32LE(at: eocd - 20) == 0x07064b50 {
            let z64 = Int(data.readUInt64LE(at: eocd - 12))
            if z64 + 56 <= data.count, data.readUInt32LE(at: z64) == 0x06064b50 {
                count = Int(data.readUInt64LE(at: z64 + 32))
                offset = Int(data.readUInt64LE(at: z64 + 48))
            }
        }

        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count, data.readUInt32LE(at: offset) == 0x02014b50 else {
                throw ModelImportError.corrupted("ZIP-Verzeichnis beschädigt")
            }
            let method = data.readUInt16LE(at: offset + 10)
            var compressed = Int(data.readUInt32LE(at: offset + 20))
            var uncompressed = Int(data.readUInt32LE(at: offset + 24))
            let nameLen = Int(data.readUInt16LE(at: offset + 28))
            let extraLen = Int(data.readUInt16LE(at: offset + 30))
            let commentLen = Int(data.readUInt16LE(at: offset + 32))
            var local = Int(data.readUInt32LE(at: offset + 42))
            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLen))
            let name = String(decoding: nameData, as: UTF8.self)

            // ZIP64 extra field (id 0x0001) carries the 64-bit values in fixed order.
            var e = offset + 46 + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let id = data.readUInt16LE(at: e)
                let size = Int(data.readUInt16LE(at: e + 2))
                if id == 0x0001 {
                    var p = e + 4
                    if uncompressed == 0xFFFFFFFF { uncompressed = Int(data.readUInt64LE(at: p)); p += 8 }
                    if compressed == 0xFFFFFFFF { compressed = Int(data.readUInt64LE(at: p)); p += 8 }
                    if local == 0xFFFFFFFF { local = Int(data.readUInt64LE(at: p)) }
                }
                e += 4 + size
            }

            entries.append(Entry(path: name, method: method, compressedSize: compressed,
                                 uncompressedSize: uncompressed, localHeaderOffset: local))
            offset += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    /// Builds a ZIP archive (deflate) from path → contents pairs.
    public static func write(_ files: [(path: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        for file in files {
            let crc = file.data.withUnsafeBytes { czip_crc32($0.bindMemory(to: UInt8.self).baseAddress, file.data.count) }
            var compressed = Data(count: czip_deflate_bound(file.data.count))
            let size = file.data.withUnsafeBytes { src in
                compressed.withUnsafeMutableBytes { dst in
                    czip_deflate_raw(src.bindMemory(to: UInt8.self).baseAddress, file.data.count,
                                     dst.bindMemory(to: UInt8.self).baseAddress, dst.count)
                }
            }
            compressed.count = max(0, size)
            let name = Data(file.path.utf8)
            let localOffset = UInt32(out.count)

            out.appendLE(UInt32(0x04034b50))
            out.appendLE(UInt16(20)); out.appendLE(UInt16(0x0800)); out.appendLE(UInt16(8))
            out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
            out.appendLE(crc); out.appendLE(UInt32(compressed.count)); out.appendLE(UInt32(file.data.count))
            out.appendLE(UInt16(name.count)); out.appendLE(UInt16(0))
            out.append(name); out.append(compressed)

            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(20)); central.appendLE(UInt16(20)); central.appendLE(UInt16(0x0800)); central.appendLE(UInt16(8))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(crc); central.appendLE(UInt32(compressed.count)); central.appendLE(UInt32(file.data.count))
            central.appendLE(UInt16(name.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt32(0))
            central.appendLE(localOffset)
            central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.appendLE(UInt32(0x06054b50))
        out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
        out.appendLE(UInt16(files.count)); out.appendLE(UInt16(files.count))
        out.appendLE(UInt32(central.count)); out.appendLE(centralOffset)
        out.appendLE(UInt16(0))
        return out
    }
}

extension Data {
    func readUInt64LE(at offset: Int) -> UInt64 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian }
    }
}
