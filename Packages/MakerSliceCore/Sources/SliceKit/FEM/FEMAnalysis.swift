import Foundation

/// How the part is printed: decides how stiff and strong the inside is.
public struct FEMPrintSetup: Sendable, Equatable {
    /// Thickness of the walls around the part (wall loops × line width), mm.
    public var wallThickness: Double
    public var topThickness: Double
    public var bottomThickness: Double
    /// Fill of the inside, 0…1.
    public var infillDensity: Double

    public init(wallThickness: Double, topThickness: Double, bottomThickness: Double, infillDensity: Double) {
        self.wallThickness = wallThickness
        self.topThickness = topThickness
        self.bottomThickness = bottomThickness
        self.infillDensity = infillDensity
    }

    public init(_ s: PrintSettings) {
        self.init(wallThickness: Double(s.wallLoops) * s.lineWidth, topThickness: Double(s.topLayers) * s.layerHeight,
                  bottomThickness: Double(s.bottomLayers) * s.layerHeight, infillDensity: s.infillDensity)
    }

    /// Stiffness of the infill relative to solid material (lattices lose stiffness a bit faster than their density).
    var infillStiffnessScale: Double { pow(max(infillDensity, 0.02), 1.3) }
    var infillStrengthScale: Double { pow(max(infillDensity, 0.02), 1.2) }
}

public struct FEMOptions: Sendable {
    /// About how many cubes the model is made of.
    public var targetElements = 40_000
    public var tolerance = 1e-5
    public init(targetElements: Int = 40_000, tolerance: Double = 1e-5) {
        self.targetElements = targetElements
        self.tolerance = tolerance
    }
    public static let fast = FEMOptions(targetElements: 20_000)
    public static let accurate = FEMOptions(targetElements: 90_000, tolerance: 1e-6)
}

/// Result of a strength estimate.
public struct FEMResult: Sendable {
    /// How many times the load could be raised before the part fails in the weakest place (short term).
    public var safetyFactor: Double
    /// Safety against permanent load (creep): short-term factor times the material's long-term share.
    public var safetyFactorLongTerm: Double
    /// Highest "failure index" in the part (1 = at the strength limit), ignoring the cubes right at supports and loads.
    public var peakFailureIndex: Double
    /// Largest displacement in mm.
    public var maxDisplacement: Double
    /// Force per displacement at the load, N/mm (how stiff the part feels).
    public var stiffness: Double
    /// Weight of the printed part in g.
    public var massGrams: Double
    /// Share of the failure index caused by forces across the layers (0…1): high means layer adhesion limits the part.
    public var layerShare: Double
    /// Where the weakest place is (model coordinates).
    public var weakestPoint: Vec3
    public var warnings: [String]
    public var iterations: Int
    public var converged: Bool
    public var elementSize: Double
    public var elementCount: Int

    // Fields for the picture.
    let grid: VoxelGrid
    /// Failure index per cube (0 = empty), index like the grid.
    let failure: [Float]
    /// Stress per solid cube: σx, σy, σz, τxy, τyz, τzx (MPa), same order as `solidIndex`.
    let stress: [Float]
    let solidIndex: [Int32]

    /// Failure index at a point of the model (nil outside the part).
    public func failureIndex(at p: Vec3) -> Double? {
        guard let (i, j, k) = grid.voxel(containing: p) else { return nil }
        let value = failure[grid.index(i, j, k)]
        return value > 0 ? Double(value) : nil
    }

    /// Stress components (σx, σy, σz, τxy, τyz, τzx in MPa) in the cube around a point.
    public func stress(at p: Vec3) -> [Double]? {
        guard let (i, j, k) = grid.voxel(containing: p) else { return nil }
        let e = Int(solidIndex[grid.index(i, j, k)])
        guard e >= 0 else { return nil }
        return (0..<6).map { Double(stress[e * 6 + $0]) }
    }

    /// Failure index for a surface point, looked up just below the surface (nil if nothing is there).
    public func surfaceFailureIndex(at p: Vec3, normal n: Vec3) -> Double? {
        for depth in [0.6, 1.2, 2.0] {
            if let v = failureIndex(at: p - n * (grid.h * depth)) { return v }
        }
        return nil
    }
}

public enum FEMAnalysis {
    /// Runs the estimate: voxelize, build the stiffness, solve, evaluate the failure index.
    @_optimize(speed)
    public static func run(mesh: TriangleMesh, material: FEMMaterial, setup: FEMPrintSetup, loadCase: FEMLoadCase,
                           options: FEMOptions = FEMOptions(), progress: (String, Double) -> Void = { _, _ in },
                           isCancelled: () -> Bool = { false }) throws -> FEMResult {
        guard !loadCase.fixed.isEmpty else { throw FEMError.noFixedSupport }
        guard !loadCase.loads.isEmpty else { throw FEMError.noLoad }

        progress("Modell in Würfel zerlegen", 0)
        var grid = try VoxelGrid.make(mesh: mesh, targetElements: options.targetElements, isCancelled: isCancelled)
        let (nx, ny, nz, h) = (grid.nx, grid.ny, grid.nz, grid.h)

        // Walls, top/bottom skin and infill: how far a cube is from the surface along each axis.
        progress("Wände und Füllung bestimmen", 0.1)
        let lateral = max(1, Int((setup.wallThickness / h).rounded(.up)))
        let topN = max(1, Int((setup.topThickness / h).rounded(.up))), bottomN = max(1, Int((setup.bottomThickness / h).rounded(.up)))
        var kind = [UInt8](repeating: 0, count: nx * ny * nz)   // 0 empty, 1 shell, 2 infill
        func run(_ i: Int, _ j: Int, _ k: Int, _ di: Int, _ dj: Int, _ dk: Int, limit: Int) -> Int {
            var steps = 1
            var (a, b, c) = (i + di, j + dj, k + dk)
            while steps <= limit, grid.isSolid(a, b, c) { a += di; b += dj; c += dk; steps += 1 }
            return steps
        }
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx where grid.solid[grid.index(i, j, k)] {
            let side = min(run(i, j, k, 1, 0, 0, limit: lateral), run(i, j, k, -1, 0, 0, limit: lateral),
                           run(i, j, k, 0, 1, 0, limit: lateral), run(i, j, k, 0, -1, 0, limit: lateral))
            let up = run(i, j, k, 0, 0, 1, limit: topN), down = run(i, j, k, 0, 0, -1, limit: bottomN)
            kind[grid.index(i, j, k)] = (side <= lateral || up <= topN || down <= bottomN) ? 1 : 2
        } } }
        if isCancelled() { throw FEMError.cancelled }

        // Which cubes are attached to the supports (everything else would just float).
        progress("Verbindungen prüfen", 0.2)
        let nodeX = nx + 1, nodeY = ny + 1
        func nodeIndex(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * nodeY + j) * nodeX + i }
        func corner(_ i: Int, _ j: Int, _ k: Int, _ c: Int) -> Int {
            let s = HexElement.nodeSigns[c]
            return nodeIndex(i + (s.0 > 0 ? 1 : 0), j + (s.1 > 0 ? 1 : 0), k + (s.2 > 0 ? 1 : 0))
        }
        let nodeTotal = nodeX * nodeY * (nz + 1)
        func regionNodes(_ region: SurfaceRegion, _ what: String) throws -> Set<Int> {
            var found = Set<Int>()
            let n = region.normal
            let axis = abs(n.x) >= abs(n.y) && abs(n.x) >= abs(n.z) ? 0 : (abs(n.y) >= abs(n.z) ? 1 : 2)
            let sign = [n.x, n.y, n.z][axis] >= 0 ? 1.0 : -1.0
            for t in region.triangles where t.count == 3 {
                let area = (t[1] - t[0]).cross(t[2] - t[0]).length / 2
                let samples = max(1, Int((area / (h * h * 0.25)).squareRoot().rounded(.up)))
                for a in 0...samples { for b in 0...(samples - a) {
                    let u = Double(a) / Double(samples), v = Double(b) / Double(samples)
                    let p = t[0] * (1 - u - v) + t[1] * u + t[2] * v
                    // A point just inside the surface, then the face of that cube that looks out.
                    var dir = Vec3.zero
                    switch axis { case 0: dir = Vec3(sign, 0, 0); case 1: dir = Vec3(0, sign, 0); default: dir = Vec3(0, 0, sign) }
                    guard let (i, j, k) = grid.voxel(containing: p - dir * (h * 0.3)), kind[grid.index(i, j, k)] != 0 else { continue }
                    for c in 0..<8 {
                        let s = HexElement.nodeSigns[c]
                        let on = axis == 0 ? s.0 : (axis == 1 ? s.1 : s.2)
                        if on * sign > 0 { found.insert(corner(i, j, k, c)) }
                    }
                } }
            }
            guard !found.isEmpty else { throw FEMError.regionNotFound(region.name) }
            return found
        }
        let fixedNodes = try loadCase.fixed.enumerated().reduce(into: Set<Int>()) { $0.formUnion(try regionNodes($1.element, "Befestigung \($1.offset + 1)")) }
        var loadNodeSets: [(Set<Int>, Vec3)] = []
        for (n, load) in loadCase.loads.enumerated() { loadNodeSets.append((try regionNodes(load.region, "Last \(n + 1)"), load.force)) }

        // Union-find over nodes: keep the cubes connected to the fixed nodes.
        var parent = Array(0..<nodeTotal)
        func find(_ x: Int) -> Int { var r = x; while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }; return r }
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx where kind[grid.index(i, j, k)] != 0 {
            let root = find(corner(i, j, k, 0))
            for c in 1..<8 { let r = find(corner(i, j, k, c)); if r != root { parent[r] = root } }
        } } }
        guard let anyFixed = fixedNodes.first(where: { _ in true }) else { throw FEMError.noFixedSupport }
        let supportRoots = Set(fixedNodes.map(find))
        _ = anyFixed
        var dropped = 0
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx where kind[grid.index(i, j, k)] != 0 {
            if !supportRoots.contains(find(corner(i, j, k, 0))) { kind[grid.index(i, j, k)] = 0; grid.solid[grid.index(i, j, k)] = false; dropped += 1 }
        } } }
        for (nodes, _) in loadNodeSets where !nodes.contains(where: { supportRoots.contains(find($0)) }) { throw FEMError.notConnected }

        // Elements and compact node numbers.
        var elementOfVoxel = [Int32](repeating: -1, count: nx * ny * nz)
        var elementVoxels: [(Int, Int, Int)] = []
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx where kind[grid.index(i, j, k)] != 0 {
            elementOfVoxel[grid.index(i, j, k)] = Int32(elementVoxels.count)
            elementVoxels.append((i, j, k))
        } } }
        let elementCount = elementVoxels.count
        guard elementCount > 0 else { throw FEMError.emptyModel }
        var compact = [Int32](repeating: -1, count: nodeTotal)
        var nodeCount = 0
        var elementNodes = [Int32](repeating: 0, count: elementCount * 8)
        var scale = [Double](repeating: 1, count: elementCount)
        var strengthScale = [Double](repeating: 1, count: elementCount)
        var groupLists = [[Int32]](repeating: [], count: 8)
        for (e, (i, j, k)) in elementVoxels.enumerated() {
            for c in 0..<8 {
                let n = corner(i, j, k, c)
                if compact[n] < 0 { compact[n] = Int32(nodeCount); nodeCount += 1 }
                elementNodes[e * 8 + c] = compact[n]
            }
            if kind[grid.index(i, j, k)] == 2 { scale[e] = setup.infillStiffnessScale; strengthScale[e] = setup.infillStrengthScale }
            groupLists[(i & 1) | (j & 1) << 1 | (k & 1) << 2].append(Int32(e))
        }

        progress("Steifigkeit aufbauen", 0.3)
        let d = HexElement.constitutive(exy: material.modulusXY, ez: material.modulusZ, nu: material.poisson)
        guard let element = HexElement(h: h, d: d) else { throw FEMError.emptyModel }
        let system = FEMSystem(nodeCount: nodeCount, nodes: elementNodes, scale: scale, ke: element.ke, groups: groupLists.filter { !$0.isEmpty })
        for n in fixedNodes where compact[n] >= 0 { for c in 0..<3 { system.fixed[Int(compact[n]) * 3 + c] = true } }
        var force = [Double](repeating: 0, count: system.dofCount)
        var loadedCompact = Set<Int>()
        for (nodes, f) in loadNodeSets {
            let live = nodes.filter { compact[$0] >= 0 && !system.fixed[Int(compact[$0]) * 3] }
            guard !live.isEmpty else { throw FEMError.notConnected }
            for n in live {
                let c = Int(compact[n])
                force[c * 3] += f.x / Double(live.count); force[c * 3 + 1] += f.y / Double(live.count); force[c * 3 + 2] += f.z / Double(live.count)
                loadedCompact.insert(c)
            }
        }

        progress("Gleichungssystem lösen", 0.4)
        let solution = try system.solve(force: force, tolerance: options.tolerance, progress: { progress("Gleichungssystem lösen", 0.4 + 0.45 * $0) }, isCancelled: isCancelled)

        // Stress and failure index per cube.
        progress("Spannungen auswerten", 0.9)
        let x0 = material.strengthXY, z0 = material.strengthZ
        var failure = [Float](repeating: 0, count: nx * ny * nz)
        var stressStore = [Float](repeating: 0, count: elementCount * 6)
        var elementFI = [Double](repeating: 0, count: elementCount)
        var worst = (fi: 0.0, element: 0, layerShare: 0.0)
        var touchesBoundary = [Bool](repeating: false, count: elementCount)
        var ue = [Double](repeating: 0, count: 24)
        for e in 0..<elementCount {
            for a in 0..<8 {
                let n = Int(elementNodes[e * 8 + a])
                ue[a * 3] = solution.displacement[n * 3]; ue[a * 3 + 1] = solution.displacement[n * 3 + 1]; ue[a * 3 + 2] = solution.displacement[n * 3 + 2]
                if system.fixed[n * 3] || loadedCompact.contains(n) { touchesBoundary[e] = true }
            }
            let xs = x0 * strengthScale[e], zs = z0 * strengthScale[e]
            var best = 0.0, bestShare = 0.0
            var mean = [Double](repeating: 0, count: 6)
            for p in 0..<8 {
                var eps = [Double](repeating: 0, count: 6)
                let m = element.strainAtGauss[p]
                for r in 0..<6 { var sum = 0.0; for c in 0..<24 { sum += m[r * 24 + c] * ue[c] }; eps[r] = sum }
                var sigma = [Double](repeating: 0, count: 6)
                for r in 0..<6 { var sum = 0.0; for c in 0..<6 { sum += element.d[r * 6 + c] * eps[c] }; sigma[r] = sum * scale[e] }
                for r in 0..<6 { mean[r] += sigma[r] / 8 }
                let (sx, sy, sz, txy, tyz, tzx) = (sigma[0], sigma[1], sigma[2], sigma[3], sigma[4], sigma[5])
                let inPlane = (sx * sx - sx * sy + sy * sy + 3 * txy * txy) / (xs * xs)
                let across = (max(sz, 0) * max(sz, 0) + 3 * (tyz * tyz + tzx * tzx)) / (zs * zs)
                let fi = (inPlane + across).squareRoot()
                if fi > best { best = fi; bestShare = (inPlane + across) > 0 ? across / (inPlane + across) : 0 }
            }
            elementFI[e] = best
            let (i, j, k) = elementVoxels[e]
            failure[grid.index(i, j, k)] = Float(best)
            for r in 0..<6 { stressStore[e * 6 + r] = Float(mean[r]) }
            if !touchesBoundary[e], best > worst.fi { worst = (best, e, bestShare) }
        }
        // Peak over the part, without the cubes right at supports/loads (idealised supports create artificial spikes).
        var reported = (0..<elementCount).filter { !touchesBoundary[$0] }.map { elementFI[$0] }
        if reported.count < 20 { reported = elementFI; worst = (elementFI.max() ?? 0, elementFI.firstIndex(of: elementFI.max() ?? 0) ?? 0, worst.layerShare) }
        reported.sort()
        let p99 = reported.isEmpty ? 0 : reported[min(reported.count - 1, Int(Double(reported.count) * 0.995))]
        let peak = max(p99, 1e-9)
        let safety = min(99, 1 / peak)

        // Displacement and stiffness at the load.
        var maxDisp = 0.0
        for n in 0..<nodeCount {
            let u = (solution.displacement[n * 3] * solution.displacement[n * 3] + solution.displacement[n * 3 + 1] * solution.displacement[n * 3 + 1]
                + solution.displacement[n * 3 + 2] * solution.displacement[n * 3 + 2]).squareRoot()
            maxDisp = max(maxDisp, u)
        }
        let totalForce = loadNodeSets.reduce(Vec3.zero) { $0 + $1.1 }
        var work = 0.0
        for c in loadedCompact { for r in 0..<3 { work += force[c * 3 + r] * solution.displacement[c * 3 + r] } }
        let stiffness = work > 1e-12 ? totalForce.dot(totalForce) / work : 0

        var mass = 0.0
        for e in 0..<elementCount { mass += h * h * h * (scale[e] == 1 ? 1 : setup.infillDensity) }
        mass *= material.density / 1000   // mm³ · g/cm³ → g

        var warnings: [String] = []
        if material.isFlexible { warnings.append(material.note ?? "Flexibles Material: nur grobe Näherung.") }
        else if let note = material.note, !note.isEmpty { warnings.append(note) }
        if dropped > 0 { warnings.append("Einzelne Teile des Modells hängen nicht an der Befestigung und wurden nicht mitgerechnet.") }
        if !solution.converged { warnings.append("Das Gleichungssystem ist nicht vollständig konvergiert (Rest \(String(format: "%.1e", solution.residual))) – Ergebnis ungenau.") }
        if h > setup.wallThickness * 1.5 { warnings.append(String(format: "Die Wände (%.1f mm) sind dünner als die Rasterweite (%.1f mm): Ergebnis nur grob. Mit „Genau“ rechnen.", setup.wallThickness, h)) }
        if dropped == 0, reported.count < 200 { warnings.append("Sehr kleines Teil: wenige Rechenelemente, Ergebnis nur grob.") }

        let wv = elementVoxels[worst.element]
        let weakest = Vec3(grid.origin.x + (Double(wv.0) + 0.5) * h, grid.origin.y + (Double(wv.1) + 0.5) * h, grid.origin.z + (Double(wv.2) + 0.5) * h)
        progress("Fertig", 1)
        return FEMResult(safetyFactor: safety, safetyFactorLongTerm: safety * material.longTermFactor, peakFailureIndex: peak,
                         maxDisplacement: maxDisp, stiffness: stiffness, massGrams: mass, layerShare: worst.layerShare, weakestPoint: weakest,
                         warnings: warnings, iterations: solution.iterations, converged: solution.converged, elementSize: h,
                         elementCount: elementCount, grid: grid, failure: failure, stress: stressStore, solidIndex: elementOfVoxel)
    }
}
