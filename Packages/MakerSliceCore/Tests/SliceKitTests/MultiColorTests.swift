@testable import SliceKit
import XCTest

final class MultiColorTests: XCTestCase {
    private func tools(of layers: [SlicedLayer]) -> [[Int]] { layers.map { $0.islands.map(\.tool) } }

    func testColorChangeAtHeightSwitchesTheSlot() throws {
        var cube = ModelObject(name: "Würfel", mesh: Fixtures.box(20, 20, 10), tool: 0)
        cube.colorChanges = [ColorChange(z: 5, tool: 2)]
        let arranged = try XCTUnwrap(PlateArranger.arrange([cube], bedSize: 270))
        let layers = try Slicer(settings: PrintSettings(printer: .snapmakerU1)).slice(arranged)
        for layer in layers {
            let expected = layer.z - layer.height / 2 < 5 ? 0 : 2
            XCTAssertEqual(Set(layer.islands.map(\.tool)), [expected], "layer at z=\(layer.z)")
        }
    }

    func testColouredPartsKeepTheirSlot() throws {
        var base = ModelObject(name: "Sockel", mesh: Fixtures.box(30, 30, 10), tool: 0)
        base.parts = [ObjectPart(name: "Deckel", mesh: Fixtures.box(10, 10, 10, at: Vec3(10, 10, 10)), tool: 3)]
        XCTAssertEqual(base.boundingBox.size.z, 20, accuracy: 1e-9)
        let arranged = try XCTUnwrap(PlateArranger.arrange([base], bedSize: 270))
        XCTAssertEqual(arranged[0].parts.count, 1)
        let layers = try Slicer(settings: PrintSettings(printer: .snapmakerU1)).slice(arranged)
        XCTAssertEqual(Set(layers.first!.islands.map(\.tool)), [0])
        XCTAssertEqual(Set(layers.last!.islands.map(\.tool)), [3])
    }

    func testMultiColorObjectsCannotBeCut() {
        var obj = ModelObject(name: "x", mesh: Fixtures.box(20, 20, 20))
        obj.colorChanges = [ColorChange(z: 5, tool: 1)]
        XCTAssertThrowsError(try MeshCutter.cut(obj, CutOptions(axis: .z, position: 10, connector: .none))) {
            XCTAssertEqual($0 as? CutError, .multiColor)
        }
    }

    func testPurgeVolumeShrinksTheTowerStripAndIsReported() throws {
        // Two stacked colours on the Kobra S1 (single nozzle + ACE) need the purge tower.
        func slice(purge: Double) throws -> (PrintEstimate, String) {
            var cube = ModelObject(name: "Würfel", mesh: Fixtures.box(20, 20, 12), tool: 0)
            cube.colorChanges = [ColorChange(z: 4, tool: 1), ColorChange(z: 8, tool: 0)]
            var s = PrintSettings(printer: .kobraS1)
            s.primeTower = true
            s.purgeVolume = purge
            let arranged = try XCTUnwrap(PlateArranger.arrange([cube], bedSize: s.bedSize))
            let out = try SliceJob(name: "c", objects: arranged, settings: s).run()
            return (out.estimate, out.gcode)
        }
        let dense = try slice(purge: 0).0
        let small = try slice(purge: 20).0
        XCTAssertGreaterThan(dense.toolChanges, 0)
        XCTAssertGreaterThan(dense.purgeGrams, 0)
        XCTAssertLessThan(small.purgeGrams, dense.purgeGrams, "a smaller purge volume wastes less")
    }

    func testPartsAreWrittenWithTheirOwnExtruder() throws {
        var obj = ModelObject(name: "A", mesh: Fixtures.box(10, 10, 10), tool: 1)
        obj.parts = [ObjectPart(name: "B", mesh: Fixtures.box(5, 5, 5, at: Vec3(2, 2, 10)), tool: 3)]
        let zip = try ZipArchive(data: ThreeMFWriter.write([obj]))
        let settings = String(decoding: try XCTUnwrap(zip.contents(of: "Metadata/model_settings.config")), as: UTF8.self)
        XCTAssertTrue(settings.contains("value=\"2\""))
        XCTAssertTrue(settings.contains("value=\"4\""), "part B uses slot 4")
        // Reading it back gives a main body in slot 2 and a part in slot 4.
        let back = try ModelImporter.load(data: ThreeMFWriter.write([obj]), fileName: "x.3mf")
        XCTAssertEqual(back.objects.count, 1)
        XCTAssertEqual(back.objects[0].parts.count, 1)
        XCTAssertEqual(Set([back.objects[0].tool] + back.objects[0].parts.map(\.tool)), [1, 3])
    }
}
