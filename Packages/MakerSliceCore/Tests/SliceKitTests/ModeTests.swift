import Foundation
@testable import SliceKit
import XCTest

/// Vase mode, fuzzy skin, seams, wall order, surface patterns, elephant foot and the help texts.
final class ModeTests: XCTestCase {
    private func centered(_ mesh: TriangleMesh, settings: PrintSettings) -> [ModelObject] {
        PlateArranger.arrange([ModelObject(name: "Teil", mesh: mesh, tool: 0)], bedSize: settings.bedSize)!
    }

    func testSpiralVaseRisesContinuously() throws {
        var s = PrintSettings(printer: .snapmakerU1)
        s.spiralVase = true
        s.bottomLayers = 3
        let mesh = MeshCutter.cylinder(center: (0, 0), radius: 20, z0: 0, z1: 10, segments: 48)
        let out = try SliceJob(name: "vase", objects: centered(mesh, settings: s), settings: s).run()
        let spiral = out.layers.filter(\.isSpiral)
        XCTAssertFalse(spiral.isEmpty)
        XCTAssertEqual(out.layers.prefix(3).filter(\.isSpiral).count, 0, "bottom layers are solid")
        for layer in spiral {
            let roles = layer.islands.flatMap { $0.extrusions.map(\.role) }
            XCTAssertEqual(roles, [.outerWall], "only a single wall per spiral layer")
        }
        // Inside the spiral part Z must never go down and change in tiny steps on extrusion moves.
        let lines = out.gcode.split(separator: "\n")
        guard let firstSpiral = lines.firstIndex(where: { $0.hasPrefix(";Z:\(fmt(spiral[0].z))") }) else {
            return XCTFail("spiral layer marker missing")
        }
        var lastZ = 0.0, zExtrusions = 0
        for line in lines[firstSpiral...] {
            if line.hasPrefix("PRINT_END") || line.hasPrefix("G1 E-") { continue }
            guard line.hasPrefix("G1 "), let zr = line.range(of: " Z") else { continue }
            let value = Double(line[zr.upperBound...].prefix { $0 != " " })!
            XCTAssertGreaterThanOrEqual(value, lastZ - 1e-6, "Z went down: \(line)")
            if line.contains(" E") { zExtrusions += 1 }
            lastZ = value
        }
        XCTAssertGreaterThan(zExtrusions, spiral.count * 20, "Z should ramp along the wall")
        XCTAssertEqual(lastZ, out.layers.last!.z, accuracy: 0.001)
    }

    func testFuzzySkinRoughensOuterWallOnly() throws {
        var s = PrintSettings(printer: .snapmakerU1)
        let objects = centered(Fixtures.box(20, 20, 3), settings: s)
        let plain = try Slicer(settings: s).slice(objects)
        s.fuzzySkin = true
        let fuzzy = try Slicer(settings: s).slice(objects)
        func outer(_ l: SlicedLayer) -> Extrusion { l.islands[0].extrusions.first { $0.role == .outerWall }! }
        XCTAssertEqual(outer(plain[0]).points.count, outer(fuzzy[0]).points.count, "first layer stays smooth")
        let p = outer(plain[5]), f = outer(fuzzy[5])
        XCTAssertGreaterThan(f.points.count, 80, "about one point per 0.8 mm on an 80 mm loop")
        XCTAssertGreaterThan(p.points.count, 3)
        // Points stay within the thickness of the original outline.
        let box = Polygons([p.points]).boundingBox!
        for pt in f.points {
            XCTAssertTrue(pt.mmX > box.min.mmX - 0.2 && pt.mmX < box.max.mmX + 0.2)
            XCTAssertTrue(pt.mmY > box.min.mmY - 0.2 && pt.mmY < box.max.mmY + 0.2)
        }
        // Deterministic: same input, same G-code.
        XCTAssertEqual(outer(try Slicer(settings: s).slice(objects)[5]).points, f.points)
    }

    func testSeamPositions() {
        let s = PrintSettings(printer: .snapmakerU1)
        let gen = LayerToolpathGenerator(settings: s, layerIndex: 3, z: 1, height: 0.2)
        // An L-shaped loop: rear edge at y=20, one concave corner.
        let l: Path = [IntPoint(mmX: 0, mmY: 0), IntPoint(mmX: 20, mmY: 0), IntPoint(mmX: 20, mmY: 10),
                       IntPoint(mmX: 10, mmY: 10), IntPoint(mmX: 10, mmY: 20), IntPoint(mmX: 0, mmY: 20)]
        let aligned = gen.seamOrdered(l, loop: 0, position: .aligned)
        XCTAssertEqual(aligned[0].mmY, 20, accuracy: 0.001)
        let corner = gen.seamOrdered(l, loop: 0, position: .corner)
        XCTAssertEqual(Set(corner), Set(l))
        XCTAssertEqual(corner[0].mmY, 20, accuracy: 0.001, "rear corner wins ties")
        let random1 = gen.seamOrdered(l, loop: 0, position: .random)
        let random2 = LayerToolpathGenerator(settings: s, layerIndex: 4, z: 1.2, height: 0.2)
            .seamOrdered(l, loop: 0, position: .random)
        XCTAssertEqual(Set(random1), Set(l))
        XCTAssertEqual(random1.count, l.count)
        _ = random2
    }

    func testWallOrder() throws {
        var s = PrintSettings(printer: .snapmakerU1)
        let objects = centered(Fixtures.box(20, 20, 2), settings: s)
        s.wallOrder = .innerOuter
        let io = try Slicer(settings: s).slice(objects)[3].islands[0].extrusions.map(\.role)
        XCTAssertEqual(io.prefix(2), [.innerWall, .outerWall])
        s.wallOrder = .outerInner
        let oi = try Slicer(settings: s).slice(objects)[3].islands[0].extrusions.map(\.role)
        XCTAssertEqual(oi.prefix(2), [.outerWall, .innerWall])
        XCTAssertEqual(PrintSettings(printer: .kobraS1).wallOrder, .outerInner)
    }

    func testSurfacePatterns() throws {
        var s = PrintSettings(printer: .snapmakerU1)
        let objects = centered(Fixtures.box(30, 30, 2), settings: s)
        s.topSurfacePattern = .concentric
        let layers = try Slicer(settings: s).slice(objects)
        let top = layers.last!.islands[0].extrusions.filter { $0.role == .topSurface }
        XCTAssertFalse(top.isEmpty)
        XCTAssertTrue(top.allSatisfy(\.closed), "concentric rings are closed loops")

        // Monotonic: lines progress in one direction across the surface.
        let gen = LayerToolpathGenerator(settings: s, layerIndex: 2, z: 0.65, height: 0.2)
        let square = Polygons.rectangle(minX: 0, minY: 0, maxX: 20, maxY: 20)
        let lines = gen.lines(in: square, angle: 0, spacing: 0.45, phase: 0, monotonic: true)
        let ys = lines.map { $0[0].mmY }
        XCTAssertEqual(ys, ys.sorted())
        XCTAssertGreaterThan(lines.count, 40)
    }

    func testElephantFootShrinksFirstLayerOnly() throws {
        var s = PrintSettings(printer: .snapmakerU1)
        let objects = centered(Fixtures.box(20, 20, 2), settings: s)
        func outerWidth(_ layer: SlicedLayer) -> Double {
            let wall = layer.islands[0].extrusions.first { $0.role == .outerWall }!
            let box = Polygons([wall.points]).boundingBox!
            return box.max.mmX - box.min.mmX
        }
        s.elephantFootCompensation = 0
        let base = try Slicer(settings: s).slice(objects)
        s.elephantFootCompensation = 0.2
        let comp = try Slicer(settings: s).slice(objects)
        XCTAssertEqual(outerWidth(base[0]) - outerWidth(comp[0]), 0.4, accuracy: 0.02)
        XCTAssertEqual(outerWidth(base[3]), outerWidth(comp[3]), accuracy: 0.001)
    }

    func testEverySettingIsExplained() {
        for key in SettingKey.allCases {
            let help = key.help
            XCTAssertFalse(help.title.isEmpty, "\(key)")
            XCTAssertGreaterThan(help.summary.count, 15, "\(key)")
            XCTAssertTrue(help.increase != nil || help.tip != nil || help.decrease != nil, "\(key) needs an effect or tip")
        }
    }

    func testMaterialAdvice() {
        var s = PrintSettings(printer: .kobraS1)
        var tpu = FilamentLibrary.bestMatch(type: "TPU", printer: .kobraS1)!
        tpu.retractLength = 2
        s.filaments[0] = tpu
        let object = ModelObject(name: "Teil", mesh: Fixtures.box(20, 20, 10), tool: 0)
        let recs = PrintAdvisor.recommendations(objects: [object], settings: s, dryerHumidity: 55)
        let ids = Set(recs.map(\.id))
        XCTAssertTrue(ids.contains("kobra-tpu"))
        XCTAssertTrue(ids.contains("tpu-retract-0"))
        XCTAssertTrue(ids.contains("ace-humid"))
        var objects = [object]
        let retract = recs.first { $0.id == "tpu-retract-0" }!
        XCTAssertNoThrow(try PrintAdvisor.apply(retract.action!, settings: &s, objects: &objects))
        XCTAssertEqual(s.filaments[0].retractLength, 0.8)

        var u1 = PrintSettings(printer: .snapmakerU1)
        u1.filaments[0] = FilamentLibrary.bestMatch(type: "PETG", printer: .snapmakerU1)!
        u1.elephantFootCompensation = 0.1
        let u1IDs = Set(PrintAdvisor.recommendations(objects: [object], settings: u1).map(\.id))
        XCTAssertTrue(u1IDs.isSuperset(of: ["petg-tips", "petg-foot", "dry"]))
        XCTAssertFalse(u1IDs.contains("kobra-wiper"))

        u1.spiralVase = true
        let two = [object, ModelObject(name: "B", mesh: Fixtures.box(10, 10, 10), tool: 1)]
        XCTAssertTrue(PrintAdvisor.recommendations(objects: two, settings: u1).contains { $0.id == "vase-multi" })
    }
}
