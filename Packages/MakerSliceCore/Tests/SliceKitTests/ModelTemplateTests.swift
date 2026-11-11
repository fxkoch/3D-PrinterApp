import XCTest
@testable import SliceKit

/// The built-in models load, are closed solids and fit on the printers.
final class ModelTemplateTests: XCTestCase {
    func testTemplatesLoadAndFitTheBeds() throws {
        XCTAssertEqual(ModelTemplates.all.count, 5)
        for template in ModelTemplates.all {
            let data = try XCTUnwrap(template.data(), template.id)
            let mesh = try STLReader.read(data)
            XCTAssertGreaterThan(mesh.triangleCount, 20, template.id)
            XCTAssertGreaterThan(mesh.volume, 1000, template.id)
            let size = mesh.boundingBox.size
            // Kobra S1 (250 × 250 × 250) is the smallest of the three printers.
            XCTAssertLessThanOrEqual(max(size.x, size.y), 245, template.id)
            XCTAssertLessThanOrEqual(size.z, 245, template.id)
        }
    }

    func testModuleIsAClosedSolid() throws {
        let template = try XCTUnwrap(ModelTemplates.all.first { $0.id == "zwiebelspender_modul" })
        let mesh = try STLReader.read(try XCTUnwrap(template.data()))
        // Every edge is shared by exactly two triangles: a closed solid without holes.
        var edges: [UInt64: Int] = [:]
        let idx = mesh.indices
        for t in stride(from: 0, to: idx.count, by: 3) {
            for (a, b) in [(idx[t], idx[t + 1]), (idx[t + 1], idx[t + 2]), (idx[t + 2], idx[t])] {
                edges[UInt64(min(a, b)) << 32 | UInt64(max(a, b)), default: 0] += 1
            }
        }
        XCTAssertTrue(edges.values.allSatisfy { $0 == 2 }, "module is watertight")
        XCTAssertTrue(template.needsSupport)
    }
}
