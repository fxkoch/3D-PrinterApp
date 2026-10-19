import Foundation

/// 3D point/vector in millimetres.
public struct Vec3: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(0, 0, 0)

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }

    public func cross(_ b: Vec3) -> Vec3 {
        Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x)
    }

    public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    public var normalized: Vec3 {
        let l = length
        return l > 0 ? self * (1 / l) : self
    }
}

/// Axis-aligned bounding box.
public struct BoundingBox: Equatable, Codable, Sendable {
    public var min: Vec3
    public var max: Vec3

    public init(min: Vec3, max: Vec3) {
        self.min = min
        self.max = max
    }

    public static let empty = BoundingBox(
        min: Vec3(.infinity, .infinity, .infinity),
        max: Vec3(-.infinity, -.infinity, -.infinity)
    )

    public var isEmpty: Bool { min.x > max.x }
    public var size: Vec3 { isEmpty ? .zero : max - min }
    public var center: Vec3 { (min + max) * 0.5 }

    public mutating func include(_ p: Vec3) {
        min = Vec3(Swift.min(min.x, p.x), Swift.min(min.y, p.y), Swift.min(min.z, p.z))
        max = Vec3(Swift.max(max.x, p.x), Swift.max(max.y, p.y), Swift.max(max.z, p.z))
    }

    public mutating func include(_ box: BoundingBox) {
        guard !box.isEmpty else { return }
        include(box.min)
        include(box.max)
    }
}

/// Row-major 3x4 affine transform (as used by 3MF: m00 m01 m02 m10 m11 m12 m20 m21 m22 m30 m31 m32).
public struct Transform3D: Equatable, Codable, Sendable {
    /// Columns of the linear part and the translation, 3MF-style: p' = p * M.
    public var m: [Double]

    public init(m: [Double]) {
        precondition(m.count == 12)
        self.m = m
    }

    public static let identity = Transform3D(m: [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0])

    public static func translation(_ t: Vec3) -> Transform3D {
        Transform3D(m: [1, 0, 0, 0, 1, 0, 0, 0, 1, t.x, t.y, t.z])
    }

    public static func scale(_ s: Vec3) -> Transform3D {
        Transform3D(m: [s.x, 0, 0, 0, s.y, 0, 0, 0, s.z, 0, 0, 0])
    }

    /// Rotation around the Z axis in radians.
    public static func rotationZ(_ a: Double) -> Transform3D {
        let c = cos(a), s = sin(a)
        return Transform3D(m: [c, s, 0, -s, c, 0, 0, 0, 1, 0, 0, 0])
    }

    public static func rotationX(_ a: Double) -> Transform3D {
        let c = cos(a), s = sin(a)
        return Transform3D(m: [1, 0, 0, 0, c, s, 0, -s, c, 0, 0, 0])
    }

    public static func rotationY(_ a: Double) -> Transform3D {
        let c = cos(a), s = sin(a)
        return Transform3D(m: [c, 0, -s, 0, 1, 0, s, 0, c, 0, 0, 0])
    }

    /// Parses the 3MF "transform" attribute (12 space-separated numbers).
    public init?(threeMF string: String) {
        let values = string.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).compactMap { Double($0) }
        guard values.count == 12 else { return nil }
        self.init(m: values)
    }

    public func apply(_ p: Vec3) -> Vec3 {
        Vec3(
            p.x * m[0] + p.y * m[3] + p.z * m[6] + m[9],
            p.x * m[1] + p.y * m[4] + p.z * m[7] + m[10],
            p.x * m[2] + p.y * m[5] + p.z * m[8] + m[11]
        )
    }

    /// Returns the transform that first applies `self`, then `other`.
    public func then(_ other: Transform3D) -> Transform3D {
        let a = m, b = other.m
        var r = [Double](repeating: 0, count: 12)
        for row in 0..<4 {
            for col in 0..<3 {
                var v = 0.0
                for k in 0..<3 { v += a[row * 3 + k] * b[k * 3 + col] }
                if row == 3 { v += b[9 + col] }
                r[row * 3 + col] = v
            }
        }
        return Transform3D(m: r)
    }

    /// True when the transform mirrors geometry (negative determinant).
    public var isMirroring: Bool {
        let det = m[0] * (m[4] * m[8] - m[5] * m[7])
            - m[1] * (m[3] * m[8] - m[5] * m[6])
            + m[2] * (m[3] * m[7] - m[4] * m[6])
        return det < 0
    }
}
