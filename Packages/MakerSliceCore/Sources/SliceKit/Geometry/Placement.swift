import Foundation

/// A face the model can be laid on, with what that means for the print.
public struct LyingFace: Identifiable, Sendable {
    public var id: Int
    /// Outward normal of the face; laid on it, this normal points down.
    public var normal: Vec3
    /// Area that touches the bed (mm²): only the faces in the lowest plane, not every face pointing the same way.
    public var contactArea: Double
    /// Height of the model lying on this face (mm).
    public var height: Double
    /// Area hanging over air steeper than the support angle (mm²) – needs supports.
    public var overhangArea: Double
    /// Rotation that puts the face onto the bed.
    public var rotation: Transform3D
}

extension TriangleMesh {
    /// The faces the model can lie on, best first: large contact, little overhang. The old "lay flat" took the face
    /// direction with the most area in total – a part with many small faces pointing one way then stood on a corner.
    public func lyingFaces(limit: Int = 6, supportAngle: Double = 30) -> [LyingFace] {
        guard triangleCount > 0 else { return [] }
        struct Face { var normal: Vec3; var area: Double; var a: Vec3; var b: Vec3; var c: Vec3 }
        var faces: [Face] = []
        faces.reserveCapacity(triangleCount)
        var byDirection: [Vec3: (area: Double, normal: Vec3)] = [:]
        for t in 0..<triangleCount {
            let a = vertices[Int(indices[t * 3])], b = vertices[Int(indices[t * 3 + 1])], c = vertices[Int(indices[t * 3 + 2])]
            let cross = (b - a).cross(c - a)
            let area = cross.length / 2
            guard area > 1e-9 else { continue }
            let n = cross.normalized
            faces.append(Face(normal: n, area: area, a: a, b: b, c: c))
            let key = Vec3((n.x * 50).rounded(), (n.y * 50).rounded(), (n.z * 50).rounded())
            let old = byDirection[key] ?? (0, n)
            byDirection[key] = (old.area + area, old.area >= area ? old.normal : n)
        }
        let threshold = cos(max(5, min(85, supportAngle)) * .pi / 180)
        var result: [LyingFace] = []
        for (_, group) in byDirection.sorted(by: { $0.value.area > $1.value.area }).prefix(40) {
            let n = group.normal
            // Laid on this face, the vertices furthest along n touch the bed.
            var top = -Double.infinity, bottom = Double.infinity
            for v in vertices { let d = v.dot(n); top = max(top, d); bottom = min(bottom, d) }
            var contact = 0.0, overhang = 0.0
            let rotation = Transform3D.rotationAligning(n, to: Vec3(0, 0, -1))
            for f in faces {
                let lowest = min(f.a.dot(n), f.b.dot(n), f.c.dot(n))
                let heightAboveBed = top - max(f.a.dot(n), f.b.dot(n), f.c.dot(n))
                if f.normal.dot(n) > 0.999, top - lowest < 0.05 {
                    contact += f.area
                    continue
                }
                // Down-facing after the rotation and above the bed: overhang.
                let down = -rotation.apply(f.normal).z
                if down > threshold, heightAboveBed > 0.3 { overhang += f.area * down }
            }
            guard contact > 1 else { continue }
            result.append(LyingFace(id: result.count, normal: n, contactArea: contact, height: top - bottom,
                                    overhangArea: overhang, rotation: rotation))
        }
        // Best first: plenty of contact, then little overhang (each cm² of overhang costs like 2 cm² of contact).
        let ranked = result.sorted { a, b in
            let sa = min(a.contactArea, 2000) - 2 * a.overhangArea, sb = min(b.contactArea, 2000) - 2 * b.overhangArea
            return sa > sb
        }
        return Array(ranked.prefix(limit)).enumerated().map { i, f in var g = f; g.id = i; return g }
    }
}

extension ModelObject {
    /// The object after `t` (rotation or scale about its own centre), standing on the bed at the same place, pushed back
    /// onto the bed if it would stick out. Other objects stay where they are.
    public func transformedInPlace(_ t: Transform3D, bedSize: Double) -> ModelObject {
        let box = boundingBox
        guard !box.isEmpty else { return self }
        let center = box.center
        let turned = transformed(Transform3D.translation(Vec3(-center.x, -center.y, -center.z)).then(t))
        return turned.placedOnBed(center: (center.x, center.y)).keptOnBed(bedSize: bedSize)
    }

    /// Moved by (dx, dy) mm, but not over the edge of the bed.
    public func moved(dx: Double, dy: Double, bedSize: Double) -> ModelObject {
        transformed(.translation(Vec3(dx, dy, 0))).keptOnBed(bedSize: bedSize)
    }

    /// Shifted inside the bed if it sticks out (an object larger than the bed is centred).
    public func keptOnBed(bedSize: Double) -> ModelObject {
        let box = boundingBox
        guard !box.isEmpty else { return self }
        func shift(_ lo: Double, _ hi: Double) -> Double {
            if hi - lo > bedSize { return bedSize / 2 - (lo + hi) / 2 }
            if lo < 0 { return -lo }
            if hi > bedSize { return bedSize - hi }
            return 0
        }
        let dx = shift(box.min.x, box.max.x), dy = shift(box.min.y, box.max.y)
        guard dx != 0 || dy != 0 || abs(box.min.z) > 1e-9 else { return self }
        return transformed(.translation(Vec3(dx, dy, -box.min.z)))
    }

    /// Outline of the object seen from above (convex hull, mm), for the bed map.
    public func footprintHull(maxPoints: Int = 4000) -> [(x: Double, y: Double)] {
        let all = mesh.vertices + parts.flatMap(\.mesh.vertices)
        guard !all.isEmpty else { return [] }
        let step = max(1, all.count / maxPoints)
        var pts = stride(from: 0, to: all.count, by: step).map { (x: all[$0].x, y: all[$0].y) }
        pts.sort { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ o: (x: Double, y: Double), _ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [(x: Double, y: Double)] = [], upper: [(x: Double, y: Double)] = []
        for p in pts {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in pts.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}
