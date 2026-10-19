import Foundation

/// Cuts a triangle mesh into 2D outlines at given Z heights.
public enum MeshSlicer {
    /// Returns one `Polygons` per entry in `heights`.
    public static func slice(_ mesh: TriangleMesh, at heights: [Double]) -> [Polygons] {
        guard !mesh.isEmpty, !heights.isEmpty else { return heights.map { _ in Polygons() } }

        // Bucket triangles by the layers they span so every layer only looks at
        // relevant triangles. `heights` is ascending.
        var buckets = [[Int32]](repeating: [], count: heights.count)
        for t in 0..<mesh.triangleCount {
            let a = mesh.vertices[Int(mesh.indices[t * 3])].z
            let b = mesh.vertices[Int(mesh.indices[t * 3 + 1])].z
            let c = mesh.vertices[Int(mesh.indices[t * 3 + 2])].z
            let lo = min(a, b, c), hi = max(a, b, c)
            guard hi > lo else { continue } // horizontal faces never cross a slicing plane
            var first = lowerBound(heights, lo)
            while first < heights.count, heights[first] <= hi {
                buckets[first].append(Int32(t))
                first += 1
            }
        }

        var result = [Polygons](repeating: Polygons(), count: heights.count)
        result.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: heights.count) { layer in
                out[layer] = sliceLayer(mesh, triangles: buckets[layer], z: heights[layer])
            }
        }
        return result
    }

    private static func lowerBound(_ values: [Double], _ x: Double) -> Int {
        var lo = 0, hi = values.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if values[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private struct Segment {
        var a: IntPoint
        var b: IntPoint
    }

    static func sliceLayer(_ mesh: TriangleMesh, triangles: [Int32], z: Double) -> Polygons {
        var segments: [Segment] = []
        segments.reserveCapacity(triangles.count)

        for t32 in triangles {
            let t = Int(t32)
            var p = [
                mesh.vertices[Int(mesh.indices[t * 3])],
                mesh.vertices[Int(mesh.indices[t * 3 + 1])],
                mesh.vertices[Int(mesh.indices[t * 3 + 2])],
            ]
            // Nudge vertices lying exactly on the plane upwards to avoid degenerate cases.
            for i in 0..<3 where p[i].z == z { p[i].z += 1e-7 }

            var points: [IntPoint] = []
            for (i, j) in [(0, 1), (1, 2), (2, 0)] {
                let (u, v) = order(p[i], p[j])
                if (u.z < z) != (v.z < z) {
                    let f = (z - u.z) / (v.z - u.z)
                    points.append(IntPoint(mmX: u.x + (v.x - u.x) * f, mmY: u.y + (v.y - u.y) * f))
                }
            }
            guard points.count == 2, points[0] != points[1] else { continue }

            // Orient so the outward face normal lies to the right of travel,
            // making outer loops counter-clockwise.
            let n = (p[1] - p[0]).cross(p[2] - p[0])
            let dx = Double(points[1].x - points[0].x), dy = Double(points[1].y - points[0].y)
            if dy * n.x - dx * n.y >= 0 {
                segments.append(Segment(a: points[0], b: points[1]))
            } else {
                segments.append(Segment(a: points[1], b: points[0]))
            }
        }
        return Polygons(chain(segments)).resolvedEvenOdd()
    }

    /// Orders an edge's endpoints deterministically so shared edges of
    /// non-welded meshes produce identical intersection points.
    private static func order(_ a: Vec3, _ b: Vec3) -> (Vec3, Vec3) {
        if a.z != b.z { return a.z < b.z ? (a, b) : (b, a) }
        if a.x != b.x { return a.x < b.x ? (a, b) : (b, a) }
        return a.y <= b.y ? (a, b) : (b, a)
    }

    /// Joins segments end-to-start into closed loops.
    private static func chain(_ segments: [Segment]) -> [Path] {
        guard !segments.isEmpty else { return [] }
        var byStart: [IntPoint: [Int]] = [:]
        var byEnd: [IntPoint: [Int]] = [:]
        byStart.reserveCapacity(segments.count)
        for (i, s) in segments.enumerated() {
            byStart[s.a, default: []].append(i)
            byEnd[s.b, default: []].append(i)
        }
        var used = [Bool](repeating: false, count: segments.count)
        var loops: [Path] = []
        var open: [Path] = []

        func take(from key: IntPoint, in map: [IntPoint: [Int]]) -> Int? {
            map[key]?.first { !used[$0] }
        }

        for start in segments.indices where !used[start] {
            used[start] = true
            var path: Path = [segments[start].a, segments[start].b]
            let origin = segments[start].a
            var closed = false
            while true {
                let tip = path[path.count - 1]
                if tip == origin { closed = true; path.removeLast(); break }
                if let next = take(from: tip, in: byStart) {
                    used[next] = true
                    path.append(segments[next].b)
                } else if let next = take(from: tip, in: byEnd) {
                    // Inconsistent winding (flipped triangle) – walk it backwards.
                    used[next] = true
                    path.append(segments[next].a)
                } else {
                    break
                }
            }
            if closed {
                if path.count >= 3 { loops.append(path) }
            } else {
                open.append(path)
            }
        }

        // Stitch open chains (holes in non-manifold meshes) by joining closest ends.
        while !open.isEmpty {
            var path = open.removeLast()
            var merged = true
            while merged {
                merged = false
                guard let tip = path.last else { break }
                var best = -1, bestDist = 2_000.0 * 2_000.0 // 2 mm
                for (i, other) in open.enumerated() {
                    let d = tip.distanceSquared(to: other[0])
                    if d < bestDist { bestDist = d; best = i }
                }
                if best >= 0 {
                    path.append(contentsOf: open.remove(at: best))
                    merged = true
                }
            }
            if path.count >= 3, let first = path.first, let last = path.last, first.distance(to: last) < 2_000 {
                loops.append(path)
            }
        }
        return loops
    }
}
