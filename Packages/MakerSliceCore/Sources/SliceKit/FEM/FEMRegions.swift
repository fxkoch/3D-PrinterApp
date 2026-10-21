import Foundation

/// A face of the model chosen for a support or a load: the flat patch around a tapped triangle.
public struct SurfaceRegion: Sendable, Equatable {
    public var name: String
    /// Triangles as three points each (model coordinates, mm).
    public var triangles: [[Vec3]]
    /// Average outward normal.
    public var normal: Vec3
    public var area: Double

    public init(name: String, triangles: [[Vec3]]) {
        self.name = name
        self.triangles = triangles
        var n = Vec3.zero
        var area = 0.0
        for t in triangles where t.count == 3 {
            let c = (t[1] - t[0]).cross(t[2] - t[0])
            n = n + c
            area += c.length / 2
        }
        self.normal = n.length > 1e-12 ? n * (1 / n.length) : Vec3(0, 0, 1)
        self.area = area
    }

    /// True for rounded areas (bores, cylinders): the triangle normals point in clearly different directions.
    public var isCurved: Bool {
        var sum = Vec3.zero, total = 0.0
        for t in triangles where t.count == 3 {
            let c = (t[1] - t[0]).cross(t[2] - t[0])
            sum = sum + c
            total += c.length
        }
        return total > 0 && sum.length / total < 0.6
    }

    /// What a tap on triangle `seed` means: a flat face, or – when the triangle belongs to a bore or another rounded
    /// feature – that whole rounded feature up to its sharp edges. Rounded areas that would cover most of the model
    /// (a sphere) count as flat patches instead.
    public static func pick(from seed: Int, in mesh: TriangleMesh, name: String) -> SurfaceRegion {
        let flat = grow(from: seed, in: mesh, name: name, maxAngleDegrees: 20)
        let round = grow(from: seed, in: mesh, name: name, maxAngleDegrees: 30, smooth: true, limit: max(mesh.triangleCount / 2, 8))
        if round.triangles.count > flat.triangles.count * 3 / 2, round.isCurved, round.triangles.count < mesh.triangleCount * 45 / 100 { return round }
        return flat
    }

    public func transformed(_ t: Transform3D) -> SurfaceRegion {
        SurfaceRegion(name: name, triangles: triangles.map { $0.map { t.apply($0) } })
    }

    /// The connected, nearly flat area around triangle `seed` (angle to the seed's normal at most `maxAngleDegrees`).
    /// With `smooth` the angle is compared between neighbouring triangles instead of with the seed: the region follows
    /// a rounded surface (a bore, a fillet, a cylinder) up to the next sharp edge. `limit` caps the number of triangles.
    public static func grow(from seed: Int, in mesh: TriangleMesh, name: String, maxAngleDegrees: Double = 25,
                            smooth: Bool = false, limit maxTriangles: Int = 20_000) -> SurfaceRegion {
        guard seed >= 0, seed < mesh.triangleCount else { return SurfaceRegion(name: name, triangles: []) }
        // Merge duplicated vertices so triangles of a soup still touch.
        var ids: [Int: Int] = [:]
        var canonical = [Int](repeating: 0, count: mesh.vertices.count)
        for (i, v) in mesh.vertices.enumerated() {
            let key = Int((v.x * 1000).rounded()) &* 73856093 ^ Int((v.y * 1000).rounded()) &* 19349663 ^ Int((v.z * 1000).rounded()) &* 83492791
            if let id = ids[key] { canonical[i] = id } else { ids[key] = i; canonical[i] = i }
        }
        func vertex(_ t: Int, _ c: Int) -> Int { canonical[Int(mesh.indices[t * 3 + c])] }
        var edges: [Int: [Int]] = [:]
        for t in 0..<mesh.triangleCount {
            for c in 0..<3 {
                let a = vertex(t, c), b = vertex(t, (c + 1) % 3)
                edges[min(a, b) &* 1_000_003 &+ max(a, b), default: []].append(t)
            }
        }
        func normal(_ t: Int) -> Vec3 {
            let a = mesh.vertices[Int(mesh.indices[t * 3])], b = mesh.vertices[Int(mesh.indices[t * 3 + 1])], c = mesh.vertices[Int(mesh.indices[t * 3 + 2])]
            let n = (b - a).cross(c - a)
            return n.length > 1e-12 ? n * (1 / n.length) : Vec3(0, 0, 1)
        }
        let seedNormal = normal(seed)
        let limit = cos(maxAngleDegrees * .pi / 180)
        var seen: Set<Int> = [seed]
        var queue = [seed]
        var head = 0
        while head < queue.count {
            let t = queue[head]; head += 1
            if queue.count >= maxTriangles { break }
            let reference = smooth ? normal(t) : seedNormal
            for c in 0..<3 {
                let a = vertex(t, c), b = vertex(t, (c + 1) % 3)
                for other in edges[min(a, b) &* 1_000_003 &+ max(a, b)] ?? [] where !seen.contains(other) {
                    if normal(other).dot(reference) >= limit { seen.insert(other); queue.append(other) }
                }
            }
        }
        let triangles = queue.map { t in (0..<3).map { mesh.vertices[Int(mesh.indices[t * 3 + $0])] } }
        return SurfaceRegion(name: name, triangles: triangles)
    }
}

/// Supports and loads of an analysis.
public struct FEMLoadCase: Sendable {
    public struct Load: Sendable {
        public var region: SurfaceRegion
        /// Total force on the region in N.
        public var force: Vec3

        public init(region: SurfaceRegion, force: Vec3) {
            self.region = region
            self.force = force
        }
    }

    public var fixed: [SurfaceRegion]
    public var loads: [Load]

    public init(fixed: [SurfaceRegion], loads: [Load]) {
        self.fixed = fixed
        self.loads = loads
    }

    public func transformed(_ t: Transform3D) -> FEMLoadCase {
        // Forces rotate with the model (direction only).
        let origin = t.apply(.zero)
        return FEMLoadCase(fixed: fixed.map { $0.transformed(t) },
                           loads: loads.map { Load(region: $0.region.transformed(t), force: t.apply($0.force) - origin) })
    }
}
