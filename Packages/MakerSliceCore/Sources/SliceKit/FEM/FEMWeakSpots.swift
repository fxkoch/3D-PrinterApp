import Foundation

extension SurfaceRegion {
    /// A round patch of `radius` around a point on the surface (a load that acts on one spot, not on the whole face).
    public static func disc(center: Vec3, normal: Vec3, radius: Double, name: String) -> SurfaceRegion {
        let n = normal.normalized
        let helper = abs(n.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        let u = n.cross(helper).normalized, v = n.cross(u).normalized
        let segments = 16
        var triangles: [[Vec3]] = []
        for s in 0..<segments {
            let a0 = Double(s) / Double(segments) * 2 * .pi, a1 = Double(s + 1) / Double(segments) * 2 * .pi
            let p0 = center + u * (cos(a0) * radius) + v * (sin(a0) * radius)
            let p1 = center + u * (cos(a1) * radius) + v * (sin(a1) * radius)
            // Wound so that the normal points out of the surface.
            let tri = [center, p0, p1]
            let c = (tri[1] - tri[0]).cross(tri[2] - tri[0])
            triangles.append(c.dot(n) >= 0 ? tri : [center, p1, p0])
        }
        return SurfaceRegion(name: name, triangles: triangles)
    }

    /// Lowest roughly horizontal face looking down (where the part sits on the bed), grown to the whole face.
    static func bottomFace(of mesh: TriangleMesh) -> SurfaceRegion? {
        var best: (Int, Double)?
        for t in 0..<mesh.triangleCount {
            let n = mesh.faceNormal(t)
            guard n.z < -0.7 else { continue }
            let z = (0..<3).map { mesh.vertices[Int(mesh.indices[t * 3 + $0])].z }.reduce(0, +) / 3
            if best == nil || z < best!.1 - 1e-6 { best = (t, z) }
        }
        return best.map { SurfaceRegion.grow(from: $0.0, in: mesh, name: "Auflage", maxAngleDegrees: 15) }
    }

    /// Highest face looking up.
    static func topFace(of mesh: TriangleMesh) -> SurfaceRegion? {
        var best: (Int, Double)?
        for t in 0..<mesh.triangleCount {
            let n = mesh.faceNormal(t)
            guard n.z > 0.5 else { continue }
            let z = (0..<3).map { mesh.vertices[Int(mesh.indices[t * 3 + $0])].z }.reduce(0, +) / 3
            if best == nil || z > best!.1 + 1e-6 { best = (t, z) }
        }
        return best.map { SurfaceRegion.grow(from: $0.0, in: mesh, name: "Obere Fläche", maxAngleDegrees: 25) }
    }
}

/// A place that gives way first.
public struct WeakSpot: Sendable, Identifiable {
    public var id = UUID()
    public var location: Vec3
    /// 1 = the most stressed place of the part.
    public var relativeStress: Double
    /// Material thickness around the spot (smallest of the three axes), mm.
    public var thickness: Double
    public var reason: String
}

public struct WeakSpotReport: Sendable {
    /// Result whose `failure` shows relative stress (1 = weakest place) for the picture.
    public var result: FEMResult
    public var spots: [WeakSpot]
    /// Smallest safety factor of the three test pushes (10 N each): only to compare variants of the same part.
    public var testSafetyFactor: Double
}

public enum FEMWeakSpots {
    /// Finds weak places without a given load: the part sits on its bed face and is pushed on top from the side
    /// and from above/below with the same force; the most stressed places over all pushes are the weak spots.
    @_optimize(speed)
    public static func scan(mesh: TriangleMesh, material: FEMMaterial, setup: FEMPrintSetup, options: FEMOptions = .fast,
                            progress: (String, Double) -> Void = { _, _ in }, isCancelled: () -> Bool = { false }) throws -> WeakSpotReport {
        guard let fixed = SurfaceRegion.bottomFace(of: mesh) else { throw FEMError.noFixedSupport }
        guard let top = SurfaceRegion.topFace(of: mesh) else { throw FEMError.noLoad }
        let force = 10.0
        let directions = [Vec3(force, 0, 0), Vec3(0, force, 0), Vec3(0, 0, -force)]
        var merged: FEMResult?
        var failure: [Float] = []
        var safety = Double.infinity
        for (n, dir) in directions.enumerated() {
            progress("Belastung \(n + 1) von \(directions.count) prüfen", Double(n) / Double(directions.count))
            let lc = FEMLoadCase(fixed: [fixed], loads: [.init(region: top, force: dir)])
            let r = try FEMAnalysis.run(mesh: mesh, material: material, setup: setup, loadCase: lc, options: options, isCancelled: isCancelled)
            safety = min(safety, r.safetyFactor)
            let peak = Float(max(r.peakFailureIndex, 1e-9))
            if merged == nil { merged = r; failure = r.failure.map { $0 / peak } } else {
                for i in 0..<failure.count { failure[i] = max(failure[i], r.failure[i] / peak) }
            }
        }
        guard var result = merged else { throw FEMError.emptyModel }
        result.failure = failure
        result.peakFailureIndex = 1

        progress("Fertig", 1)
        return WeakSpotReport(result: result, spots: spots(in: result, setup: setup), testSafetyFactor: safety)
    }

    /// The most stressed places of a result (local maxima at least 5 mm apart, at most four).
    static func spots(in result: FEMResult, setup: FEMPrintSetup) -> [WeakSpot] {
        let grid = result.grid
        let peak = max(result.failure.max() ?? 1, 1e-9)
        var candidates: [(Int, Float)] = []
        for i in 0..<result.failure.count where result.failure[i] >= 0.5 * peak { candidates.append((i, result.failure[i] / peak)) }
        candidates.sort { $0.1 > $1.1 }
        let spacing = max(5.0, grid.h * 4)
        var spots: [WeakSpot] = []
        for (cell, value) in candidates {
            let k = cell / (grid.nx * grid.ny), j = (cell / grid.nx) % grid.ny, i = cell % grid.nx
            let p = Vec3(grid.origin.x + (Double(i) + 0.5) * grid.h, grid.origin.y + (Double(j) + 0.5) * grid.h, grid.origin.z + (Double(k) + 0.5) * grid.h)
            if spots.contains(where: { ($0.location - p).length < spacing }) { continue }
            let thickness = localThickness(grid, i, j, k)
            var reason = "Hohe Spannung an einer Kante oder einem Übergang."
            if thickness < max(3, 0.4 * min(Double(grid.nx), Double(grid.ny)) * grid.h) { reason = String(format: "Dünne Stelle (etwa %.1f mm).", thickness) }
            if let s = result.stress(at: p) {
                let along = abs(s[2]) + abs(s[4]) + abs(s[5]), all = s.map(abs).reduce(0, +)
                if all > 0, along / all > 0.55 { reason += " Die Kraft wirkt quer zu den Schichten – das ist die schwächste Richtung." }
            }
            spots.append(WeakSpot(location: p, relativeStress: Double(value), thickness: thickness, reason: reason))
            if spots.count == 4 { break }
        }
        return spots
    }

    /// Smallest extent of solid cubes through (i, j, k) along the three axes, mm.
    static func localThickness(_ g: VoxelGrid, _ i: Int, _ j: Int, _ k: Int) -> Double {
        func run(_ di: Int, _ dj: Int, _ dk: Int) -> Int {
            var n = 1
            var (a, b, c) = (i + di, j + dj, k + dk)
            while n < 400, g.isSolid(a, b, c) { n += 1; a += di; b += dj; c += dk }
            (a, b, c) = (i - di, j - dj, k - dk)
            while n < 400, g.isSolid(a, b, c) { n += 1; a -= di; b -= dj; c -= dk }
            return n
        }
        return Double(min(run(1, 0, 0), run(0, 1, 0), run(0, 0, 1))) * g.h
    }
}

/// Thickens the surface around weak spots a little (smooth bulge, at most `depth` mm), keeping the shape otherwise.
public enum MeshReinforcer {
    public static func thicken(_ input: TriangleMesh, spots: [(center: Vec3, radius: Double, depth: Double)],
                               keepAway: [Vec3] = []) -> TriangleMesh {
        var mesh = input
        guard !spots.isEmpty else { return mesh }
        func near(_ p: Vec3, _ margin: Double) -> Bool { spots.contains { ($0.center - p).length < $0.radius + margin } }

        // Split long edges inside the spots (same split for both triangles that share an edge).
        let target = max(0.5, (spots.map(\.radius).min() ?? 4) / 4)
        for _ in 0..<7 {
            var splits: [UInt64: UInt32] = [:]
            func key(_ a: UInt32, _ b: UInt32) -> UInt64 { UInt64(min(a, b)) << 32 | UInt64(max(a, b)) }
            var anyLong = false
            for t in 0..<mesh.triangleCount {
                for e in 0..<3 {
                    let a = mesh.indices[t * 3 + e], b = mesh.indices[t * 3 + (e + 1) % 3]
                    let pa = mesh.vertices[Int(a)], pb = mesh.vertices[Int(b)]
                    if (pb - pa).length > target, near((pa + pb) * 0.5, 0) {
                        let k = key(a, b)
                        if splits[k] == nil {
                            splits[k] = UInt32(mesh.vertices.count)
                            mesh.vertices.append((pa + pb) * 0.5)
                        }
                        anyLong = true
                    }
                }
            }
            if !anyLong || mesh.triangleCount > 600_000 { break }
            var indices: [UInt32] = []
            indices.reserveCapacity(mesh.indices.count * 2)
            for t in 0..<mesh.triangleCount {
                let v = [mesh.indices[t * 3], mesh.indices[t * 3 + 1], mesh.indices[t * 3 + 2]]
                let m = (0..<3).map { splits[key(v[$0], v[($0 + 1) % 3])] }   // midpoint on edge v[e]–v[e+1]
                switch m.compactMap({ $0 }).count {
                case 0: indices += v
                case 1:
                    let e = m.firstIndex { $0 != nil }!
                    let a = v[e], b = v[(e + 1) % 3], c = v[(e + 2) % 3], mid = m[e]!
                    indices += [a, mid, c, mid, b, c]
                case 2:
                    // Edge e is the one without a midpoint.
                    let e = m.firstIndex { $0 == nil }!
                    let a = v[e], b = v[(e + 1) % 3], c = v[(e + 2) % 3]
                    let mbc = m[(e + 1) % 3]!, mca = m[(e + 2) % 3]!
                    indices += [a, b, mbc, a, mbc, mca, mca, mbc, c]
                default:
                    let (mab, mbc, mca) = (m[0]!, m[1]!, m[2]!)
                    indices += [v[0], mab, mca, mab, v[1], mbc, mca, mbc, v[2], mab, mbc, mca]
                }
            }
            mesh.indices = indices
        }

        // Vertex normals (area weighted), then the bulge.
        var normals = [Vec3](repeating: .zero, count: mesh.vertices.count)
        for t in 0..<mesh.triangleCount {
            let a = Int(mesh.indices[t * 3]), b = Int(mesh.indices[t * 3 + 1]), c = Int(mesh.indices[t * 3 + 2])
            let n = (mesh.vertices[b] - mesh.vertices[a]).cross(mesh.vertices[c] - mesh.vertices[a])
            normals[a] = normals[a] + n; normals[b] = normals[b] + n; normals[c] = normals[c] + n
        }
        var protected = Set<Vec3>()
        for p in keepAway { protected.insert(Vec3((p.x * 2).rounded() / 2, (p.y * 2).rounded() / 2, (p.z * 2).rounded() / 2)) }
        for i in 0..<mesh.vertices.count {
            let p = mesh.vertices[i]
            var shift = 0.0
            for s in spots {
                let d = (p - s.center).length
                if d < s.radius { let w = 0.5 * (1 + cos(.pi * d / s.radius)); shift = max(shift, s.depth * w) }
            }
            guard shift > 0 else { continue }
            if protected.contains(Vec3((p.x * 2).rounded() / 2, (p.y * 2).rounded() / 2, (p.z * 2).rounded() / 2)) { continue }
            mesh.vertices[i] = p + normals[i].normalized * shift
        }
        return mesh
    }
}

/// A reinforced variant of the part: small local thickening where it is stressed most.
public struct FEMReinforcement: Sendable {
    public var mesh: TriangleMesh
    public var spots: [WeakSpot]
    /// Largest shift of the surface, mm.
    public var maxShift: Double
    public var safetyRatio: Double
    public var massRatio: Double
}

extension FEMWeakSpots {
    /// Thickens the most stressed places by at most 1.5 mm (smooth, rest of the shape untouched) and checks with the
    /// same calculation that the part is really stronger. Uses `loadCase` if given, else the weak-spot test pushes.
    /// Returns nil when no variant gains at least 5 %.
    public static func reinforce(mesh: TriangleMesh, material: FEMMaterial, setup: FEMPrintSetup, loadCase: FEMLoadCase?,
                                 options: FEMOptions = .fast, progress: (String, Double) -> Void = { _, _ in },
                                 isCancelled: () -> Bool = { false }) throws -> FEMReinforcement? {
        func evaluate(_ m: TriangleMesh) throws -> (safety: Double, mass: Double, spots: [WeakSpot]) {
            if let loadCase {
                let r = try FEMAnalysis.run(mesh: m, material: material, setup: setup, loadCase: loadCase, options: options, isCancelled: isCancelled)
                return (r.safetyFactor, r.massGrams, spots(in: r, setup: setup))
            }
            let report = try scan(mesh: m, material: material, setup: setup, options: options, isCancelled: isCancelled)
            return (report.testSafetyFactor, report.result.massGrams, report.spots)
        }
        progress("Ausgangsform prüfen", 0)
        let base = try evaluate(mesh)
        guard !base.spots.isEmpty else { return nil }
        let keep = (loadCase?.fixed ?? []) + (loadCase?.loads.map(\.region) ?? [])
        let keepPoints = keep.flatMap { $0.triangles.flatMap { $0 } }
        var best: FEMReinforcement?
        for (n, factor) in [1.0, 1.7].enumerated() {
            progress("Verstärkung \(n + 1) prüfen", 0.3 + 0.35 * Double(n))
            if isCancelled() { throw FEMError.cancelled }
            let spotSpec = base.spots.map { s -> (center: Vec3, radius: Double, depth: Double) in
                (s.location, max(6, s.thickness * 1.5), min(1.5, max(0.4, 0.2 * s.thickness) * factor))
            }
            let shifted = MeshReinforcer.thicken(mesh, spots: spotSpec, keepAway: keepPoints)
            guard let after = try? evaluate(shifted) else { continue }
            let ratio = after.safety / max(base.safety, 1e-9)
            if ratio >= 1.05, best == nil || ratio > best!.safetyRatio {
                best = FEMReinforcement(mesh: shifted, spots: base.spots, maxShift: spotSpec.map(\.depth).max() ?? 0,
                                        safetyRatio: ratio, massRatio: after.mass / max(base.mass, 1e-9))
            }
        }
        progress("Fertig", 1)
        return best
    }
}
