import Foundation

/// Finds the orientation of a too-big object that needs the fewest pieces to fit the printer –
/// often turning it (diagonally on the bed, or onto its side) avoids cutting altogether.
enum BestOrientation {
    struct Candidate {
        var transform: Transform3D
        var pieces: Int
        var height: Double
        var turned: Bool
    }

    /// Number of pieces an object of this size needs.
    static func pieces(size: Vec3, limitXY: Double, limitZ: Double) -> Int {
        func n(_ s: Double, _ limit: Double) -> Int { max(1, Int((s / limit - 1e-9).rounded(.up))) }
        return n(size.x, limitXY) * n(size.y, limitXY) * n(size.z, limitZ)
    }

    /// 2D convex hull (monotone chain).
    static func hull(_ points: [(Double, Double)]) -> [(Double, Double)] {
        let p = points.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        guard p.count > 2 else { return p }
        func cross(_ o: (Double, Double), _ a: (Double, Double), _ b: (Double, Double)) -> Double {
            (a.0 - o.0) * (b.1 - o.1) - (a.1 - o.1) * (b.0 - o.0)
        }
        var lower: [(Double, Double)] = []
        for q in p {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        var upper: [(Double, Double)] = []
        for q in p.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// The best orientation, or nil when turning does not reduce the number of pieces.
    static func best(for object: ModelObject, bedSize: Double, maxHeight: Double, limitXY: Double, limitZ: Double) -> Transform3D? {
        let vertices = ([object.mesh] + object.volumes.filter { $0.kind == .add }.map(\.mesh)).flatMap(\.vertices)
        guard !vertices.isEmpty else { return nil }
        let center = object.boundingBox.center
        let toOrigin = Transform3D.translation(Vec3(-center.x, -center.y, -center.z))

        let flips: [Transform3D] = [.identity, .rotationX(.pi / 2), .rotationY(.pi / 2)]
        var best: Candidate?
        var original: Int?
        for (flipIndex, flip) in flips.enumerated() {
            let base = toOrigin.then(flip)
            let moved = vertices.map { base.apply($0) }
            let zMin = moved.map(\.z).min() ?? 0, zMax = moved.map(\.z).max() ?? 0
            let hullPoints = hull(moved.map { ($0.x, $0.y) })
            for step in 0..<18 {
                let angle = Double(step) * 5 * .pi / 180
                let c = cos(angle), s = sin(angle)
                var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
                for (x, y) in hullPoints {
                    let rx = x * c - y * s, ry = x * s + y * c
                    minX = min(minX, rx); maxX = max(maxX, rx); minY = min(minY, ry); maxY = max(maxY, ry)
                }
                let size = Vec3(maxX - minX, maxY - minY, zMax - zMin)
                let candidate = Candidate(transform: base.then(.rotationZ(angle)), pieces: pieces(size: size, limitXY: limitXY, limitZ: limitZ),
                                          height: size.z, turned: flipIndex != 0 || step != 0)
                if flipIndex == 0 && step == 0 { original = candidate.pieces }
                if let b = best {
                    if candidate.pieces < b.pieces || (candidate.pieces == b.pieces && candidate.height < b.height - 1e-6) { best = candidate }
                } else {
                    best = candidate
                }
            }
        }
        guard let best, let original, best.pieces < original, best.turned else { return nil }
        return best.transform
    }
}
