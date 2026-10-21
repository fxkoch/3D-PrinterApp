import Foundation

/// Cleans up scanned meshes so they can be sliced: welds vertices, keeps the main body, closes holes, fixes the winding.
public enum MeshRepair {
    public struct Report: Sendable, Equatable {
        public var removedFragments = 0
        public var closedHoles = 0
        public var openEdgesLeft = 0
        public var flipped = false
        public var watertight: Bool { openEdgesLeft == 0 }
    }

    /// Edges used by exactly one triangle (the rim of holes).
    public static func openEdgeCount(_ mesh: TriangleMesh) -> Int {
        var directed: [UInt64: Int] = [:]
        for t in 0..<mesh.triangleCount { for e in 0..<3 {
            directed[key(mesh.indices[t * 3 + e], mesh.indices[t * 3 + (e + 1) % 3]), default: 0] += 1
        } }
        return directed.reduce(0) { sum, kv in
            let (a, b) = (UInt32(kv.key >> 32), UInt32(kv.key & 0xffff_ffff))
            return sum + (directed[key(b, a)] == nil ? kv.value : 0)
        }
    }

    private static func key(_ a: UInt32, _ b: UInt32) -> UInt64 { UInt64(a) << 32 | UInt64(b) }

    public static func repair(_ input: TriangleMesh) -> (mesh: TriangleMesh, report: Report) {
        var report = Report()
        // Weld coincident vertices (scans often split them along texture seams).
        var soup: [(Vec3, Vec3, Vec3)] = []
        soup.reserveCapacity(input.triangleCount)
        for t in 0..<input.triangleCount {
            soup.append((input.vertices[Int(input.indices[t * 3])], input.vertices[Int(input.indices[t * 3 + 1])], input.vertices[Int(input.indices[t * 3 + 2])]))
        }
        var mesh = TriangleMesh(soup: soup)

        // Keep the largest connected piece (background bits and floating specks go).
        let (kept, dropped) = largestComponent(mesh)
        mesh = kept
        report.removedFragments = dropped

        // Close holes with a fan around the centre of each rim.
        let (closed, holes) = capHoles(mesh)
        mesh = closed
        report.closedHoles = holes

        // Outward winding: a negative volume means inside out.
        if signedVolume(mesh) < 0 {
            for i in stride(from: 0, to: mesh.indices.count, by: 3) { mesh.indices.swapAt(i + 1, i + 2) }
            report.flipped = true
        }
        report.openEdgesLeft = openEdgeCount(mesh)
        return (mesh, report)
    }

    static func signedVolume(_ mesh: TriangleMesh) -> Double {
        var v = 0.0
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.vertices[Int(mesh.indices[i])], b = mesh.vertices[Int(mesh.indices[i + 1])], c = mesh.vertices[Int(mesh.indices[i + 2])]
            v += a.dot(b.cross(c)) / 6
        }
        return v
    }

    static func largestComponent(_ mesh: TriangleMesh) -> (TriangleMesh, Int) {
        guard mesh.triangleCount > 0 else { return (mesh, 0) }
        var parent = Array(0..<mesh.vertices.count)
        func find(_ x: Int) -> Int { var r = x; while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }; return r }
        for t in 0..<mesh.triangleCount {
            let a = find(Int(mesh.indices[t * 3]))
            for k in 1..<3 { let b = find(Int(mesh.indices[t * 3 + k])); if a != b { parent[b] = a } }
        }
        // The main body is the piece with the largest surface (not the most triangles: a speck can be as finely meshed).
        var count: [Int: Double] = [:]
        for t in 0..<mesh.triangleCount {
            let a = mesh.vertices[Int(mesh.indices[t * 3])], b = mesh.vertices[Int(mesh.indices[t * 3 + 1])], c = mesh.vertices[Int(mesh.indices[t * 3 + 2])]
            count[find(Int(mesh.indices[t * 3])), default: 0] += (b - a).cross(c - a).length / 2
        }
        guard let main = count.max(by: { $0.value < $1.value })?.key, count.count > 1 else { return (mesh, 0) }
        var indices: [UInt32] = []
        for t in 0..<mesh.triangleCount where find(Int(mesh.indices[t * 3])) == main {
            indices += [mesh.indices[t * 3], mesh.indices[t * 3 + 1], mesh.indices[t * 3 + 2]]
        }
        return (TriangleMesh(vertices: mesh.vertices, indices: indices), count.count - 1)
    }

    static func capHoles(_ mesh: TriangleMesh) -> (TriangleMesh, Int) {
        var directed: [UInt64: (UInt32, UInt32)] = [:]
        for t in 0..<mesh.triangleCount { for e in 0..<3 {
            let a = mesh.indices[t * 3 + e], b = mesh.indices[t * 3 + (e + 1) % 3]
            directed[key(a, b)] = (a, b)
        } }
        // Rim edges: no triangle uses them in the opposite direction. The cap runs against the existing direction.
        var next: [UInt32: [UInt32]] = [:]
        for (_, (a, b)) in directed where directed[key(b, a)] == nil { next[b, default: []].append(a) }
        var result = mesh
        var holes = 0
        var used = Set<UInt64>()
        for start in next.keys.sorted() {
            while let first = next[start]?.last, !used.contains(key(start, first)) {
                var loop = [start]
                var current = start
                var guardCount = 0
                while guardCount < 100_000 {
                    guard let step = next[current]?.last(where: { !used.contains(key(current, $0)) }) else { break }
                    used.insert(key(current, step))
                    guardCount += 1
                    if step == start { break }
                    loop.append(step)
                    current = step
                }
                if loop.count >= 3 {
                    var centre = Vec3.zero
                    for i in loop { centre = centre + mesh.vertices[Int(i)] }
                    centre = centre * (1.0 / Double(loop.count))
                    let c = UInt32(result.vertices.count)
                    result.vertices.append(centre)
                    for i in 0..<loop.count { result.indices += [loop[i], loop[(i + 1) % loop.count], c] }
                    holes += 1
                }
                if next[start]?.allSatisfy({ used.contains(key(start, $0)) }) ?? true { break }
            }
        }
        return (result, holes)
    }
}
