import Foundation

public enum ModelImportError: Error, LocalizedError, Equatable {
    case unsupportedFormat(String)
    case corrupted(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): return "Dateiformat „\(ext)“ wird nicht unterstützt."
        case .corrupted(let reason): return "Datei ist beschädigt: \(reason)"
        case .empty: return "Die Datei enthält keine druckbaren Objekte."
        }
    }
}

public enum STLReader {
    public static func read(_ data: Data) throws -> TriangleMesh {
        let mesh: TriangleMesh
        if isBinary(data) {
            mesh = try readBinary(data)
        } else {
            mesh = try readASCII(data)
        }
        guard !mesh.isEmpty else { throw ModelImportError.empty }
        return mesh
    }

    /// Many binary STLs start with "solid" too, so trust the size field first.
    static func isBinary(_ data: Data) -> Bool {
        guard data.count >= 84 else { return false }
        let count = data.readUInt32LE(at: 80)
        if 84 + Int(count) * 50 == data.count { return true }
        let head = String(decoding: data.prefix(5), as: UTF8.self).lowercased()
        return head != "solid"
    }

    static func readBinary(_ data: Data) throws -> TriangleMesh {
        guard data.count >= 84 else { throw ModelImportError.corrupted("STL-Header zu kurz") }
        let count = Int(data.readUInt32LE(at: 80))
        guard data.count >= 84 + count * 50 else { throw ModelImportError.corrupted("STL zu kurz für \(count) Dreiecke") }
        var tris: [(Vec3, Vec3, Vec3)] = []
        tris.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let base = 84 + i * 50 + 12
                func v(_ o: Int) -> Vec3 {
                    Vec3(
                        Double(raw.loadFloatLE(at: base + o)),
                        Double(raw.loadFloatLE(at: base + o + 4)),
                        Double(raw.loadFloatLE(at: base + o + 8))
                    )
                }
                tris.append((v(0), v(12), v(24)))
            }
        }
        return TriangleMesh(soup: tris)
    }

    static func readASCII(_ data: Data) throws -> TriangleMesh {
        let text = String(decoding: data, as: UTF8.self)
        var tris: [(Vec3, Vec3, Vec3)] = []
        var current: [Vec3] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.first == "vertex", parts.count >= 4,
                  let x = Double(parts[1]), let y = Double(parts[2]), let z = Double(parts[3]) else { continue }
            current.append(Vec3(x, y, z))
            if current.count == 3 {
                tris.append((current[0], current[1], current[2]))
                current.removeAll(keepingCapacity: true)
            }
        }
        if tris.isEmpty { throw ModelImportError.corrupted("keine Dreiecke gefunden") }
        return TriangleMesh(soup: tris)
    }

    /// Writes a binary STL, e.g. to share an arranged plate.
    public static func binaryData(for mesh: TriangleMesh, header: String = "MakerSlice") -> Data {
        var data = Data(count: 80)
        let headerBytes = Array(header.utf8.prefix(80))
        data.replaceSubrange(0..<headerBytes.count, with: headerBytes)
        data.appendLE(UInt32(mesh.triangleCount))
        for t in 0..<mesh.triangleCount {
            let n = mesh.faceNormal(t)
            for value in [n.x, n.y, n.z] { data.appendLE(Float(value).bitPattern) }
            for k in 0..<3 {
                let v = mesh.vertices[Int(mesh.indices[t * 3 + k])]
                for value in [v.x, v.y, v.z] { data.appendLE(Float(value).bitPattern) }
            }
            data.append(contentsOf: [0, 0])
        }
        return data
    }
}

extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }

    func readUInt16LE(at offset: Int) -> UInt16 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian }
    }

    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

extension UnsafeRawBufferPointer {
    func loadFloatLE(at offset: Int) -> Float {
        Float(bitPattern: loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian)
    }
}
