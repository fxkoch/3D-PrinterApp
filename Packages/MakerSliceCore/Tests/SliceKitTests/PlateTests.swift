@testable import SliceKit
import XCTest

final class PlateTests: XCTestCase {
    private func box(_ x: Double, _ y: Double, _ z: Double = 10, name: String = "o") -> ModelObject {
        ModelObject(name: name, mesh: Fixtures.box(x, y, z))
    }

    func testObjectsThatDontFitMoveToANewPlate() throws {
        let bed = 270.0
        let big = (0..<3).map { box(150, 150, name: "b\($0)") }   // only one 150 mm square per 270 mm bed
        let layout = PlateArranger.distribute(big, bedSize: bed)
        XCTAssertEqual(layout.plates.count, 3)
        XCTAssertTrue(layout.unplaceable.isEmpty)
        for (i, plate) in layout.plates.enumerated() {
            XCTAssertEqual(plate.count, 1)
            XCTAssertEqual(plate[0].plate, i + 1)
            XCTAssertTrue(plate[0].boundingBox.min.x >= -0.01 && plate[0].boundingBox.max.x <= bed + 0.01)
            XCTAssertEqual(plate[0].boundingBox.min.z, 0, accuracy: 1e-6)
        }
    }

    func testSmallObjectsShareOnePlate() {
        let layout = PlateArranger.distribute((0..<9).map { box(40, 40, name: "s\($0)") }, bedSize: 270)
        XCTAssertEqual(layout.plates.count, 1)
        XCTAssertEqual(layout.plates[0].count, 9)
    }

    func testNewObjectFillsGapOnEarlierPlate() {
        var layout = PlateArranger.distribute([box(150, 150), box(150, 150)], bedSize: 270)
        XCTAssertEqual(layout.plates.count, 2)
        // A small part goes on the preferred plate (2), not onto a third one.
        layout = PlateArranger.place([box(30, 30, name: "klein")], into: layout.plates, bedSize: 270, preferred: 1)
        XCTAssertEqual(layout.plates.count, 2)
        XCTAssertEqual(layout.plates[1].map(\.name).sorted(), ["klein", "o"])
    }

    func testRotationMakesLongPartsFit() {
        // 250 × 40 parts: 6 of them only fit when kept lengthwise; a tall (40 × 250) orientation must be turned.
        let parts = (0..<4).map { box(40, 250, name: "p\($0)") }
        let layout = PlateArranger.distribute(parts, bedSize: 270)
        XCTAssertEqual(layout.plates.count, 1)
    }

    func testTooLargeObjectIsReported() {
        let layout = PlateArranger.distribute([box(400, 400, name: "riesig"), box(20, 20)], bedSize: 270)
        XCTAssertEqual(layout.unplaceable.map(\.name), ["riesig"])
        XCTAssertEqual(layout.plates.flatMap { $0 }.count, 1)
    }

    func testOverlapDetection() {
        let a = ModelObject(name: "a", mesh: Fixtures.box(20, 20, 10))
        let b = ModelObject(name: "b", mesh: Fixtures.box(20, 20, 10))
        XCTAssertTrue(PlateArranger.hasOverlap([a, b]))
        XCTAssertFalse(PlateArranger.hasOverlap([a, b.transformed(.translation(Vec3(30, 0, 0)))]))
        XCTAssertFalse(PlateArranger.hasOverlap([a, b.transformed(.translation(Vec3(20, 0, 0)))]), "touching is fine")
    }

    /// Cutting a long part in two: the pieces share a plate when they fit together, otherwise each goes to its own plate.
    func testCutPartsDistributeOverPlates() throws {
        let bed = 270.0
        let blocker = ModelObject(name: "Block", mesh: Fixtures.box(200, 200, 10))
        let start = PlateArranger.place([blocker], into: [[]], bedSize: bed)
        XCTAssertEqual(start.plates.count, 1)

        // Halves of 150 × 200 mm don't fit next to each other (306 mm) in any orientation: one plate each.
        let wide = ModelObject(name: "Stab", mesh: Fixtures.box(300, 200, 20))
        let wideParts = try MeshCutter.cut(wide, CutOptions(axis: .x, position: 150, connector: .none))
            .filter { !$0.name.contains("Dübel") }
        XCTAssertEqual(wideParts.count, 2)
        var layout = PlateArranger.place(wideParts, into: start.plates, bedSize: bed, preferred: 0)
        XCTAssertTrue(layout.unplaceable.isEmpty)
        XCTAssertEqual(layout.plates.map(\.count), [1, 1, 1])

        // Halves of 150 × 100 mm fit together (turned) – they share the second plate.
        let slim = ModelObject(name: "Leiste", mesh: Fixtures.box(300, 100, 20))
        let slimParts = try MeshCutter.cut(slim, CutOptions(axis: .x, position: 150, connector: .none))
            .filter { !$0.name.contains("Dübel") }
        layout = PlateArranger.place(slimParts, into: start.plates, bedSize: bed, preferred: 0)
        XCTAssertEqual(layout.plates.map(\.count), [1, 2])
        for (i, plate) in layout.plates.enumerated() {
            var box = BoundingBox.empty
            plate.forEach { box.include($0.boundingBox) }
            XCTAssertLessThanOrEqual(box.max.x, bed + 0.01, "plate \(i + 1)")
            XCTAssertLessThanOrEqual(box.max.y, bed + 0.01, "plate \(i + 1)")
            XCTAssertGreaterThanOrEqual(box.min.x, -0.01)
            XCTAssertGreaterThanOrEqual(box.min.y, -0.01)
        }
    }
}
