import XCTest
@testable import SliceKit

final class PlacementTests: XCTestCase {
    func testLyingFacesFindTheRealContactFace() throws {
        let box = Fixtures.box(40, 20, 10)
        let faces = box.lyingFaces()
        let best = try XCTUnwrap(faces.first)
        XCTAssertEqual(best.contactArea, 800, accuracy: 1)
        XCTAssertEqual(best.height, 10, accuracy: 0.01)
        XCTAssertEqual(best.overhangArea, 0, accuracy: 1)
        // A tilted box still lies down flat on its big face.
        let tilted = box.transformed(.rotationX(0.6).then(.rotationY(0.3)))
        let laid = tilted.transformed(try XCTUnwrap(tilted.lyingFaces().first).rotation)
        XCTAssertEqual(laid.boundingBox.size.z, 10, accuracy: 0.01)
    }

    /// A staircase has many small faces pointing up (in total more than the back face) – but it can only lie on a face
    /// in one plane. The old rule laid it on the step tops and it stood on edges.
    func testStepsDoNotCountAsOneFace() throws {
        var vertices: [Vec3] = [], indices: [UInt32] = []
        for i in 0..<5 {
            let b = Fixtures.box(10, 30, Double(i + 1) * 4, at: Vec3(Double(i) * 10, 0, 0))
            indices += b.indices.map { $0 + UInt32(vertices.count) }
            vertices += b.vertices
        }
        let stairs = TriangleMesh(vertices: vertices, indices: indices)
        let best = try XCTUnwrap(stairs.lyingFaces().first)
        XCTAssertGreaterThanOrEqual(best.contactArea, 1490, "the bottom (50 × 30 mm) lies on the bed")
        XCTAssertLessThan(best.normal.z, -0.99, "the bottom, not the step tops")
    }

    func testTurningKeepsThePlaceAndTheBed() {
        let o = ModelObject(name: "Teil", mesh: Fixtures.box(40, 20, 10, at: Vec3(30, 50, 0)))
        let c = o.boundingBox.center
        let turned = o.transformedInPlace(.rotationZ(.pi / 2), bedSize: 270)
        XCTAssertEqual(turned.boundingBox.center.x, c.x, accuracy: 0.01)
        XCTAssertEqual(turned.boundingBox.center.y, c.y, accuracy: 0.01)
        XCTAssertEqual(turned.boundingBox.min.z, 0, accuracy: 1e-9)
        let tipped = o.transformedInPlace(.rotationX(.pi / 2), bedSize: 270)
        XCTAssertEqual(tipped.boundingBox.size.z, 20, accuracy: 0.01)
        XCTAssertEqual(tipped.boundingBox.min.z, 0, accuracy: 1e-9)
    }

    func testMovingStopsAtTheBedEdge() {
        let o = ModelObject(name: "Teil", mesh: Fixtures.box(40, 20, 10, at: Vec3(100, 100, 0)))
        let pushed = o.moved(dx: 500, dy: -500, bedSize: 270)
        XCTAssertEqual(pushed.boundingBox.max.x, 270, accuracy: 0.01)
        XCTAssertEqual(pushed.boundingBox.min.y, 0, accuracy: 0.01)
        let nudged = o.moved(dx: 10, dy: 5, bedSize: 270)
        XCTAssertEqual(nudged.boundingBox.min.x, 110, accuracy: 0.01)
        XCTAssertEqual(nudged.boundingBox.min.y, 105, accuracy: 0.01)
    }

    func testArrangePacksCompactlyWithoutOverlap() throws {
        let objects = (0..<6).map { i in ModelObject(name: "T\(i)", mesh: Fixtures.box(i < 2 ? 100 : 40, i < 2 ? 60 : 40, 10)) }
        let arranged = try XCTUnwrap(PlateArranger.arrange(objects, bedSize: 270, spacing: 6))
        XCTAssertFalse(PlateArranger.hasOverlap(arranged))
        var group = BoundingBox.empty
        arranged.forEach { group.include($0.boundingBox) }
        XCTAssertGreaterThanOrEqual(group.min.x, 0); XCTAssertLessThanOrEqual(group.max.x, 270)
        XCTAssertGreaterThanOrEqual(group.min.y, 0); XCTAssertLessThanOrEqual(group.max.y, 270)
        XCTAssertEqual(group.center.x, 135, accuracy: 0.5, "centred")
        XCTAssertEqual(group.center.y, 135, accuracy: 0.5)
        // Compact: the old shelf packing used one long row; the group is now roughly square.
        XCTAssertLessThan(abs(group.size.x - group.size.y), 80)
    }
}
