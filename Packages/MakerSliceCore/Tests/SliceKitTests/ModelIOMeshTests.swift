@testable import SliceKit
import XCTest
#if canImport(ModelIO)
import ModelIO

final class ModelIOMeshTests: XCTestCase {
    func testObjFromMetresBecomesMillimetreMeshOnTheBed() throws {
        let box = MDLMesh.newBox(withDimensions: SIMD3<Float>(0.1, 0.05, 0.02), segments: SIMD3<UInt32>(1, 1, 1), geometryType: .triangles,
                                 inwardNormals: false, allocator: nil)
        let asset = MDLAsset()
        asset.add(box)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("box-\(UUID().uuidString).obj")
        defer { try? FileManager.default.removeItem(at: url) }
        try asset.export(to: url)
        let mesh = try ModelIOMesh.load(url: url)
        let (fixed, report) = MeshRepair.repair(mesh)
        XCTAssertTrue(report.watertight)
        let size = fixed.boundingBox.size
        let dims = [size.x, size.y, size.z].sorted()
        XCTAssertEqual(dims[0], 20, accuracy: 0.1)
        XCTAssertEqual(dims[1], 50, accuracy: 0.1)
        XCTAssertEqual(dims[2], 100, accuracy: 0.1)
        XCTAssertEqual(size.z, 50, accuracy: 0.1, "Y-up file: the 50 mm side (its Y) stands up")
        XCTAssertEqual(fixed.volume, 100_000, accuracy: 500)
    }
}
#endif
