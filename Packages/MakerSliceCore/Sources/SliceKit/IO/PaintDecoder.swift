import Foundation

/// One small triangle of a painted surface and the colour it was painted with.
public struct PaintedFacet: Sendable, Equatable {
    public var a: Vec3
    public var b: Vec3
    public var c: Vec3
    /// Zero-based slot the colour is printed with (starts as the file's extruder, changes with the colour mapping).
    public var tool: Int
    /// Zero-based extruder/colour index in the file (state − 1).
    public var sourceTool: Int

    public init(a: Vec3, b: Vec3, c: Vec3, tool: Int, sourceTool: Int? = nil) {
        self.a = a
        self.b = b
        self.c = c
        self.tool = tool
        self.sourceTool = sourceTool ?? tool
    }

    func transformed(_ t: Transform3D) -> PaintedFacet {
        PaintedFacet(a: t.apply(a), b: t.apply(b), c: t.apply(c), tool: tool, sourceTool: sourceTool)
    }
}

/// Decodes the `paint_color` attribute of Bambu Studio / OrcaSlicer 3MF files (multi-colour painting).
///
/// The text is a hexadecimal bit stream, written backwards: every digit is a "node" of a triangle subdivision tree.
/// Low two bits = number of split sides (0 = leaf); a leaf carries its state in the upper two bits (states 0–2 directly,
/// 12 means "the next digit plus 3"). State 0 is "not painted", state n ≥ 1 is extruder n.
/// This follows OrcaSlicer's `TriangleSelector::deserialize`.
enum PaintDecoder {
    /// Painted pieces (state ≥ 1) of one mesh triangle; nil when the text is malformed.
    static func decode(_ text: String, a: Vec3, b: Vec3, c: Vec3) -> [PaintedFacet]? {
        let digits = text.reversed().compactMap { $0.hexDigitValue }
        guard digits.count == text.count else { return nil }
        var position = 0
        var result: [PaintedFacet] = []
        var failed = false

        func next() -> Int? {
            guard position < digits.count else { failed = true; return nil }
            defer { position += 1 }
            return digits[position]
        }

        func visit(_ v: (Vec3, Vec3, Vec3), depth: Int) {
            guard !failed, depth < 12, let code = next() else { failed = true; return }
            let splitSides = code & 3
            if splitSides == 0 {
                var state = code >> 2
                if code & 12 == 12 {
                    guard let extra = next() else { return }
                    state = extra + 3
                }
                if state >= 1 { result.append(PaintedFacet(a: v.0, b: v.1, c: v.2, tool: state - 1)) }
                return
            }
            let children = split(v, sides: splitSides, special: code >> 2)
            // Children are stored last to first.
            for child in children.reversed() { visit(child, depth: depth + 1) }
        }

        visit((a, b, c), depth: 0)
        return failed || position != digits.count ? nil : result
    }

    private static func mid(_ p: Vec3, _ q: Vec3) -> Vec3 { Vec3((p.x + q.x) / 2, (p.y + q.y) / 2, (p.z + q.z) / 2) }

    /// The child triangles in the order OrcaSlicer creates them.
    static func split(_ t: (Vec3, Vec3, Vec3), sides: Int, special: Int) -> [(Vec3, Vec3, Vec3)] {
        let source = [t.0, t.1, t.2]
        var v = (0..<3).map { source[(special + $0) % 3] }
        switch sides {
        case 1:
            v.insert(mid(v[2], v[1]), at: 2)
            return [(v[0], v[1], v[2]), (v[2], v[3], v[0])]
        case 2:
            v.insert(mid(v[1], v[0]), at: 1)
            v.insert(mid(v[0], v[3]), at: 4)
            return [(v[0], v[1], v[4]), (v[1], v[2], v[4]), (v[2], v[3], v[4])]
        default:   // 3
            v.insert(mid(v[1], v[0]), at: 1)
            v.insert(mid(v[3], v[2]), at: 3)
            v.insert(mid(v[0], v[4]), at: 5)
            return [(v[0], v[1], v[5]), (v[1], v[2], v[3]), (v[3], v[4], v[5]), (v[1], v[3], v[5])]
        }
    }
}
