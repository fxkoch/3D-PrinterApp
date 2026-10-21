@testable import SliceKit
import XCTest

final class MeshRepairTests: XCTestCase {
    private func openBox() -> TriangleMesh {
        var box = Fixtures.box(10, 10, 10)
        // Remove the two triangles of the top face.
        var keep: [UInt32] = []
        for t in 0..<box.triangleCount {
            let z = (0..<3).map { box.vertices[Int(box.indices[t * 3 + $0])].z }
            if z.allSatisfy({ abs($0 - 10) < 1e-9 }) { continue }
            keep += [box.indices[t * 3], box.indices[t * 3 + 1], box.indices[t * 3 + 2]]
        }
        box.indices = keep
        return box
    }

    func testHoleIsClosedAndVolumeKept() {
        let open = openBox()
        XCTAssertGreaterThan(MeshRepair.openEdgeCount(open), 0)
        let (fixed, report) = MeshRepair.repair(open)
        XCTAssertTrue(report.watertight)
        XCTAssertEqual(report.closedHoles, 1)
        XCTAssertEqual(fixed.volume, 1000, accuracy: 1)
        XCTAssertGreaterThan(MeshRepair.signedVolume(fixed), 0, "outward winding")
    }

    func testFloatingSpeckIsRemoved() {
        var mesh = Fixtures.box(20, 20, 20)
        mesh.append(Fixtures.box(1, 1, 1, at: Vec3(40, 40, 40)))
        let (fixed, report) = MeshRepair.repair(mesh)
        XCTAssertEqual(report.removedFragments, 1)
        XCTAssertEqual(fixed.volume, 8000, accuracy: 1)
    }

    func testInsideOutMeshIsFlipped() {
        var mesh = Fixtures.box(10, 10, 10)
        for i in stride(from: 0, to: mesh.indices.count, by: 3) { mesh.indices.swapAt(i + 1, i + 2) }
        let (fixed, report) = MeshRepair.repair(mesh)
        XCTAssertTrue(report.flipped)
        XCTAssertGreaterThan(MeshRepair.signedVolume(fixed), 0)
    }

    func testClosedMeshStaysUntouched() {
        let (fixed, report) = MeshRepair.repair(Fixtures.box(10, 10, 10))
        XCTAssertEqual(report, MeshRepair.Report())
        XCTAssertEqual(fixed.triangleCount, 12)
    }
}
