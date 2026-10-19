import Foundation
@testable import SliceKit
import XCTest

final class CutTests: XCTestCase {
    func testTriangulateSquareWithHole() {
        var poly = Polygons.rectangle(minX: 0, minY: 0, maxX: 10, maxY: 10)
        poly = poly.difference(.rectangle(minX: 3, minY: 3, maxX: 7, maxY: 7))
        let tris = poly.triangulated()
        let area = tris.reduce(0.0) { $0 + abs(Polygons.signedArea($1)) } / 1e6
        XCTAssertEqual(area, 84, accuracy: 0.01)
    }

    func testHorizontalCutWithPegs() throws {
        let obj = ModelObject(name: "Tower", mesh: Fixtures.box(20, 20, 40, at: Vec3(10, 10, 0)))
        let parts = try MeshCutter.cut(obj, CutOptions(axis: .z, position: 15, connector: .pegs))
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].mesh.volume, 20 * 20 * 15, accuracy: 0.5)
        XCTAssertEqual(parts[1].mesh.volume, 20 * 20 * 25, accuracy: 0.5)
        // Lower part keeps its bottom; the peg sticks out of the cut face.
        XCTAssertEqual(parts[0].volumes.filter { $0.kind == .add }.count, 1)
        XCTAssertGreaterThan(parts[0].boundingBox.max.z, 15.5)
        // Upper part got a hole and stands on its cut face.
        XCTAssertEqual(parts[1].volumes.filter { $0.kind == .subtract }.count, 1)
        XCTAssertEqual(parts[1].boundingBox.size.z, 25, accuracy: 1e-6)

        // Both parts slice into valid layers, with the hole visible near the bottom of part 2.
        let arranged = try XCTUnwrap(PlateArranger.arrange(parts, bedSize: 270))
        let layers = try Slicer(settings: PrintSettings()).slice([arranged[1]])
        let first = layers[2].outline.areaMM2
        XCTAssertEqual(first, 400 - Double.pi * 3.2 * 3.2, accuracy: 3)
    }

    func testSideCutWithDowels() throws {
        let obj = ModelObject(name: "Bar", mesh: Fixtures.box(300, 30, 20, at: Vec3(0, 0, 0)))
        let parts = try MeshCutter.cut(obj, CutOptions(axis: .x, position: 150, connector: .dowels))
        let pieces = parts.filter { !$0.name.contains("Dübel") }
        let dowels = parts.filter { $0.name.contains("Dübel") }
        XCTAssertEqual(pieces.count, 2)
        XCTAssertFalse(dowels.isEmpty)
        for piece in pieces {
            XCTAssertEqual(piece.mesh.volume, 150 * 30 * 20, accuracy: 1)
            XCTAssertEqual(piece.volumes.count, dowels.count)
            XCTAssertEqual(piece.boundingBox.min.z, 0, accuracy: 1e-6, "side cuts keep parts upright")
        }
    }

    func testAutoSplitFitsBed() throws {
        let big = ModelObject(name: "Sign", mesh: Fixtures.box(400, 60, 10))
        let parts = try MeshCutter.autoSplit(big, bedSize: 250, maxHeight: 250)
        let pieces = parts.filter { !$0.name.contains("Dübel") }
        XCTAssertEqual(pieces.count, 2)
        for p in pieces { XCTAssertLessThanOrEqual(p.boundingBox.size.x, 238) }
        XCTAssertNotNil(PlateArranger.arrange([pieces[0]], bedSize: 250))
    }

    func testCutOutsideThrows() {
        let obj = ModelObject(name: "Box", mesh: Fixtures.box(10, 10, 10))
        XCTAssertThrowsError(try MeshCutter.cut(obj, CutOptions(axis: .z, position: 30)))
    }
}
