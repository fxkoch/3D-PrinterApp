import Foundation

/// Indexed triangle mesh in millimetres.
public struct TriangleMesh: Sendable, Equatable {
    public var vertices: [Vec3]
    /// Three vertex indices per triangle.
    public var indices: [UInt32]

    public init(vertices: [Vec3] = [], indices: [UInt32] = []) {
        self.vertices = vertices
        self.indices = indices
    }

    public var triangleCount: Int { indices.count / 3 }
    public var isEmpty: Bool { indices.isEmpty }

    public var boundingBox: BoundingBox {
        var box = BoundingBox.empty
        for v in vertices { box.include(v) }
        return box
    }

    /// Builds an indexed mesh from a triangle soup, merging coincident vertices.
    public init(soup triangles: [(Vec3, Vec3, Vec3)]) {
        var welder = VertexWelder()
        var indices: [UInt32] = []
        indices.reserveCapacity(triangles.count * 3)
        for (a, b, c) in triangles {
            let ia = welder.index(of: a), ib = welder.index(of: b), ic = welder.index(of: c)
            // Skip degenerate triangles produced by welding.
            if ia == ib || ib == ic || ia == ic { continue }
            indices.append(ia); indices.append(ib); indices.append(ic)
        }
        self.init(vertices: welder.vertices, indices: indices)
    }

    public func transformed(_ t: Transform3D) -> TriangleMesh {
        var copy = self
        copy.vertices = vertices.map(t.apply)
        if t.isMirroring {
            // Keep outward-facing winding after a mirror.
            for i in stride(from: 0, to: copy.indices.count, by: 3) {
                copy.indices.swapAt(i + 1, i + 2)
            }
        }
        return copy
    }

    public mutating func append(_ other: TriangleMesh) {
        let base = UInt32(vertices.count)
        vertices.append(contentsOf: other.vertices)
        indices.append(contentsOf: other.indices.map { $0 + base })
    }

    /// Moves the mesh so it rests on z = 0 with its XY centre at `center`.
    public func placedOnBed(center: (x: Double, y: Double)) -> TriangleMesh {
        let box = boundingBox
        guard !box.isEmpty else { return self }
        return transformed(.translation(Vec3(center.x - box.center.x, center.y - box.center.y, -box.min.z)))
    }

    /// Volume in mm³ (assumes a closed, consistently wound mesh).
    public var volume: Double {
        var v = 0.0
        for i in stride(from: 0, to: indices.count, by: 3) {
            let a = vertices[Int(indices[i])], b = vertices[Int(indices[i + 1])], c = vertices[Int(indices[i + 2])]
            v += a.dot(b.cross(c)) / 6
        }
        return abs(v)
    }

    /// Per-face normals, used for previews and "lay flat".
    public func faceNormal(_ triangle: Int) -> Vec3 {
        let a = vertices[Int(indices[triangle * 3])]
        let b = vertices[Int(indices[triangle * 3 + 1])]
        let c = vertices[Int(indices[triangle * 3 + 2])]
        return (b - a).cross(c - a).normalized
    }

    /// Rotates the mesh so the largest roughly-coplanar face group faces down.
    public func laidFlat() -> TriangleMesh {
        var areaByNormal: [Vec3: (area: Double, normal: Vec3)] = [:]
        for t in 0..<triangleCount {
            let a = vertices[Int(indices[t * 3])]
            let b = vertices[Int(indices[t * 3 + 1])]
            let c = vertices[Int(indices[t * 3 + 2])]
            let cross = (b - a).cross(c - a)
            let area = cross.length / 2
            guard area > 0 else { continue }
            let n = cross.normalized
            let key = Vec3((n.x * 50).rounded(), (n.y * 50).rounded(), (n.z * 50).rounded())
            areaByNormal[key, default: (0, n)].area += area
        }
        guard let best = areaByNormal.values.max(by: { $0.area < $1.area })?.normal else { return self }
        return transformed(Transform3D.rotationAligning(best, to: Vec3(0, 0, -1)))
    }
}

extension Transform3D {
    /// Rotation that maps unit vector `from` onto unit vector `to` (Rodrigues).
    static func rotationAligning(_ from: Vec3, to: Vec3) -> Transform3D {
        let f = from.normalized, t = to.normalized
        let v = f.cross(t)
        let c = f.dot(t)
        if c > 0.999999 { return .identity }
        if c < -0.999999 {
            // 180°: rotate around any axis perpendicular to `from`.
            return abs(f.x) < 0.9 ? .rotationX(.pi) : .rotationY(.pi)
        }
        let k = 1 / (1 + c)
        // Column-vector rotation matrix R; 3MF layout stores R transposed (p' = p * M).
        let r00 = v.x * v.x * k + c, r01 = v.x * v.y * k - v.z, r02 = v.x * v.z * k + v.y
        let r10 = v.y * v.x * k + v.z, r11 = v.y * v.y * k + c, r12 = v.y * v.z * k - v.x
        let r20 = v.z * v.x * k - v.y, r21 = v.z * v.y * k + v.x, r22 = v.z * v.z * k + c
        return Transform3D(m: [r00, r10, r20, r01, r11, r21, r02, r12, r22, 0, 0, 0])
    }
}

/// Merges vertices that are within 1 µm of each other.
struct VertexWelder {
    private(set) var vertices: [Vec3] = []
    private var lookup: [Key: UInt32] = [:]

    private struct Key: Hashable {
        let x: Int64, y: Int64, z: Int64
    }

    mutating func index(of v: Vec3) -> UInt32 {
        let key = Key(x: Int64((v.x * 1000).rounded()), y: Int64((v.y * 1000).rounded()), z: Int64((v.z * 1000).rounded()))
        if let existing = lookup[key] { return existing }
        let idx = UInt32(vertices.count)
        vertices.append(v)
        lookup[key] = idx
        return idx
    }
}
