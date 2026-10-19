import CClipper
import Foundation

/// Integer 2D point in micrometres (1 mm = 1000 units). Integer coordinates keep
/// polygon clipping robust.
public struct IntPoint: Hashable, Codable, Sendable {
    public var x: Int64
    public var y: Int64

    public init(_ x: Int64, _ y: Int64) {
        self.x = x
        self.y = y
    }

    public init(mmX: Double, mmY: Double) {
        x = Int64((mmX * Units.perMM).rounded())
        y = Int64((mmY * Units.perMM).rounded())
    }

    public var mmX: Double { Double(x) / Units.perMM }
    public var mmY: Double { Double(y) / Units.perMM }

    public func distance(to other: IntPoint) -> Double {
        let dx = Double(other.x - x), dy = Double(other.y - y)
        return (dx * dx + dy * dy).squareRoot()
    }

    public func distanceSquared(to other: IntPoint) -> Double {
        let dx = Double(other.x - x), dy = Double(other.y - y)
        return dx * dx + dy * dy
    }
}

public enum Units {
    public static let perMM: Double = 1000
    public static func from(mm: Double) -> Double { mm * perMM }
}

public typealias Path = [IntPoint]

/// A set of closed outlines interpreted with the even-odd/non-zero rule
/// (outer boundaries counter-clockwise, holes clockwise after normalisation).
public struct Polygons: Sendable, Equatable {
    public var paths: [Path]

    public init(_ paths: [Path] = []) {
        self.paths = paths.filter { $0.count >= 3 }
    }

    public var isEmpty: Bool { paths.isEmpty }

    /// Total enclosed area in mm².
    public var areaMM2: Double {
        paths.reduce(0) { $0 + Polygons.signedArea($1) } / (Units.perMM * Units.perMM)
    }

    public var boundingBox: (min: IntPoint, max: IntPoint)? {
        var minX = Int64.max, minY = Int64.max, maxX = Int64.min, maxY = Int64.min
        for path in paths {
            for p in path {
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
        }
        return minX == .max ? nil : (IntPoint(minX, minY), IntPoint(maxX, maxY))
    }

    public static func signedArea(_ path: Path) -> Double {
        guard path.count >= 3 else { return 0 }
        var area = 0.0
        var prev = path[path.count - 1]
        for p in path {
            area += Double(prev.x) * Double(p.y) - Double(p.x) * Double(prev.y)
            prev = p
        }
        return area / 2
    }

    /// Even-odd point-in-polygon test across all outlines.
    public func contains(_ point: IntPoint) -> Bool {
        var inside = false
        for path in paths {
            var j = path.count - 1
            for i in 0..<path.count {
                let a = path[i], b = path[j]
                if (a.y > point.y) != (b.y > point.y) {
                    let x = Double(b.x - a.x) * Double(point.y - a.y) / Double(b.y - a.y) + Double(a.x)
                    if Double(point.x) < x { inside.toggle() }
                }
                j = i
            }
        }
        return inside
    }

    // MARK: - Clipper bridge

    public enum JoinType { case square, round, miter }

    /// Offsets outlines by `deltaMM` (negative shrinks).
    public func offset(_ deltaMM: Double, join: JoinType = .miter, miterLimit: Double = 3) -> Polygons {
        guard !isEmpty else { return self }
        let jt: Int32 = join == .round ? Int32(CC_JOIN_ROUND) : join == .miter ? Int32(CC_JOIN_MITER) : Int32(CC_JOIN_SQUARE)
        return Polygons.withFlat(paths) { xy, counts, n in
            Polygons.consume(cc_offset(xy, counts, n, deltaMM * Units.perMM, jt, miterLimit))
        }
    }

    public func union(_ other: Polygons = Polygons()) -> Polygons {
        boolean(Int32(CC_OP_UNION), other, fill: Int32(CC_FILL_NONZERO))
    }

    public func difference(_ other: Polygons) -> Polygons {
        if other.isEmpty || isEmpty { return isEmpty ? self : union() }
        return boolean(Int32(CC_OP_DIFFERENCE), other, fill: Int32(CC_FILL_NONZERO))
    }

    public func intersection(_ other: Polygons) -> Polygons {
        if other.isEmpty || isEmpty { return Polygons() }
        return boolean(Int32(CC_OP_INTERSECTION), other, fill: Int32(CC_FILL_NONZERO))
    }

    /// Resolves raw slice loops (arbitrary orientation, holes as nested loops)
    /// into clean polygons using the even-odd rule.
    public func resolvedEvenOdd() -> Polygons {
        boolean(Int32(CC_OP_UNION), Polygons(), fill: Int32(CC_FILL_EVENODD))
    }

    public func simplified(toleranceMM: Double) -> Polygons {
        guard !isEmpty else { return self }
        return Polygons.withFlat(paths) { xy, counts, n in
            Polygons.consume(cc_simplify(xy, counts, n, toleranceMM * Units.perMM))
        }
    }

    /// Splits the outlines into triangles (for closing cut faces).
    public func triangulated() -> [Path] {
        guard !isEmpty else { return [] }
        return Polygons.withFlat(paths) { xy, counts, n in
            Polygons.consumePaths(cc_triangulate(xy, counts, n))
        }.filter { $0.count == 3 }
    }

    /// Returns the parts of the open polylines `lines` that lie inside `self`.
    public func clip(lines: [Path]) -> [Path] {
        guard !isEmpty, !lines.isEmpty else { return [] }
        return Polygons.withFlat(lines) { lxy, lcounts, ln in
            Polygons.withFlat(paths) { cxy, ccounts, cn in
                Polygons.consumePaths(cc_clip_lines(lxy, lcounts, ln, cxy, ccounts, cn))
            }
        }.filter { $0.count >= 2 }
    }

    private func boolean(_ op: Int32, _ other: Polygons, fill: Int32) -> Polygons {
        Polygons.withFlat(paths) { sxy, scounts, sn in
            Polygons.withFlat(other.paths) { cxy, ccounts, cn in
                Polygons.consume(cc_boolean(op, fill, sxy, scounts, sn, cxy, ccounts, cn))
            }
        }
    }

    private static func withFlat<R>(_ paths: [Path], _ body: (UnsafePointer<Int64>, UnsafePointer<Int>, Int) -> R) -> R {
        var xy: [Int64] = []
        xy.reserveCapacity(paths.reduce(0) { $0 + $1.count } * 2 + 2)
        var counts: [Int] = []
        counts.reserveCapacity(paths.count + 1)
        for path in paths {
            counts.append(path.count)
            for p in path {
                xy.append(p.x)
                xy.append(p.y)
            }
        }
        // Never hand out empty buffers: their base address may be nil.
        xy.append(0)
        counts.append(0)
        return xy.withUnsafeBufferPointer { xyBuf in
            counts.withUnsafeBufferPointer { cBuf in
                body(xyBuf.baseAddress!, cBuf.baseAddress!, paths.count)
            }
        }
    }

    private static func consume(_ result: UnsafeMutablePointer<cc_paths>?) -> Polygons {
        Polygons(consumePaths(result))
    }

    private static func consumePaths(_ result: UnsafeMutablePointer<cc_paths>?) -> [Path] {
        guard let result else { return [] }
        defer { cc_free(result) }
        var out: [Path] = []
        out.reserveCapacity(result.pointee.path_count)
        var offset = 0
        for i in 0..<result.pointee.path_count {
            let count = result.pointee.counts[i]
            var path: Path = []
            path.reserveCapacity(count)
            for j in 0..<count {
                let k = (offset + j) * 2
                path.append(IntPoint(result.pointee.xy[k], result.pointee.xy[k + 1]))
            }
            offset += count
            out.append(path)
        }
        return out
    }
}

public extension Polygons {
    static func rectangle(minX: Double, minY: Double, maxX: Double, maxY: Double) -> Polygons {
        Polygons([[
            IntPoint(mmX: minX, mmY: minY), IntPoint(mmX: maxX, mmY: minY),
            IntPoint(mmX: maxX, mmY: maxY), IntPoint(mmX: minX, mmY: maxY),
        ]])
    }

    static func + (lhs: Polygons, rhs: Polygons) -> Polygons {
        Polygons(lhs.paths + rhs.paths)
    }
}
