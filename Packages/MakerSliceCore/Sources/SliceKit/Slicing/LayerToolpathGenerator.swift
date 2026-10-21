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

    /// Spiral-vase layers print only one rising outer wall.
    var isSpiral: Bool { settings.spiralVase && layerIndex >= settings.bottomLayers }

    func generate(region rawRegion: Polygons, above: (Int) -> Polygons?, below: (Int) -> Polygons?) -> [Extrusion] {
        let s = settings
        let outerW = isFirstLayer ? s.firstLayerLineWidth : s.outerWallLineWidth
        let innerW = isFirstLayer ? s.firstLayerLineWidth : s.lineWidth
        // Elephant foot: the squished first layer bulges out, so pull it in a little.
        let region = isFirstLayer && s.elephantFootCompensation > 0
            ? rawRegion.offset(-s.elephantFootCompensation) : rawRegion
        var walls: [[Extrusion]] = []

        if isSpiral {
            // Only the largest outline, as one loop starting at the back so layers join up.
            let outline = region.offset(-outerW / 2)
            guard let largest = outline.paths.max(by: { abs(Polygons.signedArea($0)) < abs(Polygons.signedArea($1)) }) else { return [] }
            var points = seamOrdered(largest, loop: 0, position: .aligned)
            if s.fuzzySkin { points = fuzzed(points) }
            return [Extrusion(role: .outerWall, points: points, closed: true, width: outerW, speed: s.outerWallSpeed)]
        }

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
                var points = seamOrdered($0, loop: loop, position: s.seamPosition)
                if loop == 0, s.fuzzySkin, !isFirstLayer { points = fuzzed(points) }
                return Extrusion(role: role, points: points, closed: true, width: width, speed: speed)
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
        // Inner → outer gives the cleanest surface; outer → inner the most accurate dimensions and overhangs.
        for wall in (s.wallOrder == .innerOuter ? walls.reversed() : walls) { extrusions.append(contentsOf: wall) }
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
                extrusions.append(contentsOf: surface(topPart, pattern: s.topSurfacePattern, angle: solidAngle, width: innerW).map {
                    Extrusion(role: .topSurface, points: $0.points, closed: $0.closed, width: innerW,
                              speed: isFirstLayer ? s.firstLayerSpeed : s.topSurfaceSpeed)
                })
            }
            if !internalSolid.isEmpty {
                let isBottom = isFirstLayer || below(1) == nil
                let role: ExtrusionRole = isBottom ? .bottomSurface : .solidInfill
                let pattern: SurfacePattern = isBottom ? s.bottomSurfacePattern : .lines
                extrusions.append(contentsOf: surface(internalSolid, pattern: pattern, angle: solidAngle, width: innerW).map {
                    Extrusion(role: role, points: $0.points, closed: $0.closed, width: innerW,
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
    func lines(in area: Polygons, angle: Double, spacing: Double, phase: Double, monotonic: Bool = false) -> [Path] {
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
        if monotonic { return Self.monotonicOrder(clipped, normal: normal) }
        return Self.nearestNeighborOrder(clipped)
    }

    /// Lines strictly side by side in one sweep (no jumping back), alternating direction.
    /// Gives evenly blended, streak-free top surfaces.
    static func monotonicOrder(_ paths: [Path], normal: (x: Double, y: Double)) -> [Path] {
        func key(_ p: Path) -> Double {
            let m = (x: Double(p[0].x + p[p.count - 1].x) / 2, y: Double(p[0].y + p[p.count - 1].y) / 2)
            return m.x * normal.x + m.y * normal.y
        }
        var ordered = paths.sorted { key($0) < key($1) }
        guard !ordered.isEmpty else { return ordered }
        for i in 1..<ordered.count {
            let end = ordered[i - 1][ordered[i - 1].count - 1]
            if end.distanceSquared(to: ordered[i][ordered[i].count - 1]) < end.distanceSquared(to: ordered[i][0]) {
                ordered[i].reverse()
            }
        }
        return ordered
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

    /// Fills a solid surface with the chosen pattern.
    func surface(_ area: Polygons, pattern: SurfacePattern, angle: Double, width: Double) -> [(points: Path, closed: Bool)] {
        switch pattern {
        case .lines:
            return lines(in: area, angle: angle, spacing: width, phase: 0).map { ($0, false) }
        case .monotonic:
            return lines(in: area, angle: angle, spacing: width, phase: 0, monotonic: true).map { ($0, false) }
        case .concentric:
            // Rings following the outline, outside in.
            var rings: [(Path, Bool)] = []
            var ring = area.offset(-width / 2)
            var guardCount = 0
            while !ring.isEmpty, guardCount < 2000 {
                for path in ring.paths where abs(Polygons.signedArea(path)) / 1e6 > minArea {
                    rings.append((path, true))
                }
                ring = ring.offset(-width)
                guardCount += 1
            }
            return rings
        }
    }

    /// Rotates a loop so it starts at the seam.
    func seamOrdered(_ path: Path, loop: Int, position: SeamPosition) -> Path {
        guard path.count > 2 else { return path }
        let idx: Int
        switch position {
        case .aligned:
            // Rear-most point, so seams line up into one straight line at the back.
            idx = path.indices.max(by: { path[$0].y == path[$1].y ? path[$0].x > path[$1].x : path[$0].y < path[$1].y })!
        case .corner:
            // The sharpest corner hides the seam best; fall back to the rear if the loop is round.
            let n = path.count
            var best = -1, bestTurn = 0.35 // ≈ 20°
            for i in 0..<n {
                let a = path[(i + n - 1) % n], b = path[i], c = path[(i + 1) % n]
                let v1 = (x: Double(b.x - a.x), y: Double(b.y - a.y)), v2 = (x: Double(c.x - b.x), y: Double(c.y - b.y))
                let l1 = (v1.x * v1.x + v1.y * v1.y).squareRoot(), l2 = (v2.x * v2.x + v2.y * v2.y).squareRoot()
                guard l1 > 0, l2 > 0 else { continue }
                let turn = abs(atan2(v1.x * v2.y - v1.y * v2.x, v1.x * v2.x + v1.y * v2.y))
                // Prefer rear corners on ties so seams still group together.
                if turn > bestTurn + 0.01 || (abs(turn - bestTurn) <= 0.01 && best >= 0 && b.y > path[best].y) {
                    bestTurn = turn
                    best = i
                }
            }
            idx = best >= 0 ? best : seamIndexRear(path)
        case .random:
            var rng = SplitMix(seed: UInt64(layerIndex &* 7919 &+ loop &* 104_729) &+ UInt64(truncatingIfNeeded: path[0].x))
            idx = Int(rng.next() % UInt64(path.count))
        }
        return Array(path[idx...] + path[..<idx])
    }

    private func seamIndexRear(_ path: Path) -> Int {
        path.indices.max(by: { path[$0].y == path[$1].y ? path[$0].x > path[$1].x : path[$0].y < path[$1].y }) ?? 0
    }

    /// Fuzzy skin: resample the loop and push each point randomly in or out.
    func fuzzed(_ path: Path) -> Path {
        let s = settings
        guard path.count > 2, s.fuzzySkinThickness > 0 else { return path }
        let step = max(s.fuzzySkinPointDistance, 0.1) * Units.perMM
        let amp = s.fuzzySkinThickness * Units.perMM
        var rng = SplitMix(seed: UInt64(layerIndex &* 31 &+ 17) &+ UInt64(truncatingIfNeeded: path[0].y))
        var result: Path = []
        let n = path.count
        for i in 0..<n {
            let a = path[i], b = path[(i + 1) % n]
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > 0 else { continue }
            // Outward normal for counter-clockwise loops; holes run clockwise so it flips correctly.
            let nx = dy / len, ny = -dx / len
            let count = max(1, Int(len / step))
            for k in 0..<count {
                let t = Double(k) / Double(count)
                let r = (Double(rng.next() % 10_000) / 10_000 - 0.5) * amp
                result.append(IntPoint(a.x + Int64(dx * t + nx * r), a.y + Int64(dy * t + ny * r)))
            }
        }
        return result.count > 2 ? result : path
    }
}

/// Small deterministic random generator (same G-code for the same input).
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
