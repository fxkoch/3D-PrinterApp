import Foundation
@testable import SliceKit
import XCTest

final class AdvisorTests: XCTestCase {
    func ids(_ r: [Recommendation]) -> Set<String> { Set(r.map(\.id)) }

    func testOverhangSuggestsSupport() throws {
        let t = try XCTUnwrap(PlateArranger.arrange([ModelObject(name: "T", mesh: Fixtures.tShape())], bedSize: 270))
        var s = PrintSettings()
        let recs = PrintAdvisor.recommendations(objects: t, settings: s)
        let support = try XCTUnwrap(recs.first { $0.id == "support" })
        XCTAssertEqual(support.action, .support(.buildPlateOnly))
        var objects = t
        try PrintAdvisor.apply(support.action!, settings: &s, objects: &objects)
        XCTAssertEqual(s.support, .buildPlateOnly)
        XCTAssertFalse(ids(PrintAdvisor.recommendations(objects: t, settings: s)).contains("support"))
    }

    func testFlatTopSuggestsIroningAndSmallSuggestsFine() throws {
        let cube = try XCTUnwrap(PlateArranger.arrange([ModelObject(name: "C", mesh: Fixtures.box(40, 40, 10))], bedSize: 270))
        XCTAssertTrue(ids(PrintAdvisor.recommendations(objects: cube, settings: PrintSettings())).contains("ironing"))
        let tiny = try XCTUnwrap(PlateArranger.arrange([ModelObject(name: "c", mesh: Fixtures.box(8, 8, 8))], bedSize: 270))
        let recs = PrintAdvisor.recommendations(objects: tiny, settings: PrintSettings())
        XCTAssertTrue(ids(recs).contains("fine"))
        XCTAssertTrue(ids(recs).contains("brim"), "8×8 mm footprint needs a brim")
    }

    func testTooLargeSplitsAutomatically() throws {
        var s = PrintSettings(printer: .kobraS1)
        var objects = [ModelObject(name: "Long", mesh: Fixtures.box(400, 40, 20))]
        let recs = PrintAdvisor.recommendations(objects: objects, settings: s)
        let split = try XCTUnwrap(recs.first { $0.id.hasPrefix("split-") })
        XCTAssertEqual(split.severity, .warning)
        try PrintAdvisor.apply(split.action!, settings: &s, objects: &objects)
        XCTAssertGreaterThan(objects.count, 2)
        let out = try SliceJob(name: "split", objects: objects, settings: s).run()
        XCTAssertFalse(out.layers.isEmpty)
    }

    func testLoadedFilamentMismatch() throws {
        var s = PrintSettings(printer: .kobraS1)
        var objects = try XCTUnwrap(PlateArranger.arrange([ModelObject(name: "C", mesh: Fixtures.box(20, 20, 20), tool: 1)], bedSize: 250))
        let recs = PrintAdvisor.recommendations(objects: objects, settings: s, loadedTypes: ["PLA", "PETG", nil, nil])
        let mismatch = try XCTUnwrap(recs.first { $0.id == "mismatch-1" })
        try PrintAdvisor.apply(mismatch.action!, settings: &s, objects: &objects)
        XCTAssertEqual(s.filaments[1].type, "PETG")
        let empty = PrintAdvisor.recommendations(objects: objects, settings: s, loadedTypes: ["PLA", "NONE"])
        XCTAssertTrue(ids(empty).contains("empty-1"))
    }

    func testMultiColorKobraWithoutTowerWarns() throws {
        var s = PrintSettings(printer: .kobraS1)
        s.primeTower = false
        let objs = try XCTUnwrap(PlateArranger.arrange([
            ModelObject(name: "A", mesh: Fixtures.box(20, 20, 5), tool: 0),
            ModelObject(name: "B", mesh: Fixtures.box(20, 20, 5), tool: 1),
        ], bedSize: 250))
        XCTAssertTrue(ids(PrintAdvisor.recommendations(objects: objs, settings: s)).contains("tower"))
    }
}
