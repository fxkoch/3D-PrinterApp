@testable import SliceKit
import XCTest

final class FEMTests: XCTestCase {
    private let isotropic = FEMMaterial(id: "T", name: "Test", density: 1.2, modulusXY: 3000, modulusZ: 3000, poisson: 0.3, strengthXY: 50,
                                        zStrengthFactor: 1, heatDeflection: 80, longTermFactor: 1)
    private let solid = FEMPrintSetup(wallThickness: 1000, topThickness: 1000, bottomThickness: 1000, infillDensity: 1)

    /// Region of the face of a box lying in the plane axis = value.
    private func face(of mesh: TriangleMesh, axis: Int, value: Double, name: String) -> SurfaceRegion {
        for t in 0..<mesh.triangleCount {
            let v = (0..<3).map { mesh.vertices[Int(mesh.indices[t * 3 + $0])] }
            if v.allSatisfy({ abs([$0.x, $0.y, $0.z][axis] - value) < 1e-6 }) { return SurfaceRegion.grow(from: t, in: mesh, name: name) }
        }
        fatalError("no such face")
    }

    private func beam(length: Double = 100, load: Double = 10, e: Double = 3000, elements: Int = 10_000) throws -> FEMResult {
        let mesh = Fixtures.box(length, 10, 10)
        var m = isotropic
        m.modulusXY = e; m.modulusZ = e
        let lc = FEMLoadCase(fixed: [face(of: mesh, axis: 0, value: 0, name: "Wand")],
                             loads: [.init(region: face(of: mesh, axis: 0, value: length, name: "Last"), force: Vec3(0, 0, -load))])
        let start = Date()
        return try FEMAnalysis.run(mesh: mesh, material: m, setup: solid, loadCase: lc, options: FEMOptions(targetElements: elements),
                                   progress: { phase, f in if ProcessInfo.processInfo.environment["FEM_DEBUG"] != nil { fputs(String(format: "%.1fs  %.2f  %@\n", Date().timeIntervalSince(start), f, phase), stderr) } })
    }

    func testCantileverBeamMatchesBeamTheory() throws {
        // Tip deflection of a cantilever: δ = 4·F·L³ / (E·b·h³) = 1.333 mm for F = 10 N, L = 100, b = h = 10, E = 3000 MPa.
        let result = try beam()
        XCTAssertTrue(result.converged)
        XCTAssertEqual(result.maxDisplacement, 1.333, accuracy: 0.1, "within 7.5 % of beam theory")
        // Bending stress at mid-span, outer cube: σ = M·c/I = (10·50)·4.5/833 = 2.7 MPa.
        let sigma = try XCTUnwrap(result.stress(at: Vec3(50, 5, 9.5)))
        XCTAssertEqual(sigma[0], 2.7, accuracy: 0.45)
        let bottom = try XCTUnwrap(result.stress(at: Vec3(50, 5, 0.5)))
        XCTAssertEqual(bottom[0], -2.7, accuracy: 0.45, "compression on the other side")
        XCTAssertEqual(result.stiffness, 10 / 1.333, accuracy: 1.0, "force per displacement")
    }

    func testStiffnessScalesWithModulusAndLoad() throws {
        let base = try beam(elements: 4000)
        let stiffer = try beam(e: 6000, elements: 4000)
        XCTAssertEqual(base.maxDisplacement / stiffer.maxDisplacement, 2, accuracy: 0.02)
        let heavier = try beam(load: 20, elements: 4000)
        XCTAssertEqual(heavier.maxDisplacement / base.maxDisplacement, 2, accuracy: 0.02)
        XCTAssertEqual(base.safetyFactor / heavier.safetyFactor, 2, accuracy: 0.1, "twice the load halves the safety")
    }

    func testBeamLengthDeflectionLaw() throws {
        // Deflection grows with L³.
        let short = try beam(length: 60, elements: 6000)
        let long = try beam(length: 120, elements: 12000)
        XCTAssertEqual(long.maxDisplacement / short.maxDisplacement, 8, accuracy: 1.0)
    }

    func testTensionBarMatchesAxialFormula() throws {
        // δ = F·L / (E·A) = 100·60 / (3000·100) = 0.02 mm; σ = F/A = 1 MPa.
        let mesh = Fixtures.box(60, 10, 10)
        let lc = FEMLoadCase(fixed: [face(of: mesh, axis: 0, value: 0, name: "Wand")],
                             loads: [.init(region: face(of: mesh, axis: 0, value: 60, name: "Zug"), force: Vec3(100, 0, 0))])
        let r = try FEMAnalysis.run(mesh: mesh, material: isotropic, setup: solid, loadCase: lc, options: FEMOptions(targetElements: 6000))
        XCTAssertEqual(r.maxDisplacement, 0.02, accuracy: 0.003)
        let sigma = try XCTUnwrap(r.stress(at: Vec3(30, 5, 5)))
        XCTAssertEqual(sigma[0], 1.0, accuracy: 0.1)
    }

    func testInfillAndWallsChangeTheResult() throws {
        let mesh = Fixtures.box(60, 20, 20)
        let lc = FEMLoadCase(fixed: [face(of: mesh, axis: 0, value: 0, name: "Wand")],
                             loads: [.init(region: face(of: mesh, axis: 0, value: 60, name: "Last"), force: Vec3(0, 0, -20))])
        func run(walls: Double, infill: Double) throws -> FEMResult {
            try FEMAnalysis.run(mesh: mesh, material: isotropic, setup: FEMPrintSetup(wallThickness: walls, topThickness: walls, bottomThickness: walls, infillDensity: infill),
                                loadCase: lc, options: FEMOptions(targetElements: 6000))
        }
        let thin = try run(walls: 1.2, infill: 0.15)
        let thick = try run(walls: 3.0, infill: 0.15)
        let full = try run(walls: 1.2, infill: 1.0)
        XCTAssertGreaterThan(thick.safetyFactor, thin.safetyFactor, "more walls make the part stronger")
        XCTAssertLessThan(thick.maxDisplacement, thin.maxDisplacement)
        XCTAssertGreaterThan(full.massGrams, thin.massGrams)
        XCTAssertLessThan(full.maxDisplacement, thin.maxDisplacement)
    }

    func testLayersAreTheWeakDirection() throws {
        // Pulling a bar along the layers (X) vs across them (Z): same material, the Z bar fails earlier.
        let weakZ = FEMMaterial.material(id: "ABS")!
        func tension(axis: Int) throws -> Double {
            let size = [20.0, 20.0, 20.0]
            var dims = size; dims[axis] = 60
            let mesh = Fixtures.box(dims[0], dims[1], dims[2])
            var f = Vec3.zero
            switch axis { case 0: f = Vec3(300, 0, 0); case 1: f = Vec3(0, 300, 0); default: f = Vec3(0, 0, 300) }
            let lc = FEMLoadCase(fixed: [face(of: mesh, axis: axis, value: 0, name: "fest")],
                                 loads: [.init(region: face(of: mesh, axis: axis, value: 60, name: "Zug"), force: f)])
            return try FEMAnalysis.run(mesh: mesh, material: weakZ, setup: solid, loadCase: lc, options: FEMOptions(targetElements: 5000)).safetyFactor
        }
        let along = try tension(axis: 0), across = try tension(axis: 2)
        XCTAssertEqual(along / across, 1 / weakZ.zStrengthFactor, accuracy: 0.35, "safety drops by the layer-adhesion factor")
    }

    func testDisconnectedLoadIsReported() {
        // Two separate boxes: the load sits on the one that is not attached.
        var mesh = Fixtures.box(20, 20, 20)
        mesh.append(Fixtures.box(20, 20, 20, at: Vec3(50, 0, 0)))
        let lc = FEMLoadCase(fixed: [face(of: mesh, axis: 0, value: 0, name: "fest")],
                             loads: [.init(region: face(of: mesh, axis: 0, value: 70, name: "Last"), force: Vec3(0, 0, -10))])
        XCTAssertThrowsError(try FEMAnalysis.run(mesh: mesh, material: isotropic, setup: solid, loadCase: lc, options: FEMOptions(targetElements: 2000))) {
            XCTAssertEqual($0 as? FEMError, .notConnected)
        }
    }

    func testMaterialCatalogMatchesFilamentTypes() {
        XCTAssertEqual(FEMMaterial.matching(filamentType: "PLA").id, "PLA")
        XCTAssertEqual(FEMMaterial.matching(filamentType: "PETG HF").id, "PETG")
        XCTAssertEqual(FEMMaterial.matching(filamentType: "PA6-CF").id, "PA-CF")
        XCTAssertEqual(FEMMaterial.matching(filamentType: "PLA-CF").id, "PLA-CF")
        XCTAssertEqual(FEMMaterial.matching(filamentType: "TPU").id, "TPU")
        XCTAssertEqual(FEMMaterial.matching(filamentType: "PAHT-CF").id, "PAHT-CF")
        XCTAssertEqual(FEMMaterial.matching(filamentType: "Unbekannt").id, "PLA")
        XCTAssertGreaterThanOrEqual(FEMMaterial.catalog.count, 10)
        for m in FEMMaterial.catalog {
            XCTAssertGreaterThan(m.modulusXY, 0); XCTAssertGreaterThan(m.strengthXY, 0)
            XCTAssertTrue((0.2...1).contains(m.zStrengthFactor), m.id)
            XCTAssertNotNil(HexElement(h: 1, d: HexElement.constitutive(exy: m.modulusXY, ez: m.modulusZ, nu: m.poisson)), "\(m.id) has a valid stiffness")
        }
    }

    func testRigidBodyMotionCreatesNoForces() throws {
        let element = try XCTUnwrap(HexElement(h: 2, d: HexElement.constitutive(exy: 3000, ez: 2500, nu: 0.35)))
        var u = [Double](repeating: 0, count: 24)
        for n in 0..<8 { u[n * 3] = 1.5; u[n * 3 + 1] = -0.7; u[n * 3 + 2] = 0.3 }
        let f = Dense.multiply(element.ke, 24, 24, u, 1)
        XCTAssertLessThan(f.map(abs).max() ?? 1, 1e-6)
        // Uniform stretch in x: strain 0.001 everywhere.
        var s = [Double](repeating: 0, count: 24)
        for (n, sign) in HexElement.nodeSigns.enumerated() { s[n * 3] = 0.001 * 2 * (sign.0 + 1) / 2 }
        for p in 0..<8 {
            var eps = [Double](repeating: 0, count: 6)
            for r in 0..<6 { for c in 0..<24 { eps[r] += element.strainAtGauss[p][r * 24 + c] * s[c] } }
            XCTAssertEqual(eps[0], 0.001, accuracy: 1e-9)
            XCTAssertLessThan(abs(eps[1]) + abs(eps[2]) + abs(eps[3]), 1e-9)
        }
    }

    func testAdvisorFindsStrongerAndLighterVariants() throws {
        let mesh = Fixtures.box(80, 14, 14)
        let pla = try XCTUnwrap(FEMMaterial.matching(filamentType: "PLA"))
        var settings = PrintSettings()
        settings.wallLoops = 2; settings.infillDensity = 0.5
        let lc = FEMLoadCase(fixed: [face(of: mesh, axis: 0, value: 0, name: "Wand")],
                             loads: [.init(region: face(of: mesh, axis: 0, value: 80, name: "Last"), force: Vec3(0, 0, -20))])
        let tips = try FEMAdvisor.suggest(mesh: mesh, material: pla, settings: settings, loadCase: lc, options: FEMOptions(targetElements: 3000))
        let stronger = tips.filter { $0.goal == .stronger }
        XCTAssertFalse(stronger.isEmpty)
        XCTAssertTrue(stronger.allSatisfy { $0.safetyRatio > 1.05 })
        let lighter = try XCTUnwrap(tips.first { $0.goal == .lighter }, "50 % infill can be reduced")
        XCTAssertLessThan(lighter.massRatio, 0.97)
        XCTAssertGreaterThanOrEqual(lighter.safetyRatio, 0.95)
    }

    /// Foot, thin neck and head stacked on each other (no overlaps).
    private func neckPart() -> TriangleMesh {
        var m = Fixtures.box(24, 24, 8)
        m.append(Fixtures.box(6, 6, 14, at: Vec3(9, 9, 8)))
        m.append(Fixtures.box(24, 24, 8, at: Vec3(0, 0, 22)))
        return m
    }

    private func edgeUse(_ mesh: TriangleMesh) -> [UInt64: Int] {
        var use: [UInt64: Int] = [:]
        for t in 0..<mesh.triangleCount { for e in 0..<3 {
            let a = mesh.indices[t * 3 + e], b = mesh.indices[t * 3 + (e + 1) % 3]
            use[UInt64(min(a, b)) << 32 | UInt64(max(a, b)), default: 0] += 1
        } }
        return use
    }

    func testDiscRegionIsRoundPatchWithNormal() {
        let disc = SurfaceRegion.disc(center: Vec3(5, 5, 10), normal: Vec3(0, 0, 1), radius: 3, name: "Last")
        XCTAssertEqual(disc.area, Double.pi * 9, accuracy: 1.5)
        XCTAssertEqual(disc.normal.z, 1, accuracy: 1e-9)
    }

    func testThickeningKeepsMeshClosedAndShiftsLittle() {
        let mesh = Fixtures.box(20, 20, 20)
        let thick = MeshReinforcer.thicken(mesh, spots: [(Vec3(10, 10, 20), 6, 1.0)])
        XCTAssertGreaterThan(thick.triangleCount, mesh.triangleCount)
        XCTAssertTrue(edgeUse(thick).values.allSatisfy { $0 == 2 }, "every edge belongs to exactly two triangles")
        XCTAssertGreaterThan(thick.volume, mesh.volume)
        let box = thick.boundingBox
        XCTAssertLessThan(box.max.z, 21.01)
        XCTAssertGreaterThan(box.max.z, 20.5)
    }

    func testScanFindsTheThinNeck() throws {
        let pla = FEMMaterial.matching(filamentType: "PLA")
        let report = try FEMWeakSpots.scan(mesh: neckPart(), material: pla, setup: FEMPrintSetup(wallThickness: 1.2, topThickness: 1, bottomThickness: 1, infillDensity: 0.2),
                                           options: FEMOptions(targetElements: 6000))
        let first = try XCTUnwrap(report.spots.first)
        XCTAssertGreaterThan(first.location.z, 7.5)
        XCTAssertLessThan(first.location.z, 22.5, "the neck gives way first")
        XCTAssertEqual(first.thickness, 6, accuracy: 2)
        XCTAssertTrue(first.reason.contains("Dünne"))
    }

    func testReinforcementMakesTheNeckStrongerWithSmallShift() throws {
        let pla = FEMMaterial.matching(filamentType: "PLA")
        let setup = FEMPrintSetup(wallThickness: 1.2, topThickness: 1, bottomThickness: 1, infillDensity: 0.2)
        let fix = try XCTUnwrap(SurfaceRegion.bottomFace(of: neckPart()))
        let top = try XCTUnwrap(SurfaceRegion.topFace(of: neckPart()))
        let lc = FEMLoadCase(fixed: [fix], loads: [.init(region: top, force: Vec3(15, 0, 0))])
        let result = try FEMWeakSpots.reinforce(mesh: neckPart(), material: pla, setup: setup, loadCase: lc, options: FEMOptions(targetElements: 6000))
        let r = try XCTUnwrap(result, "a thicker neck must be found")
        XCTAssertGreaterThanOrEqual(r.safetyRatio, 1.05)
        XCTAssertLessThanOrEqual(r.maxShift, 1.5)
        XCTAssertGreaterThan(r.massRatio, 1, "material is added")
        XCTAssertLessThan(r.massRatio, 1.5)
    }
}
