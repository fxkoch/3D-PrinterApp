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

final class MaterialMappingTests: XCTestCase {
    private func color(_ tool: Int, _ hex: String, type: String? = "PLA") -> ModelColor {
        ModelColor(tool: tool, colorHex: hex, type: type, vendor: nil, users: ["x"])
    }

    func testMappingKeepsFileNumbersWhenTheyFit() {
        let map = ColorMapper.suggest(colors: [color(0, "#FFFFFF"), color(2, "#FF0000")], slotColors: ["#FFFFFF", "#000000", "#FF0000", "#0000FF"])
        XCTAssertEqual(map, [0: 0, 2: 2])
    }

    func testMoreColoursThanSlotsPickTheNearestFreeSlot() {
        let map = ColorMapper.suggest(colors: [color(0, "#FFFFFF"), color(5, "#101010"), color(6, "#FE0000")],
                                      slotColors: ["#FFFFFF", "#000000", "#FF0000", "#0000FF"])
        XCTAssertEqual(map[0], 0)
        XCTAssertEqual(map[5], 1, "near-black goes to the black slot")
        XCTAssertEqual(map[6], 2, "red goes to the red slot")
    }

    func testObjectsFollowTheColourMap() {
        var object = ModelObject(name: "A", mesh: Fixtures.box(10, 10, 10), tool: 4)
        object.parts = [ObjectPart(name: "B", mesh: Fixtures.box(5, 5, 5, at: Vec3(0, 0, 10)), tool: 6)]
        let mapped = object.applyingColorMap([4: 1, 6: 3])
        XCTAssertEqual(mapped.tool, 1)
        XCTAssertEqual(mapped.parts[0].tool, 3)
        // Mapping again from the original colours (not from the previous result) stays correct.
        XCTAssertEqual(mapped.applyingColorMap([4: 2, 6: 0]).tool, 2)
    }

    func testImportedModelListsTheColoursItUses() throws {
        var a = ModelObject(name: "Körper", mesh: Fixtures.box(10, 10, 10), tool: 0)
        a.parts = [ObjectPart(name: "Text", mesh: Fixtures.box(4, 4, 2, at: Vec3(0, 0, 10)), tool: 2)]
        let project = ProjectSettings.fromConfig(Data(##"{"filament_colour":["#FFFFFF","#00FF00","#FF8800"],"filament_type":["PLA","PETG","PLA"],"filament_vendor":["Bambu","","Generic"]}"##.utf8))
        let model = ImportedModel(objects: [a], projectSettings: project)
        XCTAssertTrue(model.isMultiColor)
        XCTAssertEqual(model.modelColors.map(\.tool), [0, 2], "the unused green extruder is not listed")
        XCTAssertEqual(model.modelColors[1].colorHex, "#FF8800")
        XCTAssertEqual(model.modelColors[0].vendor, "Bambu")
        XCTAssertEqual(model.modelColors[1].users, ["Text"])
    }

    func testSupportCanUseItsOwnSlot() throws {
        var s = PrintSettings(printer: .snapmakerU1)
        s.support = .buildPlateOnly
        s.supportSlot = 2
        let object = ModelObject(name: "T", mesh: Fixtures.tShape(), tool: 0)
        let arranged = try XCTUnwrap(PlateArranger.arrange([object], bedSize: s.bedSize))
        let layers = try Slicer(settings: s).slice(arranged)
        let supportTools = Set(layers.flatMap { $0.islands.filter { $0.extrusions.contains { $0.role == .support } }.map(\.tool) })
        XCTAssertEqual(supportTools, [2], "support is printed with slot 3")
        XCTAssertTrue(layers.contains { $0.islands.contains { $0.tool == 0 } }, "the object itself stays in slot 1")
        // The cloud job asks OrcaSlicer for the same filament.
        let overrides = OrcaJob.processOverrides(s)
        XCTAssertEqual(overrides["support_filament"], "3")
        XCTAssertEqual(overrides["support_interface_filament"], "0")
    }
}
