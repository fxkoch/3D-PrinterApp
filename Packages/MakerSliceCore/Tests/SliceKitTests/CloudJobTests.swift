import Foundation
@testable import SliceKit
import XCTest

/// 3MF export and the OrcaSlicer cloud job. With CLOUD_EXPORT_DIR set, the jobs are written out so
/// the cloud-slice self-test can feed them to the real OrcaSlicer.
final class CloudJobTests: XCTestCase {
    func sampleJobs() throws -> [(String, [ModelObject], PrintSettings)] {
        var u1 = PrintSettings(printer: .snapmakerU1)
        u1.filaments[0] = FilamentLibrary.bestMatch(type: "PETG", printer: .snapmakerU1)!
        let single = PlateArranger.arrange([ModelObject(name: "Würfel", mesh: Fixtures.box(20, 20, 10), tool: 0)],
                                           bedSize: u1.bedSize)!

        var u1Multi = PrintSettings(printer: .snapmakerU1)
        u1Multi.ironing = true
        u1Multi.infillPattern = .gyroid
        let multi = PlateArranger.arrange([ModelObject(name: "A", mesh: Fixtures.box(20, 20, 6), tool: 0),
                                           ModelObject(name: "B", mesh: Fixtures.box(15, 15, 6), tool: 1)],
                                          bedSize: u1Multi.bedSize)!

        let kobra = PrintSettings(printer: .kobraS1)
        let parts = try MeshCutter.cut(ModelObject(name: "Stab", mesh: Fixtures.box(20, 20, 40), tool: 0),
                                       CutOptions(axis: .z, position: 20, connector: .pegs))
        var colored = parts
        colored[colored.count - 1].tool = 1
        let kobraObjects = PlateArranger.arrange(colored, bedSize: kobra.bedSize)!
        return [("u1-single", single, u1), ("u1-multi", multi, u1Multi), ("kobra-multi", kobraObjects, kobra)]
    }

    func testThreeMFRoundTrip() throws {
        for (_, objects, _) in try sampleJobs() {
            let data = ThreeMFWriter.write(objects)
            let back = try ModelImporter.load(data: data, fileName: "x.3mf")
            XCTAssertEqual(back.objects.count, objects.count)
            for (a, b) in zip(objects, back.objects) {
                XCTAssertEqual(a.tool, b.tool)
                XCTAssertEqual(a.name, b.name)
                let addTriangles = a.volumes.filter { $0.kind == .add }.map(\.mesh.triangleCount).reduce(0, +)
                XCTAssertEqual(b.mesh.triangleCount, a.mesh.triangleCount + addTriangles)
                XCTAssertEqual(b.boundingBox.min.x, a.boundingBox.min.x, accuracy: 0.01)
            }
        }
    }

    func testJobManifestMapsSettings() throws {
        var s = PrintSettings(printer: .kobraS1)
        s.infillDensity = 0.2
        s.wallOrder = .innerOuter
        s.spiralVase = true
        s.support = .buildPlateOnly
        let job = try OrcaJob(objects: [ModelObject(name: "Vase / Test", mesh: Fixtures.box(10, 10, 10))], settings: s, name: "Vase / Test")
        XCTAssertTrue(job.id.contains("vase-test"), job.id)
        XCTAssertFalse(job.id.contains("/"))
        let m = try XCTUnwrap(JSONSerialization.jsonObject(with: job.manifest) as? [String: Any])
        XCTAssertEqual(m["printer"] as? String, "kobraS1")
        let p = try XCTUnwrap(m["process"] as? [String: String])
        XCTAssertEqual(p["sparse_infill_density"], "20%")
        XCTAssertEqual(p["wall_sequence"], "inner wall/outer wall")
        XCTAssertEqual(p["spiral_mode"], "1")
        XCTAssertEqual(p["support_on_build_plate_only"], "1")
        XCTAssertEqual(p["curr_bed_type"], "Textured PEI Plate")
        let f = try XCTUnwrap((m["filaments"] as? [[String: Any]])?.first)
        XCTAssertEqual(f["preset"] as? String, "Anycubic PLA @Anycubic Kobra S1 0.4 nozzle")
    }

    func testExportForCloudSelfTest() throws {
        guard let dir = ProcessInfo.processInfo.environment["CLOUD_EXPORT_DIR"] else {
            throw XCTSkip("CLOUD_EXPORT_DIR not set")
        }
        for (name, objects, settings) in try sampleJobs() {
            let job = try OrcaJob(objects: objects, settings: settings, name: name)
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try job.manifest.write(to: url.appendingPathComponent("job.json"))
            try job.model.write(to: url.appendingPathComponent(OrcaJob.modelFileName))
            // Our own G-code for comparison.
            let own = try SliceJob(name: name, objects: objects, settings: settings).run()
            try Data(own.gcode.utf8).write(to: url.appendingPathComponent("makerslice.gcode"))
        }
    }

    func testGCodePreviewReadsOwnOutput() throws {
        let (_, objects, settings) = try sampleJobs()[1]
        let out = try SliceJob(name: "multi", objects: objects, settings: settings).run()
        let parsed = GCodePreview.parse(out.gcode)
        XCTAssertEqual(parsed.layers.count, out.layers.count)
        XCTAssertEqual(Set(parsed.layers.flatMap { $0.islands.map(\.tool) }), [0, 1])
        let roles = Set(parsed.layers.flatMap { $0.islands.flatMap { $0.extrusions.map(\.role) } })
        XCTAssertTrue(roles.isSuperset(of: [.outerWall, .innerWall, .topSurface, .sparseInfill, .ironing]), "\(roles)")
        XCTAssertEqual(parsed.estimate.seconds, out.estimate.seconds, accuracy: 1)
        XCTAssertEqual(parsed.estimate.toolChanges, out.estimate.toolChanges)
        XCTAssertEqual(parsed.estimate.totalGrams, out.estimate.totalGrams, accuracy: 0.05)
        XCTAssertEqual(parsed.layers[3].z, out.layers[3].z, accuracy: 0.001)
    }

    /// With ORCA_GCODE pointing at a file from the cloud slicer: the preview understands real Orca output.
    func testParsesRealOrcaGCode() throws {
        guard let path = ProcessInfo.processInfo.environment["ORCA_GCODE"] else { throw XCTSkip("ORCA_GCODE not set") }
        let parsed = GCodePreview.parse(try String(contentsOfFile: path, encoding: .utf8))
        XCTAssertGreaterThan(parsed.layers.count, 1)
        XCTAssertGreaterThan(parsed.estimate.seconds, 0)
        XCTAssertGreaterThan(parsed.estimate.totalGrams, 0)
        let roles = Set(parsed.layers.flatMap { $0.islands.flatMap { $0.extrusions.map(\.role) } })
        XCTAssertTrue(roles.isSuperset(of: [.outerWall, .innerWall, .sparseInfill]), "\(roles)")
        print("Orca preview:", parsed.layers.count, "layers", parsed.estimate.formattedTime, parsed.estimate.totalGrams, "g", roles.map(\.rawValue).sorted())
    }
}
