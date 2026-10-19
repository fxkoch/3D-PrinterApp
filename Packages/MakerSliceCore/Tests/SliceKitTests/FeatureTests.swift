import Foundation
@testable import SliceKit
import XCTest

final class FeatureTests: XCTestCase {
    func roles(_ layers: [SlicedLayer]) -> Set<ExtrusionRole> {
        Set(layers.flatMap { $0.islands.flatMap { $0.extrusions.map(\.role) } })
    }

    func testFilamentLibraryLoads() {
        XCTAssertGreaterThan(FilamentLibrary.all.count, 300)
        let kobra = FilamentLibrary.entries(for: .kobraS1).filter { $0.scope == "kobraS1" }
        XCTAssertTrue(kobra.contains { $0.filament.name == "Anycubic PLA" })
        XCTAssertEqual(FilamentLibrary.defaultFilament(for: .kobraS1).name, "Anycubic PLA")
        XCTAssertEqual(FilamentLibrary.defaultFilament(for: .snapmakerU1).name, "Generic PLA")
        XCTAssertEqual(FilamentLibrary.bestMatch(type: "PETG", printer: .kobraS1)?.type, "PETG")
        XCTAssertEqual(FilamentLibrary.bestMatch(type: "PLA High Speed", printer: .kobraS1)?.name, "Anycubic PLA High Speed")
        XCTAssertNil(FilamentLibrary.bestMatch(type: "NONE", printer: .kobraS1))
    }

    func testPrinterSwitchKeepsChoices() {
        var s = PrintSettings(printer: .snapmakerU1)
        s.layerHeight = 0.12
        s.filaments[1] = FilamentLibrary.bestMatch(type: "PETG", printer: .snapmakerU1)!
        s.filaments[1].color = "#112233"
        s.switchPrinter(to: .kobraS1)
        XCTAssertEqual(s.printer, .kobraS1)
        XCTAssertEqual(s.bedSize, 250)
        XCTAssertEqual(s.layerHeight, 0.12)
        XCTAssertEqual(s.filaments[1].type, "PETG")
        XCTAssertEqual(s.filaments[1].color, "#112233")
        XCTAssertTrue(s.primeTower)
    }

    func testSettingsDecodeTolerant() throws {
        let old = #"{"layerHeight":0.16,"wallLoops":4}"#
        let s = try JSONDecoder().decode(PrintSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.layerHeight, 0.16)
        XCTAssertEqual(s.wallLoops, 4)
        XCTAssertEqual(s.filaments.count, 4)
        let roundTrip = try JSONDecoder().decode(PrintSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(roundTrip, s)
    }

    func testKobraMultiColorUsesPrimeTowerAndToolChanges() throws {
        let s = PrintSettings(printer: .kobraS1)
        let a = ModelObject(name: "A", mesh: Fixtures.box(20, 20, 4), tool: 0)
        let b = ModelObject(name: "B", mesh: Fixtures.box(20, 20, 4), tool: 1)
        let arranged = try XCTUnwrap(PlateArranger.arrange([a, b], bedSize: s.bedSize))
        let out = try SliceJob(name: "multi", objects: arranged, settings: s).run()
        XCTAssertTrue(roles(out.layers).contains(.primeTower))
        XCTAssertTrue(out.gcode.contains("G9111 bedTemp="))
        XCTAssertTrue(out.gcode.contains("T1 ; change extruder"))
        XCTAssertFalse(out.gcode.contains("SM_PRINT"), "no U1 macros on the Kobra")
        // The tower must stay on the 250 mm bed and away from the parts.
        for layer in out.layers {
            for island in layer.islands {
                for e in island.extrusions where e.role == .primeTower {
                    for p in e.points {
                        XCTAssertTrue((0...250).contains(p.mmX) && (0...250).contains(p.mmY))
                    }
                }
            }
        }
        XCTAssertEqual(out.estimate.toolChanges, out.layers.count)
    }

    func testIroningAndGyroid() throws {
        var s = PrintSettings(printer: .snapmakerU1)
        s.ironing = true
        s.infillPattern = .gyroid
        s.infillDensity = 0.2
        let cube = try XCTUnwrap(PlateArranger.arrange([ModelObject(name: "C", mesh: Fixtures.box(30, 30, 10))], bedSize: 270))
        let out = try SliceJob(name: "c", objects: cube, settings: s).run()
        let r = roles(out.layers)
        XCTAssertTrue(r.contains(.ironing))
        XCTAssertTrue(r.contains(.sparseInfill))
        // Ironing only on the very top layer.
        let ironLayers = out.layers.filter { $0.islands.contains { $0.extrusions.contains { $0.role == .ironing } } }
        XCTAssertEqual(ironLayers.map(\.index), [out.layers.count - 1])
        // Gyroid lines are curved (many points per line).
        let infill = out.layers[20].islands[0].extrusions.filter { $0.role == .sparseInfill }
        XCTAssertGreaterThan(infill.map(\.points.count).max() ?? 0, 5)
    }

    func testBridgeDetected() throws {
        // Two pillars connected by a slab: the slab underside is a bridge.
        var mesh = Fixtures.box(10, 20, 10, at: Vec3(0, 0, 0))
        mesh.append(Fixtures.box(10, 20, 10, at: Vec3(40, 0, 0)))
        mesh.append(Fixtures.box(50, 20, 3, at: Vec3(0, 0, 10)))
        let arranged = try XCTUnwrap(PlateArranger.arrange([ModelObject(name: "Bridge", mesh: mesh)], bedSize: 270))
        let out = try SliceJob(name: "b", objects: arranged, settings: PrintSettings()).run()
        let bridgeLayers = out.layers.filter { $0.islands.contains { $0.extrusions.contains { $0.role == .bridge } } }
        XCTAssertFalse(bridgeLayers.isEmpty)
        XCTAssertTrue(bridgeLayers.allSatisfy { abs($0.z - 10.05) < 0.3 }, "\(bridgeLayers.map(\.z))")
        // Bridge lines should span the 30 mm gap along X (angle ~0°), not run along Y.
        let bridge = bridgeLayers[0].islands[0].extrusions.filter { $0.role == .bridge }.max { $0.lengthMM < $1.lengthMM }!
        let dx = abs(bridge.points.last!.mmX - bridge.points.first!.mmX)
        let dy = abs(bridge.points.last!.mmY - bridge.points.first!.mmY)
        XCTAssertGreaterThan(dx, dy)
    }

    func testVolumesAddAndSubtract() throws {
        let base = Fixtures.box(20, 20, 10)
        let peg = Fixtures.box(4, 4, 5, at: Vec3(8, 8, 10))
        let hole = Fixtures.box(4, 4, 5, at: Vec3(8, 8, 5))
        let obj = ModelObject(name: "P", mesh: base, volumes: [ObjectVolume(kind: .add, mesh: peg), ObjectVolume(kind: .subtract, mesh: hole)])
        XCTAssertEqual(obj.boundingBox.max.z, 15)
        let arranged = try XCTUnwrap(PlateArranger.arrange([obj], bedSize: 270))
        let layers = try Slicer(settings: PrintSettings()).slice(arranged)
        XCTAssertEqual(layers.last!.z, 15.05, accuracy: 0.01)
        // Layer at z≈7 has a 4×4 hole: outline area 400 − 16.
        let mid = layers.first { abs($0.z - 7.05) < 0.01 }!
        XCTAssertEqual(mid.outline.areaMM2, 384, accuracy: 0.5)
        let top = layers.first { abs($0.z - 12.05) < 0.01 }!
        XCTAssertEqual(top.outline.areaMM2, 16, accuracy: 0.5)
    }
}
