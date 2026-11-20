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
