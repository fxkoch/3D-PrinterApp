import XCTest
@testable import SliceKit

final class AutoTuneTests: XCTestCase {
    private func arranged(_ object: ModelObject, _ s: PrintSettings) throws -> [ModelObject] {
        try XCTUnwrap(PlateArranger.arrange([object], bedSize: s.bedSize))
    }

    func testOverhangingModelGetsSupportsAndTheResultIsStable() throws {
        let s = PrintSettings()
        let objects = try arranged(ModelObject(name: "T", mesh: Fixtures.tShape()), s)
        let result = AutoTune.run(objects: objects, settings: s)
        XCTAssertNotEqual(result.settings.support, .off)
        XCTAssertTrue(result.applied.contains { $0.id == "support" })
        XCTAssertEqual(result.original, s)
        // Tuning the tuned settings changes nothing more: no tip pushes another one back.
        let again = AutoTune.run(objects: objects, settings: result.settings)
        XCTAssertFalse(again.changed, again.applied.map(\.id).joined(separator: ", "))
    }

    func testNeverTouchesPlateLevelingOrTheModel() throws {
        var s = PrintSettings()
        s.filaments[0] = .petg
        s.plateType = .highTemp            // PETG on smooth PEI: a warning, but the plate in the printer is a fact
        let objects = [ModelObject(name: "Riesig", mesh: Fixtures.box(300, 20, 10))] // too big for the bed: split tip
        let result = AutoTune.run(objects: objects, settings: s)
        XCTAssertEqual(result.settings.plateType, .highTemp)
        XCTAssertEqual(result.settings.enableBedLeveling, s.enableBedLeveling)
        XCTAssertFalse(result.applied.contains { if case .autoSplit = $0.action { return true } else { return false } })
    }

    func testInfoTipsAreNotTakenOver() throws {
        var s = PrintSettings()
        s.infillDensity = 0.4
        // Big model: "material sparen" is only an info.
        let objects = try arranged(ModelObject(name: "Block", mesh: Fixtures.box(80, 80, 60)), s)
        let result = AutoTune.run(objects: objects, settings: s)
        XCTAssertEqual(result.settings.infillDensity, 0.4)
        XCTAssertTrue(result.applied.allSatisfy { $0.severity >= .suggestion })
    }

    func testAcrossMaterialsAndShapesEveryTipIsTakenAtMostOnce() throws {
        for f in [Filament.pla, .petg, .tpu, .abs] {
            for mesh in [Fixtures.tShape(), Fixtures.box(10, 10, 60), Fixtures.box(60, 60, 4), Fixtures.box(8, 8, 8)] {
                var s = PrintSettings()
                s.filaments[0] = f
                let objects = try arranged(ModelObject(name: "Teil", mesh: mesh), s)
                let result = AutoTune.run(objects: objects, settings: s)
                XCTAssertEqual(Set(result.applied.map(\.id)).count, result.applied.count, "\(f.type)")
                XCTAssertFalse(AutoTune.run(objects: objects, settings: result.settings).changed, "stable for \(f.type)")
            }
        }
    }
}

final class EmptySlotTests: XCTestCase {
    func testEmptyHeadMovesToTheHeadWithTheSameMaterial() throws {
        var s = PrintSettings()
        s.filaments = [.petg, .pla, .petg, .pla]
        let objects = [ModelObject(name: "Zwiebelspender", mesh: Fixtures.box(20, 20, 20), tool: 0)]
        let loaded: [String?] = ["", "PLA", "PETG", nil]
        let tip = try XCTUnwrap(PrintAdvisor.recommendations(objects: objects, settings: s, loadedTypes: loaded).first { $0.id == "empty-0" })
        XCTAssertEqual(tip.action, .useSlot(from: 0, to: 2))
        XCTAssertEqual(tip.severity, .warning)
        let tuned = AutoTune.run(objects: objects, settings: s, loadedTypes: loaded)
        XCTAssertEqual(tuned.objects.first?.tool, 2)
        XCTAssertTrue(tuned.applied.contains { $0.id == "empty-0" })
    }

    func testOtherMaterialIsOnlyOffered() throws {
        var s = PrintSettings()
        s.filaments = [.petg, .pla, .pla, .pla]
        let objects = [ModelObject(name: "Teil", mesh: Fixtures.box(20, 20, 20), tool: 0)]
        let loaded: [String?] = ["", "PLA", nil, nil]
        let tip = try XCTUnwrap(PrintAdvisor.recommendations(objects: objects, settings: s, loadedTypes: loaded).first { $0.id == "empty-0" })
        XCTAssertEqual(tip.severity, .info)
        XCTAssertEqual(tip.action, .useSlot(from: 0, to: 1))
        XCTAssertEqual(AutoTune.run(objects: objects, settings: s, loadedTypes: loaded).objects.first?.tool, 0, "not automatic")
    }

    func testMovingKeepsPartsAndColourChangesInStep() {
        var o = ModelObject(name: "Anhänger", mesh: Fixtures.box(10, 10, 10), tool: 0)
        o.parts = [ObjectPart(name: "Schrift", mesh: Fixtures.box(5, 5, 5), tool: 1)]
        o.colorChanges = [ColorChange(z: 5, tool: 0)]
        let moved = o.movingTool(from: 0, to: 3)
        XCTAssertEqual(moved.tool, 3)
        XCTAssertEqual(moved.parts.first?.tool, 1)
        XCTAssertEqual(moved.colorChanges.first?.tool, 3)
        XCTAssertEqual(moved.takingTools(of: o).tool, 0)
    }
}

final class ReviewRoundTwoTests: XCTestCase {
    /// A spool without RFID is there, its material is just unknown: no "empty" tip and nothing is moved.
    func testUnknownSpoolIsNotEmpty() {
        var s = PrintSettings()
        s.filaments = [.petg, .pla, .petg, .pla]
        let objects = [ModelObject(name: "Teil", mesh: Fixtures.box(20, 20, 20), tool: 0)]
        let loaded: [String?] = ["?", "PLA", "PETG", nil]
        XCTAssertFalse(PrintAdvisor.recommendations(objects: objects, settings: s, loadedTypes: loaded).contains { $0.id.hasPrefix("empty-") || $0.id.hasPrefix("mismatch-") })
        XCTAssertEqual(AutoTune.run(objects: objects, settings: s, loadedTypes: loaded).objects.first?.tool, 0)
    }

    /// A calibrated temperature or retraction is never replaced by the general PETG tips.
    func testCalibratedPETGKeepsItsValues() {
        var s = PrintSettings()
        var f = Filament.petg
        f.nozzleTemp = 250
        f.retractLength = 1.2
        f.calibratedKinds = [CalibrationKind.temperature.rawValue, CalibrationKind.retraction.rawValue]
        s.filaments[0] = f
        let objects = [ModelObject(name: "Teil", mesh: Fixtures.box(20, 20, 20))]
        let ids = PrintAdvisor.recommendations(objects: objects, settings: s).map(\.id)
        XCTAssertFalse(ids.contains("petg-temp-0"))
        XCTAssertFalse(ids.contains("petg-retract-0"))
        XCTAssertEqual(AutoTune.run(objects: objects, settings: s).settings.filaments[0].nozzleTemp, 250)
    }

    /// A flat sign is not a small model: no 0.12 mm layers.
    func testFlatPartsKeepTheirLayerHeight() {
        let s = PrintSettings()
        let sign = [ModelObject(name: "Schild", mesh: Fixtures.box(150, 100, 3))]
        XCTAssertFalse(PrintAdvisor.recommendations(objects: sign, settings: s).contains { $0.id == "fine" })
        let figure = [ModelObject(name: "Figur", mesh: Fixtures.box(15, 15, 25))]
        XCTAssertTrue(PrintAdvisor.recommendations(objects: figure, settings: s).contains { $0.id == "fine" })
    }

    func testDismissedTipsAreNotTakenOver() throws {
        let s = PrintSettings()
        let objects = try XCTUnwrap(PlateArranger.arrange([ModelObject(name: "T", mesh: Fixtures.tShape())], bedSize: s.bedSize))
        let result = AutoTune.run(objects: objects, settings: s, excluding: ["support"])
        XCTAssertEqual(result.settings.support, .off)
    }
}

final class AutoBrimTests: XCTestCase {
    private func width(_ mesh: TriangleMesh, _ f: Filament = .pla) -> Double {
        var s = PrintSettings()
        s.filaments[0] = f
        let a = PrintAdvisor.analyze(ModelObject(name: "t", mesh: mesh))
        return PrintAdvisor.autoBrimWidth(a, settings: s, filament: f)
    }

    /// Worked values of the Bambu/Orca formula (vmax 300 mm/s): a 20 mm PLA square tips at about 147 mm height.
    func testMatchesTheBambuFormula() {
        XCTAssertEqual(width(Fixtures.box(20, 20, 140)), 0, "just below the threshold")
        XCTAssertEqual(width(Fixtures.box(20, 20, 150)), 5, accuracy: 0.6)
        XCTAssertEqual(width(Fixtures.box(10, 10, 52)), 5, accuracy: 0.6, "10 mm square: 5 mm at 52 mm")
        XCTAssertEqual(width(Fixtures.box(40, 40, 200)), 0, "bases of 40 mm and more do not tip")
        XCTAssertGreaterThan(width(Fixtures.box(20, 20, 110), .petg), 0, "PETG counts double")
    }

    func testWarpProneMaterialsGetABrimOnLargeBases() {
        XCTAssertGreaterThanOrEqual(width(Fixtures.box(80, 80, 40), .abs), 5)
        XCTAssertEqual(width(Fixtures.box(80, 80, 40), .pla), 0)
    }
}
