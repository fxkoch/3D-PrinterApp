import Foundation

/// Very small, fast XML tag scanner. 3MF model files can hold millions of
/// `<vertex>`/`<triangle>` tags, which is too slow with a callback-based
/// parser; we only ever need tag names and attributes.
struct XMLTagScanner {
    struct Tag {
        var name: Substring
        var attributes: [Substring: String]
        var isClosing: Bool
        var isSelfClosing: Bool

        /// Name without a namespace prefix ("p:component" → "component").
        var localName: Substring {
            if let colon = name.lastIndex(of: ":") { return name[name.index(after: colon)...] }
            return name
        }

        func attribute(_ local: String) -> String? {
            if let v = attributes[Substring(local)] { return v }
            for (k, v) in attributes {
                if let colon = k.lastIndex(of: ":"), k[k.index(after: colon)...] == local { return v }
            }
            return nil
        }
    }

    private let bytes: [UInt8]

    init(data: Data) {
        bytes = [UInt8](data)
    }

    func forEachTag(_ body: (Tag) throws -> Void) rethrows {
        let n = bytes.count
        var i = 0
        while i < n {
            guard bytes[i] == UInt8(ascii: "<") else { i += 1; continue }
            // Skip comments, declarations, CDATA, processing instructions.
            if i + 1 < n, bytes[i + 1] == UInt8(ascii: "?") || bytes[i + 1] == UInt8(ascii: "!") {
                if i + 3 < n, bytes[i + 2] == UInt8(ascii: "-"), bytes[i + 3] == UInt8(ascii: "-") {
                    i = find("-->", from: i + 4).map { $0 + 3 } ?? n
                } else if i + 8 < n, bytes[i + 2] == UInt8(ascii: "[") {
                    i = find("]]>", from: i + 3).map { $0 + 3 } ?? n
                } else {
                    i = find(">", from: i).map { $0 + 1 } ?? n
                }
                continue
            }
            var j = i + 1
            var closing = false
            if j < n, bytes[j] == UInt8(ascii: "/") { closing = true; j += 1 }
            let nameStart = j
            while j < n, !isSpace(bytes[j]), bytes[j] != UInt8(ascii: ">"), bytes[j] != UInt8(ascii: "/") { j += 1 }
            let name = Substring(decoding: bytes[nameStart..<j], as: UTF8.self)
            var attributes: [Substring: String] = [:]
            var selfClosing = false
            while j < n {
                while j < n, isSpace(bytes[j]) { j += 1 }
                guard j < n else { break }
                if bytes[j] == UInt8(ascii: ">") { j += 1; break }
                if bytes[j] == UInt8(ascii: "/") { selfClosing = true; j += 1; continue }
                let keyStart = j
                while j < n, bytes[j] != UInt8(ascii: "="), !isSpace(bytes[j]), bytes[j] != UInt8(ascii: ">") { j += 1 }
                let key = Substring(decoding: bytes[keyStart..<j], as: UTF8.self)
                while j < n, isSpace(bytes[j]) { j += 1 }
                guard j < n, bytes[j] == UInt8(ascii: "=") else { continue }
                j += 1
                while j < n, isSpace(bytes[j]) { j += 1 }
                guard j < n else { break }
                let quote = bytes[j]
                guard quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else { continue }
                j += 1
                let valueStart = j
                while j < n, bytes[j] != quote { j += 1 }
                let raw = String(decoding: bytes[valueStart..<j], as: UTF8.self)
                attributes[key] = raw.contains("&") ? XMLTagScanner.decodeEntities(raw) : raw
                j += 1
            }
            try body(Tag(name: name, attributes: attributes, isClosing: closing, isSelfClosing: selfClosing))
            i = j
        }
    }

    private func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09
    }

    private func find(_ needle: String, from start: Int) -> Int? {
        let pattern = Array(needle.utf8)
        var i = start
        while i + pattern.count <= bytes.count {
            if bytes[i] == pattern[0], Array(bytes[i..<(i + pattern.count)]) == pattern { return i }
            i += 1
        }
        return nil
    }

    static func decodeEntities(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].firstIndex(of: ";") {
                let entity = s[s.index(after: i)..<semi]
                switch entity {
                case "amp": out.append("&")
                case "lt": out.append("<")
                case "gt": out.append(">")
                case "quot": out.append("\"")
                case "apos": out.append("'")
                default:
                    if entity.hasPrefix("#x"), let v = UInt32(entity.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) {
                        out.unicodeScalars.append(u)
                    } else if entity.hasPrefix("#"), let v = UInt32(entity.dropFirst()), let u = Unicode.Scalar(v) {
                        out.unicodeScalars.append(u)
                    } else {
                        out.append(contentsOf: s[i...semi])
                    }
                }
                i = s.index(after: semi)
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }
}
