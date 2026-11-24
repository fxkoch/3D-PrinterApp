import XCTest
@testable import SliceKit

/// From the headphone stand: two columns and a plate on one bed. The nozzle printed the walls of all three, then the
/// outer walls of all three, then the infill of all three – ten trips across the fresh walls per layer, without lifting
/// (Z-hop was off for every material because PETG strung). Result: X-shaped marks on the sides facing each other.
final class PartOrderTests: XCTestCase {
    func testComponentsSplitPartsWithTheirHoles() {
        let ring = Polygons([Self.square(0, 0, 40), Self.square(10, 10, 20).reversed()])
        let island = Polygons([Self.square(15, 15, 10)])          // inside the hole of the ring
        let other = Polygons([Self.square(60, 0, 10)])
        let parts = (ring + island + other).components()
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts.map(\.paths.count).sorted(), [1, 1, 2], "the hole stays with the ring")
        XCTAssertEqual(parts.map { abs($0.areaMM2) }.reduce(0, +), 1600 - 400 + 100 + 100, accuracy: 1)
    }

    func testEachPartIsPrintedCompletelyBeforeTheNext() throws {
        var s = PrintSettings(printer: .snapmakerU1)
        s.brimWidth = 0; s.skirtLoops = 0
        let objects = [
            ModelObject(name: "Säule 1", mesh: Fixtures.box(12, 12, 10, at: Vec3(70, 170, 0))),
            ModelObject(name: "Säule 2", mesh: Fixtures.box(12, 12, 10, at: Vec3(110, 170, 0))),
            ModelObject(name: "Platte", mesh: Fixtures.box(60, 20, 10, at: Vec3(170, 50, 0))),
        ]
        let layers = try Slicer(settings: s).slice(objects)
        let layer = try XCTUnwrap(layers.first { $0.index == 20 })
        // Which part each extrusion belongs to, in printing order; count the switches.
        func part(_ e: Extrusion) -> Int {
            let x = e.points[0].mmX
            return x < 90 ? 0 : (x < 150 ? 1 : 2)
        }
        let sequence = layer.islands.flatMap(\.extrusions).map(part)
        let switches = zip(sequence, sequence.dropFirst()).filter { $0 != $1 }.count
        XCTAssertEqual(switches, 2, "three parts, two moves between them (was ten)")
        XCTAssertEqual(Set(sequence).count, 3)
    }

    func testZHopOnlyOffForPETG() throws {
        var s = PrintSettings(printer: .snapmakerU1)
        s.brimWidth = 0; s.skirtLoops = 0; s.zHop = 0.4
        s.filaments[0] = try XCTUnwrap(FilamentLibrary.bestMatch(type: "PLA", printer: s.printer))
        s.filaments[1] = try XCTUnwrap(FilamentLibrary.bestMatch(type: "PETG", printer: s.printer))
        s.filaments[1].zHop = 0
        func lifts(tool: Int) throws -> Int {
            let objects = [ModelObject(name: "A", mesh: Fixtures.box(10, 10, 2, at: Vec3(50, 50, 0)), tool: tool),
                           ModelObject(name: "B", mesh: Fixtures.box(10, 10, 2, at: Vec3(150, 50, 0)), tool: tool)]
            let layers = try Slicer(settings: s).slice(objects)
            let gcode = GCodeWriter(settings: s).write(layers: layers, jobName: "t", objects: objects).gcode
            return gcode.split(separator: "\n").filter { $0.hasPrefix("G1 Z") && $0.contains("F1200") }.count
        }
        let pla = try lifts(tool: 0), petg = try lifts(tool: 1)
        XCTAssertGreaterThan(pla, petg + 10, "PLA lifts on the way between the parts, PETG does not")
    }

    func testAdvisorFindsTheThinColumnAndAsksForZHop() throws {
        // Ring-like base with a 12 mm column 200 mm high, plus a separate plate – like the headphone stand.
        var vertices: [Vec3] = [], indices: [UInt32] = []
        for m in [Fixtures.box(100, 100, 15, at: Vec3(40, 40, 0)), MeshCutter.cylinder(center: (85, 125), radius: 6, z0: 15, z1: 215)] {
            indices += m.indices.map { $0 + UInt32(vertices.count) }
            vertices += m.vertices
        }
        let stand = ModelObject(name: "Ständer", mesh: TriangleMesh(vertices: vertices, indices: indices))
        let plate = ModelObject(name: "Ablage", mesh: Fixtures.box(60, 20, 80, at: Vec3(170, 40, 0)))
        var s = PrintSettings(printer: .snapmakerU1)
        s.wallLoops = 3; s.zHop = 0
        var objects = [stand, plate]
        let analysis = PrintAdvisor.analyze(stand)
        XCTAssertEqual(analysis.columnDiameter, 12, accuracy: 1)
        XCTAssertGreaterThan(analysis.columnHeight, 150)
        let recs = PrintAdvisor.recommendations(objects: objects, settings: s)
        let column = try XCTUnwrap(recs.first { $0.id == "thin-column" })
        XCTAssertEqual(column.action, .atLeastWalls(6))
        let hop = try XCTUnwrap(recs.first { $0.id == "zhop-parts" })
        try PrintAdvisor.apply(hop.action!, settings: &s, objects: &objects)
        XCTAssertEqual(s.zHop, 0.4)
        // A compact part is no column.
        XCTAssertEqual(PrintAdvisor.analyze(ModelObject(name: "Würfel", mesh: Fixtures.box(30, 30, 30))).columnHeight, 0)
    }

    private static func square(_ x: Double, _ y: Double, _ size: Double) -> Path {
        [IntPoint(mmX: x, mmY: y), IntPoint(mmX: x + size, mmY: y), IntPoint(mmX: x + size, mmY: y + size), IntPoint(mmX: x, mmY: y + size)]
    }
}
