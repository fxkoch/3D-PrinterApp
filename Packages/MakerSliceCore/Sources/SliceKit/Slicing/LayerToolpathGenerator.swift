import Foundation

/// Generates walls and infill for one tool's region within one layer.
struct LayerToolpathGenerator {
    let settings: PrintSettings
    let layerIndex: Int
    let z: Double
    let height: Double

    private var isFirstLayer: Bool { layerIndex == 0 }

    /// Minimum area (mm²) for an island to be worth printing.
    private let minArea = 0.05

    func generate(region: Polygons, above: (Int) -> Polygons?, below: (Int) -> Polygons?) -> [Extrusion] {
        let s = settings
        let outerW = isFirstLayer ? s.firstLayerLineWidth : s.outerWallLineWidth
        let innerW = isFirstLayer ? s.firstLayerLineWidth : s.lineWidth
        var walls: [[Extrusion]] = []

        // Walls: successive insets. Each inset is printed as closed loops.
        var current = region.offset(-outerW / 2)
        var lastInset = current
        var lastWidth = outerW
        for loop in 0..<max(1, s.wallLoops) {
            guard !current.isEmpty else { break }
            let role: ExtrusionRole = loop == 0 ? .outerWall : .innerWall
            let width = loop == 0 ? outerW : innerW
            let speed = isFirstLayer ? s.firstLayerSpeed : (loop == 0 ? s.outerWallSpeed : s.innerWallSpeed)
            walls.append(current.paths.filter { abs(Polygons.signedArea($0)) / 1e6 > minArea }.map {
                Extrusion(role: role, points: seamOrdered($0), closed: true, width: width, speed: speed)
            })
            lastInset = current
            lastWidth = width
            if loop + 1 < s.wallLoops {
                current = current.offset(-(width / 2 + innerW / 2))
            }
        }

        // Area left for infill, overlapping the innermost wall slightly.
        let infillArea = lastInset.offset(-(lastWidth / 2) + s.infillOverlap * innerW)
            .offset(-0.05).offset(0.05) // drop slivers
        var extrusions: [Extrusion] = []
        // Inner walls first, outer wall last: better surface finish and accuracy.
        for wall in walls.reversed() { extrusions.append(contentsOf: wall) }
        guard !infillArea.isEmpty else { return extrusions }

        // Solid surfaces: anything not covered by enough layers above/below.
        let top = uncovered(infillArea, layers: s.topLayers, neighbor: above)
        let bottom = uncovered(infillArea, layers: s.bottomLayers, neighbor: below)
        // Only the very top layer is a visible "top surface".
        let visibleTop = s.topLayers > 0 ? infillArea.difference(above(1) ?? Polygons()) : Polygons()
        let solid = (top + bottom).union()
        let sparse = infillArea.difference(solid.offset(innerW * 0.5)).offset(-0.01)

        let solidAngle = layerIndex % 2 == 0 ? 45.0 : 135.0
        if !solid.isEmpty {
            let topPart = visibleTop.intersection(solid)
            var internalSolid = solid.difference(topPart)

            // Bridges: solid areas hanging over air (not the first layer).
            if s.detectBridges, layerIndex > 0, let support = below(1), !internalSolid.isEmpty {
                let bridgeArea = internalSolid.difference(support.offset(0.2)).offset(-0.1).offset(0.1)
                    .filterSmall(minArea: 1.0)
                if !bridgeArea.isEmpty {
                    let anchored = bridgeArea.offset(innerW).intersection(internalSolid.union(bridgeArea))
                    let angle = bestBridgeAngle(bridgeArea, support: support)
                    extrusions.append(contentsOf: lines(in: anchored, angle: angle, spacing: innerW, phase: 0).map {
                        Extrusion(role: .bridge, points: $0, closed: false, width: innerW,
                                  speed: s.bridgeSpeed, flow: s.bridgeFlow)
                    })
                    internalSolid = internalSolid.difference(anchored)
                }
            }
            if !topPart.isEmpty {
                extrusions.append(contentsOf: lines(in: topPart, angle: solidAngle, spacing: innerW, phase: 0).map {
                    Extrusion(role: .topSurface, points: $0, closed: false, width: innerW,
                              speed: isFirstLayer ? s.firstLayerSpeed : s.topSurfaceSpeed)
                })
            }
            if !internalSolid.isEmpty {
                let role: ExtrusionRole = isFirstLayer || below(1) == nil ? .bottomSurface : .solidInfill
                extrusions.append(contentsOf: lines(in: internalSolid, angle: solidAngle, spacing: innerW, phase: 0).map {
                    Extrusion(role: role, points: $0, closed: false, width: innerW,
                              speed: isFirstLayer ? s.firstLayerInfillSpeed : s.solidInfillSpeed)
                })
            }
            // Ironing: a second, nearly flow-less pass that smooths visible tops.
            if s.ironing, !isFirstLayer, !topPart.isEmpty {
                let ironArea = topPart.offset(-innerW / 2)
                extrusions.append(contentsOf: lines(in: ironArea, angle: solidAngle + 90, spacing: s.ironingSpacing, phase: 0).map {
                    Extrusion(role: .ironing, points: $0, closed: false, width: innerW,
                              speed: s.ironingSpeed, flow: s.ironingFlow * s.ironingSpacing / innerW)
                })
            }
        }
        if !sparse.isEmpty, s.infillDensity > 0.001 {
            for path in sparseInfill(sparse, width: innerW) {
                extrusions.append(Extrusion(role: .sparseInfill, points: path, closed: false, width: innerW,
                                            speed: isFirstLayer ? s.firstLayerInfillSpeed : s.infillSpeed))
            }
        }
        return extrusions
    }

    func supportPaths(area: Polygons, interface: Polygons) -> [Extrusion] {
        let s = settings
        let w = isFirstLayer ? s.firstLayerLineWidth : s.lineWidth
        let speed = isFirstLayer ? s.firstLayerSpeed : s.supportSpeed
        var result: [Extrusion] = []
        let base = area.difference(interface)
        if !base.isEmpty {
            // First layer gets denser support for adhesion.
            let spacing = isFirstLayer ? w * 2 : s.supportSpacing
            result += lines(in: base, angle: 0, spacing: spacing, phase: 0).map {
                Extrusion(role: .support, points: $0, closed: false, width: w, speed: speed)
            }
        }
        if !interface.isEmpty {
            result += lines(in: interface, angle: layerIndex % 2 == 0 ? 0 : 90, spacing: w * 1.6, phase: 0).map {
                Extrusion(role: .supportInterface, points: $0, closed: false, width: w, speed: speed * 0.6)
            }
        }
        return result
    }

    // MARK: - Helpers

    /// Part of `area` that is not covered by all of the next `layers` neighbours.
    private func uncovered(_ area: Polygons, layers: Int, neighbor: (Int) -> Polygons?) -> Polygons {
        guard layers > 0 else { return Polygons() }
        var covered: Polygons?
        for k in 1...layers {
            guard let n = neighbor(k), !n.isEmpty else { return area }
            covered = covered.map { $0.intersection(n) } ?? n
            if covered!.isEmpty { return area }
        }
        return area.difference(covered!)
    }

    private func sparseInfill(_ area: Polygons, width: Double) -> [Path] {
        let d = max(settings.infillDensity, 0.01)
        switch settings.infillPattern {
        case .lines:
            return lines(in: area, angle: layerIndex % 2 == 0 ? 45 : 135, spacing: width / d, phase: 0)
        case .grid:
            let spacing = 2 * width / d
            return lines(in: area, angle: 45, spacing: spacing, phase: 0)
                + lines(in: area, angle: 135, spacing: spacing, phase: 0)
        case .triangles:
            let spacing = 3 * width / d
            return [0.0, 60, 120].flatMap { lines(in: area, angle: $0, spacing: spacing, phase: 0) }
        case .cubic:
            // Three line families that shift with Z form tilted cubes.
            let spacing = 3 * width / d
            let shift = z * 0.7071
            return [0.0, 120, 240].flatMap { lines(in: area, angle: $0, spacing: spacing, phase: shift) }
        case .gyroid:
            return gyroid(in: area, spacing: width / d * 1.2)
        }
    }

    /// Gyroid surface sin(x)cos(y) + sin(y)cos(z) + sin(z)cos(x) = 0 cut at this
    /// layer's height. Depending on z we solve for y(x) or x(y), whichever has a
    /// solution everywhere, which yields continuous wavy lines.
    func gyroid(in area: Polygons, spacing: Double) -> [Path] {
        guard let box = area.boundingBox else { return [] }
        let period = 2 * spacing
        let k = 2 * Double.pi / period // mm → radians
        let zr = z * k
        let solveForY = abs(cos(zr)) >= abs(sin(zr))
        let minA = (solveForY ? box.min.mmX : box.min.mmY) - period
        let maxA = (solveForY ? box.max.mmX : box.max.mmY) + period
        let minB = (solveForY ? box.min.mmY : box.min.mmX) - period
        let maxB = (solveForY ? box.max.mmY : box.max.mmX) + period
        let step = period / 24
        let firstRow = Int(floor(minB / period)) - 1
        let lastRow = Int(ceil(maxB / period)) + 1
        var raw: [Path] = []
        for row in firstRow...lastRow {
            for sign in [-1.0, 1.0] {
                var path: Path = []
                var a = minA
                while a <= maxA {
                    let ar = a * k
                    // p·cos(b) + q·sin(b) = d. One of p/q is constant and non-zero for this
                    // layer; using it as the reference keeps the phase continuous.
                    let p: Double, q: Double, d: Double
                    let b: Double
                    if solveForY {
                        p = sin(ar); q = cos(zr); d = -sin(zr) * cos(ar)
                        let psi = atan(p / q)
                        let r = q / cos(psi)
                        let s0 = asin(max(-1, min(1, d / r)))
                        b = (sign > 0 ? s0 - psi : Double.pi - s0 - psi) / k + Double(row) * period
                    } else {
                        p = sin(zr); q = cos(ar); d = -sin(ar) * cos(zr)
                        let phi = atan(q / p)
                        let r = p / cos(phi)
                        b = (phi + sign * acos(max(-1, min(1, d / r)))) / k + Double(row) * period
                    }
                    path.append(solveForY ? IntPoint(mmX: a, mmY: b) : IntPoint(mmX: b, mmY: a))
                    a += step
                }
                if path.count >= 2 { raw.append(path) }
            }
        }
        let clipped = area.clip(lines: raw).filter { path in
            guard let f = path.first, let l = path.last else { return false }
            return path.count > 2 || f.distance(to: l) > 0.3 * Units.perMM
        }
        return Self.nearestNeighborOrder(clipped)
    }

    /// Direction in which bridge lines are anchored on supported material at both
    /// ends (ties: shorter spans win).
    private func bestBridgeAngle(_ area: Polygons, support: Polygons) -> Double {
        let probeArea = area.offset(1.5)
        var best = 0.0, bestScore = -Double.infinity
        for angle in stride(from: 0.0, to: 180.0, by: 15) {
            let probe = lines(in: probeArea, angle: angle, spacing: 1.0, phase: 0)
            guard !probe.isEmpty else { continue }
            var anchored = 0
            var total = 0.0
            for line in probe {
                if support.contains(line[0]) && support.contains(line[line.count - 1]) { anchored += 1 }
                total += line[0].distance(to: line[line.count - 1])
            }
            let score = Double(anchored) / Double(probe.count) - total / Double(probe.count) / 1e7
            if score > bestScore { bestScore = score; best = angle }
        }
        return best
    }

    /// Parallel lines at `angle` (degrees) spaced `spacing` mm apart, clipped to
    /// `area`, ordered to keep travel short. Lines align to a global grid so
    /// consecutive layers stack.
    func lines(in area: Polygons, angle: Double, spacing: Double, phase: Double) -> [Path] {
        guard let box = area.boundingBox, spacing > 0.01 else { return [] }
        let a = angle * .pi / 180
        let dir = (x: cos(a), y: sin(a))
        let normal = (x: -sin(a), y: cos(a))
        let corners = [(box.min.mmX, box.min.mmY), (box.max.mmX, box.min.mmY), (box.min.mmX, box.max.mmY), (box.max.mmX, box.max.mmY)]
        let proj = corners.map { $0.0 * normal.x + $0.1 * normal.y }
        let along = corners.map { $0.0 * dir.x + $0.1 * dir.y }
        guard let pMin = proj.min(), let pMax = proj.max(), let aMin = along.min(), let aMax = along.max() else { return [] }

        var raw: [Path] = []
        var t = (floor((pMin - phase) / spacing)) * spacing + phase
        while t <= pMax {
            let p0 = (x: normal.x * t + dir.x * (aMin - 1), y: normal.y * t + dir.y * (aMin - 1))
            let p1 = (x: normal.x * t + dir.x * (aMax + 1), y: normal.y * t + dir.y * (aMax + 1))
            raw.append([IntPoint(mmX: p0.x, mmY: p0.y), IntPoint(mmX: p1.x, mmY: p1.y)])
            t += spacing
        }
        let clipped = area.clip(lines: raw).filter { path in
            guard let f = path.first, let l = path.last else { return false }
            return f.distance(to: l) > 0.3 * Units.perMM
        }
        return Self.nearestNeighborOrder(clipped)
    }

    /// Greedy ordering that also flips lines to start at the closer end.
    static func nearestNeighborOrder(_ paths: [Path]) -> [Path] {
        guard paths.count > 1 else { return paths }
        var remaining = paths
        var ordered: [Path] = []
        ordered.reserveCapacity(paths.count)
        var position = remaining[0][0]
        while !remaining.isEmpty {
            var best = 0, bestDist = Double.infinity, flip = false
            for (i, p) in remaining.enumerated() {
                let d0 = position.distanceSquared(to: p[0])
                let d1 = position.distanceSquared(to: p[p.count - 1])
                if d0 < bestDist { bestDist = d0; best = i; flip = false }
                if d1 < bestDist { bestDist = d1; best = i; flip = true }
            }
            var next = remaining.remove(at: best)
            if flip { next.reverse() }
            position = next[next.count - 1]
            ordered.append(next)
        }
        return ordered
    }

    /// Rotates a loop so it starts at the rear-most point (aligned seam at the back).
    private func seamOrdered(_ path: Path) -> Path {
        guard let idx = path.indices.max(by: { path[$0].y == path[$1].y ? path[$0].x > path[$1].x : path[$0].y < path[$1].y }) else {
            return path
        }
        return Array(path[idx...] + path[..<idx])
    }
}
