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
