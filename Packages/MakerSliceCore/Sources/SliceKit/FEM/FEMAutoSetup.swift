import Foundation

/// A suggestion for where a part is held and where it is loaded – so the user only has to correct, not to start from zero.
public struct FEMAutoSetup: Sendable {
    public struct Item: Sendable {
        public var region: SurfaceRegion
        public var label: String
    }

    public var supports: [Item]
    public var loads: [Item]
    /// One sentence for the user.
    public var note: String
}

/// Smooth patches of a surface: connected triangles whose neighbours differ by at most `maxAngleDegrees`.
struct SurfacePatches {
    struct Patch {
        var triangles: [Int]
        var area: Double
        var normal: Vec3
    }

    var patches: [Patch] = []

    init(_ mesh: TriangleMesh, maxAngleDegrees: Double = 30) {
        let n = mesh.triangleCount
        guard n > 0 else { return }
        var ids: [Int: Int] = [:]
        var canonical = [Int](repeating: 0, count: mesh.vertices.count)
        for (i, v) in mesh.vertices.enumerated() {
            let key = Int((v.x * 1000).rounded()) &* 73856093 ^ Int((v.y * 1000).rounded()) &* 19349663 ^ Int((v.z * 1000).rounded()) &* 83492791
            if let id = ids[key] { canonical[i] = id } else { ids[key] = i; canonical[i] = i }
        }
        var edges: [Int: [Int]] = [:]
        var normals = [Vec3](repeating: .zero, count: n)
        var areas = [Double](repeating: 0, count: n)
        for t in 0..<n {
            let a = mesh.vertices[Int(mesh.indices[t * 3])], b = mesh.vertices[Int(mesh.indices[t * 3 + 1])], c = mesh.vertices[Int(mesh.indices[t * 3 + 2])]
            let cross = (b - a).cross(c - a)
            areas[t] = cross.length / 2
            normals[t] = cross.length > 1e-12 ? cross * (1 / cross.length) : Vec3(0, 0, 1)
            for k in 0..<3 {
                let p = canonical[Int(mesh.indices[t * 3 + k])], q = canonical[Int(mesh.indices[t * 3 + (k + 1) % 3])]
                edges[min(p, q) &* 1_000_003 &+ max(p, q), default: []].append(t)
            }
        }
        let limit = cos(maxAngleDegrees * .pi / 180)
        var seen = [Bool](repeating: false, count: n)
        for start in 0..<n where !seen[start] {
            var queue = [start], head = 0
            seen[start] = true
            var area = 0.0, sum = Vec3.zero
            while head < queue.count {
                let t = queue[head]; head += 1
                area += areas[t]; sum = sum + normals[t] * areas[t]
                for k in 0..<3 {
                    let p = canonical[Int(mesh.indices[t * 3 + k])], q = canonical[Int(mesh.indices[t * 3 + (k + 1) % 3])]
                    for other in edges[min(p, q) &* 1_000_003 &+ max(p, q)] ?? [] where !seen[other] && normals[other].dot(normals[t]) >= limit {
                        seen[other] = true; queue.append(other)
                    }
                }
            }
            patches.append(Patch(triangles: queue, area: area, normal: sum.length > 1e-12 ? sum * (1 / sum.length) : Vec3(0, 0, 1)))
        }
    }
}

extension FEMAutoSetup {
    /// Screw holes (concave cylinders) as supports; otherwise the face the part rests on. The load is the face farthest from
    /// the supports, pointing up if possible (weight).
    public static func suggest(mesh: TriangleMesh) -> FEMAutoSetup? {
        guard mesh.triangleCount > 0 else { return nil }
        let patches = SurfacePatches(mesh).patches
        let box = mesh.boundingBox
        let totalArea = patches.reduce(0) { $0 + $1.area }
        func region(_ p: SurfacePatches.Patch, _ name: String) -> SurfaceRegion {
            SurfaceRegion(name: name, triangles: p.triangles.map { t in (0..<3).map { mesh.vertices[Int(mesh.indices[t * 3 + $0])] } })
        }

        // Screw holes.
        var bores: [(SurfacePatches.Patch, Double, Double)] = []   // patch, radius, depth
        for p in patches where p.area > 3 && p.triangles.count >= 8 {
            if let (radius, depth) = boreShape(p, mesh) { bores.append((p, radius, depth)) }
        }
        bores.sort { $0.0.area > $1.0.area }
        var supports: [Item] = []
        for (p, radius, depth) in bores.prefix(6) {
            supports.append(Item(region: region(p, "Loch"), label: String(format: "Schraubenloch Ø %.1f mm, %.0f mm tief", radius * 2, depth)))
        }
        if supports.isEmpty, let bottom = SurfaceRegion.bottomFace(of: mesh) {
            supports.append(Item(region: bottom, label: "Auflage unten (Fläche auf dem Druckbett)"))
        }
        guard !supports.isEmpty else { return nil }

        // Load: the large flat face farthest from the supports.
        var centre = Vec3.zero, count = 0.0
        for s in supports { for t in s.region.triangles { for v in t { centre = centre + v; count += 1 } } }
        centre = centre * (1 / max(count, 1))
        let supportAreas = Set(bores.prefix(6).map { $0.0.triangles.first ?? -1 })
        var best: (SurfacePatches.Patch, Double)?
        for p in patches where p.area >= max(totalArea * 0.03, 4) && !supportAreas.contains(p.triangles.first ?? -1) {
            let r = region(p, "Last")
            guard !r.isCurved else { continue }
            var c = Vec3.zero, n = 0.0
            for t in r.triangles { for v in t { c = c + v; n += 1 } }
            c = c * (1 / max(n, 1))
            // Not the supports' own face: skip a patch whose centre is at the support centre (the bottom face).
            let isBottom = supports.first.map { _ in p.normal.z < -0.7 && (c.z - box.min.z) < 0.5 } ?? false
            if isBottom { continue }
            var score = (c - centre).length + (p.normal.z > 0.5 ? box.size.z : 0)
            score += p.normal.z > 0.5 ? 0 : -box.size.z * 0.2
            if best == nil || score > best!.1 { best = (p, score) }
        }
        guard let load = best?.0 else {
            return FEMAutoSetup(supports: supports, loads: [], note: "Halterung vorgeschlagen – tippe die Fläche an, auf die die Kraft wirkt.")
        }
        let loadItem = Item(region: region(load, "Last"), label: load.normal.z > 0.5 ? "Obere Fläche (Gewicht)" : "Fläche mit größtem Abstand")
        let holeText = bores.isEmpty ? "an der Unterseite" : "an \(min(bores.count, 6)) Schraubenloch\(bores.count == 1 ? "" : "ern")"
        return FEMAutoSetup(supports: supports, loads: [loadItem],
                            note: "Vorschlag: gehalten \(holeText); Last: \(loadItem.label). Ändere es durch Tippen aufs Modell.")
    }

    /// (radius, depth) when the patch is a concave cylinder (a hole) of screw size.
    static func boreShape(_ patch: SurfacePatches.Patch, _ mesh: TriangleMesh) -> (Double, Double)? {
        // Axis: the direction all normals are perpendicular to (smallest eigenvector of the normal covariance, found by trying the principal directions).
        var normals: [Vec3] = [], points: [Vec3] = []
        for t in patch.triangles {
            let a = mesh.vertices[Int(mesh.indices[t * 3])], b = mesh.vertices[Int(mesh.indices[t * 3 + 1])], c = mesh.vertices[Int(mesh.indices[t * 3 + 2])]
            let n = (b - a).cross(c - a)
            guard n.length > 1e-12 else { continue }
            normals.append(n.normalized); points.append((a + b + c) * (1.0 / 3.0))
        }
        guard normals.count >= 8 else { return nil }
        // Two non-parallel normals span the plane; the axis is perpendicular to both of the widest-apart pair.
        var axis: Vec3?
        var widest = 0.0
        let first = normals[0]
        for n in normals where abs(n.dot(first)) < 0.95 {
            let a = first.cross(n)
            if a.length > widest { widest = a.length; axis = a.normalized }
        }
        guard let axis, widest > 0.3 else { return nil }
        let worst = normals.map { abs($0.dot(axis)) }.max() ?? 1
        guard worst < 0.25 else { return nil }   // not a cylinder around one axis
        // Centre and radius in the plane perpendicular to the axis.
        let u = (abs(axis.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)).cross(axis).normalized, v = axis.cross(u).normalized
        var cx = 0.0, cy = 0.0
        var lo = Double.infinity, hi = -Double.infinity
        for p in points { cx += p.dot(u); cy += p.dot(v); lo = min(lo, p.dot(axis)); hi = max(hi, p.dot(axis)) }
        cx /= Double(points.count); cy /= Double(points.count)
        var radius = 0.0, inward = 0, maxGap = 0.0
        var angles: [Double] = []
        for (p, n) in zip(points, normals) {
            let dx = p.dot(u) - cx, dy = p.dot(v) - cy
            radius += (dx * dx + dy * dy).squareRoot()
            if n.dot(u) * dx + n.dot(v) * dy < 0 { inward += 1 }
            angles.append(atan2(dy, dx))
        }
        radius /= Double(points.count)
        angles.sort()
        for i in 0..<angles.count { maxGap = max(maxGap, i + 1 < angles.count ? angles[i + 1] - angles[i] : angles[0] + 2 * .pi - angles[i]) }
        let concave = Double(inward) / Double(points.count) > 0.8
        let depth = hi - lo
        guard concave, maxGap < .pi / 2, (1.2...12).contains(radius), depth >= 1 else { return nil }
        return (radius, depth)
    }
}
