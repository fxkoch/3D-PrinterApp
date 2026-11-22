import XCTest
@testable import SliceKit

/// Fixes from the code review of November 2026 (problems seen on the U1).
final class ReviewFixTests: XCTestCase {
    /// The speed steps of the max-flow test (M220 up to 433 %) as they were kept as defaults by older versions.
    private func leftoverSettings() -> PrintSettings {
        var s = PrintSettings()
        s.layerGCodes = [LayerGCode(z: 0, lines: ["M220 S100"]), LayerGCode(z: 28, lines: ["M220 S400"]),
                         LayerGCode(z: 31, lines: ["M220 S433", "M104 S240"])]
        s.footerGCode = ["M220 S100"]
        s.retractLengthSteps = [HeightValue(z: 8, value: 0.4)]
        s.spiralVase = true
        return s
    }

    func testOnePrintOnlyValuesAreNotKeptAsDefaults() {
        let s = leftoverSettings()
        XCTAssertTrue(s.hasProjectOnlyValues)
        let defaults = s.forNewProjects
        XCTAssertFalse(defaults.hasProjectOnlyValues)
        XCTAssertTrue(defaults.layerGCodes.isEmpty)
        XCTAssertTrue(defaults.footerGCode.isEmpty)
        XCTAssertTrue(defaults.retractLengthSteps.isEmpty)
        XCTAssertFalse(defaults.spiralVase)
        // Everything else stays.
        var expected = s
        expected.layerGCodes = []; expected.footerGCode = []; expected.retractLengthSteps = []; expected.spiralVase = false
        XCTAssertEqual(defaults, expected)
    }

    func testAdvisorWarnsAboutSpeedStepsAndRemovesThem() throws {
        var s = leftoverSettings()
        s.spiralVase = false
        var objects = [ModelObject(name: "Würfel", mesh: Fixtures.box(20, 20, 40))]
        let recs = PrintAdvisor.recommendations(objects: objects, settings: s)
        let tip = try XCTUnwrap(recs.first { $0.id == "leftover-commands" })
        XCTAssertEqual(tip.severity, .warning)
        XCTAssertTrue(tip.detail.contains("M220 S400 ab 28 mm"), tip.detail)
        XCTAssertEqual(tip.action, .removeLeftoverCommands)

        try PrintAdvisor.apply(.removeLeftoverCommands, settings: &s, objects: &objects)
        XCTAssertTrue(s.factorCommands.isEmpty)
        XCTAssertTrue(s.footerGCode.isEmpty)
        XCTAssertTrue(s.retractLengthSteps.isEmpty)
        // A temperature step of the project stays.
        XCTAssertEqual(s.layerGCodes, [LayerGCode(z: 31, lines: ["M104 S240"])])
        XCTAssertFalse(PrintAdvisor.recommendations(objects: objects, settings: s).contains { $0.id == "leftover-commands" })
    }

    func testNoLeftoverTipForANormalPrint() {
        let objects = [ModelObject(name: "Würfel", mesh: Fixtures.box(20, 20, 20))]
        var s = PrintSettings()
        s.layerGCodes = [LayerGCode(z: 5, lines: ["M104 S230"])] // temperature tower of a downloaded project
        XCTAssertFalse(PrintAdvisor.recommendations(objects: objects, settings: s).contains { $0.id == "leftover-commands" })
    }

    func testU1UsesTheNormalTemperaturesFromTheSecondLayer() throws {
        var s = PrintSettings()
        s.filaments[0].nozzleTemp = 250
        s.filaments[0].firstLayerNozzleTemp = 245
        s.filaments[0].bedTemp = 70
        s.filaments[0].firstLayerBedTemp = 75
        s.plateType = .texturedPEI
        let cube = ModelObject(name: "Cube", mesh: Fixtures.box(10, 10, 2))
        let arranged = try XCTUnwrap(PlateArranger.arrange([cube], bedSize: s.bedSize))
        let gcode = try SliceJob(name: "cube", objects: arranged, settings: s).run().gcode
        XCTAssertTrue(gcode.contains("M109 S245"), "first layer at the first-layer temperature")
        let second = try XCTUnwrap(gcode.range(of: "CURRENT_LAYER=2\n"))
        let after = gcode[second.upperBound...]
        XCTAssertTrue(after.hasPrefix("M104 T0 S250\nM140 S70\n"), String(after.prefix(80)))
        XCTAssertEqual(String(after).components(separatedBy: "M104 T0 S250").count, 2, "only once in the layers")
    }

    func testU1KeepsTemperaturesWhenTheyAreTheSame() throws {
        var s = PrintSettings()
        s.filaments[0].nozzleTemp = 220
        s.filaments[0].firstLayerNozzleTemp = 220
        s.filaments[0].bedTemp = 60
        s.filaments[0].firstLayerBedTemp = 60
        let cube = ModelObject(name: "Cube", mesh: Fixtures.box(10, 10, 2))
        let arranged = try XCTUnwrap(PlateArranger.arrange([cube], bedSize: s.bedSize))
        let gcode = try SliceJob(name: "cube", objects: arranged, settings: s).run().gcode
        let second = try XCTUnwrap(gcode.range(of: "CURRENT_LAYER=2\n"))
        XCTAssertFalse(gcode[second.upperBound...].hasPrefix("M104"))
        XCTAssertFalse(gcode[second.upperBound...].hasPrefix("M140"))
    }

    // MARK: Overhangs

    /// Square frustum: `bottom` wide at z = 0, `top` wide at `height` (wider top = overhang all around).
    private func frustum(bottom: Double, top: Double, height: Double) -> TriangleMesh {
        let b = (top - bottom) / 2 // the top square sticks out by this much on every side
        let o = max(0, b)
        let v = [Vec3(o, o, 0), Vec3(o + bottom, o, 0), Vec3(o + bottom, o + bottom, 0), Vec3(o, o + bottom, 0),
                 Vec3(o - b, o - b, height), Vec3(o - b + top, o - b, height), Vec3(o - b + top, o - b + top, height), Vec3(o - b, o - b + top, height)]
        let i: [UInt32] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7]
        return TriangleMesh(vertices: v, indices: i)
    }

    private func roles(_ mesh: TriangleMesh, _ configure: (inout PrintSettings) -> Void = { _ in }) throws -> (roles: [ExtrusionRole], gcode: String, layers: [SlicedLayer]) {
        var s = PrintSettings()
        s.skirtLoops = 0
        configure(&s)
        let arranged = try XCTUnwrap(PlateArranger.arrange([ModelObject(name: "Teil", mesh: mesh)], bedSize: s.bedSize))
        let output = try SliceJob(name: "teil", objects: arranged, settings: s).run()
        return (output.layers.flatMap { $0.islands.flatMap { $0.extrusions.map(\.role) } }, output.gcode, output.layers)
    }

    func testStraightWallsHaveNoOverhangs() throws {
        XCTAssertFalse(try roles(Fixtures.box(20, 20, 10)).roles.contains(.overhangWall))
        // 30° from vertical: each layer sticks out 0.12 mm, the wall still stands on the layer below.
        XCTAssertFalse(try roles(frustum(bottom: 20, top: 20 + 2 * 10 * tan(30 * .pi / 180), height: 10)).roles.contains(.overhangWall))
    }

    func testSteepOverhangsPrintSlowlyWithFullFan() throws {
        // 60° from vertical: 0.35 mm per layer, more than half the line hangs in the air.
        let mesh = frustum(bottom: 20, top: 20 + 2 * 8 * tan(60 * .pi / 180), height: 8)
        let result = try roles(mesh) { $0.filaments[0] = .petg }
        let overhangs = result.layers.flatMap { $0.islands.flatMap { $0.extrusions } }.filter { $0.role == .overhangWall }
        XCTAssertFalse(overhangs.isEmpty)
        XCTAssertTrue(overhangs.allSatisfy { $0.speed <= 30 })
        XCTAssertTrue(result.gcode.contains(";TYPE:Overhang wall"))
        // Full cooling on the overhang (PETG cools with 40 %, overhangs with 100 %).
        let afterType = try XCTUnwrap(result.gcode.range(of: ";TYPE:Overhang wall\n"))
        XCTAssertTrue(result.gcode[afterType.upperBound...].prefix(200).contains("M106 S255"))

        let off = try roles(mesh) { $0.slowDownOverhangs = false }
        XCTAssertFalse(off.roles.contains(.overhangWall))
    }

    func testOverhangSplitKeepsTheLoopClosedAndInOrder() {
        // A 20 mm square wall; the right half (x > 10) hangs in the air.
        let gen = LayerToolpathGenerator(settings: PrintSettings(), layerIndex: 5, z: 1.25, height: 0.2)
        let square: Path = [IntPoint(mmX: 0, mmY: 0), IntPoint(mmX: 20, mmY: 0), IntPoint(mmX: 20, mmY: 20), IntPoint(mmX: 0, mmY: 20)]
        let wall = Extrusion(role: .outerWall, points: square, closed: true, width: 0.42, speed: 200)
        let zone = Polygons.rectangle(minX: 10, minY: -5, maxX: 30, maxY: 25)
        let parts = gen.splitOverhangs(wall, zone: zone)
        XCTAssertEqual(parts.map(\.role), [.outerWall, .overhangWall, .outerWall])
        XCTAssertEqual(parts.first?.points.first, square[0], "starts at the seam")
        XCTAssertEqual(parts.last?.points.last, square[0], "ends where it started")
        for (a, b) in zip(parts, parts.dropFirst()) { XCTAssertEqual(a.points.last, b.points.first, "no gap between the runs") }
        XCTAssertEqual(parts[1].speed, 30)
        XCTAssertEqual(parts.reduce(0) { $0 + $1.lengthMM }, 80, accuracy: 0.01)
    }

    // MARK: Supports standing on the model

    func testSupportLeavesAGapAboveTheModelItStandsOn() throws {
        // A base block and a slab floating 5 mm above it: the support under the slab stands on the block.
        let base = Fixtures.box(60, 60, 5), slab = Fixtures.box(40, 40, 2, at: Vec3(10, 10, 10))
        let mesh = TriangleMesh(vertices: base.vertices + slab.vertices,
                                indices: base.indices + slab.indices.map { $0 + UInt32(base.vertices.count) })
        func supportLayers(bottom: Double) throws -> [Int] {
            try roles(mesh) { $0.support = .everywhere; $0.supportBottomZDistance = bottom }.layers
                .filter { $0.islands.contains { $0.extrusions.contains { $0.role == .support || $0.role == .supportInterface } } }
                .map(\.index)
        }
        // Layer 24 (top 5.05 mm) is the block's last layer.
        let touching = try supportLayers(bottom: 0)
        XCTAssertEqual(touching.first, 25, "0 mm: the support starts right on the block")
        let gap = try supportLayers(bottom: 0.2)
        XCTAssertEqual(gap.first, 26, "0.2 mm: one layer of air between block and support")
    }

    // MARK: Calibration on the head that holds the filament

    func testCalibrationPrintsWithTheChosenSlot() throws {
        var base = PrintSettings()
        base.filaments = [.pla, .pla, .petg, .pla]
        let plan = CalibrationFactory.plan(.temperature, filament: .petg, base: base, tool: 2)
        XCTAssertEqual(plan.tool, 2)
        XCTAssertEqual(plan.object.tool, 2)
        XCTAssertEqual(plan.filament.type, "PETG")
        XCTAssertEqual(plan.filament.nozzleTemp, Int(plan.steps[0].value), "the tower's first step is set in the slot that prints")
        XCTAssertEqual(plan.settings.filaments[0], base.filaments[0], "slot 0 keeps its own filament")
        let arranged = try XCTUnwrap(PlateArranger.arrange([plan.object], bedSize: plan.settings.bedSize))
        let output = try SliceJob(name: "turm", objects: arranged, settings: plan.settings).run()
        XCTAssertEqual(output.layers.first?.islands.map(\.tool), [2])
        XCTAssertTrue(output.gcode.contains("SM_PRINT_PREEXTRUDE_FILAMENT INDEX=2"), "the U1 primes head 3")
        XCTAssertFalse(output.gcode.contains("\nT0\n"))
        // Slot 0 stays the default.
        XCTAssertEqual(CalibrationFactory.plan(.flow, filament: .petg, base: base).tool, 0)
    }

    /// PETG part with PLA supports from another slot: the brim must be PETG, or it does not hold the part.
    func testBrimIsPrintedInThePartsMaterial() throws {
        var s = PrintSettings()
        s.filaments[0] = .pla
        s.filaments[1] = .petg
        s.support = .buildPlateOnly
        s.supportSlot = 0
        s.brimWidth = 5
        s.skirtLoops = 0
        let t = ModelObject(name: "T", mesh: Fixtures.tShape(), tool: 1)
        let arranged = try XCTUnwrap(PlateArranger.arrange([t], bedSize: s.bedSize))
        let output = try SliceJob(name: "t", objects: arranged, settings: s).run()
        let first = try XCTUnwrap(output.layers.first)
        XCTAssertEqual(first.islands.first?.tool, 1, "the layer starts with the part and its brim")
        let brimTools = Set(first.islands.filter { $0.extrusions.contains { $0.role == .brim } }.map(\.tool))
        XCTAssertEqual(brimTools, [1])
        XCTAssertTrue(first.islands.contains { $0.tool == 0 && $0.extrusions.contains { $0.role == .support } },
                      "the support still stands in its own slot")
    }
}

final class BedEdgeTests: XCTestCase {
    /// A part almost as long as the bed: its skirt (and brim) must not leave the bed – the U1 stopped with "move out of
    /// range" at Y −0.5 on the first layer of a headphone stand base.
    func testSkirtAndBrimStayOnTheBed() throws {
        for brim in [0.0, 8.0] {
            var s = PrintSettings()
            s.skirtLoops = 2
            s.brimWidth = brim
            let part = ModelObject(name: "Lang", mesh: Fixtures.box(40, 266, 5, at: Vec3(100, 2, 0)))
            let output = try SliceJob(name: "lang", objects: [part], settings: s).run()
            var minY = Double.infinity, maxY = -Double.infinity, minX = Double.infinity, maxX = -Double.infinity
            for line in output.gcode.split(separator: "\n") where line.hasPrefix("G1 ") || line.hasPrefix("G0 ") {
                for token in line.split(separator: " ") {
                    if token.hasPrefix("Y"), let v = Double(token.dropFirst()) { minY = min(minY, v); maxY = max(maxY, v) }
                    if token.hasPrefix("X"), let v = Double(token.dropFirst()) { minX = min(minX, v); maxX = max(maxX, v) }
                }
            }
            XCTAssertGreaterThanOrEqual(minY, 0, "brim \(brim)")
            XCTAssertLessThanOrEqual(maxY, s.bedSize, "brim \(brim)")
            XCTAssertGreaterThanOrEqual(minX, 0)
            let roles = Set(output.layers[0].islands.flatMap { $0.extrusions.map(\.role) })
            XCTAssertTrue(roles.contains(.skirt), "the skirt is cut, not dropped")
        }
    }
}
