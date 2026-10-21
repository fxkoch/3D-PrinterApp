import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PrinterKit
import SliceKit
import XCTest

/// End-to-end virtual print on a Snapmaker U1: the unmodified Snapmaker Moonraker fork running on
/// u1sim (a simulated Klipper with the U1's four tool heads and RFID filament data).
/// Start it with tools/virtualprinters/start_u1.sh and set U1_HOST=127.0.0.1.
final class U1VirtualPrintTests: XCTestCase {
    var host: String!

    override func setUpWithError() throws {
        guard let h = ProcessInfo.processInfo.environment["U1_HOST"] else { throw XCTSkip("U1_HOST not set") }
        host = h
    }

    func client() -> MoonrakerClient {
        MoonrakerClient(connection: PrinterConnection(name: "Virtueller U1", host: host))
    }

    func waitFor(_ what: String, timeout: Double = 60, _ condition: (PrinterStatus) -> Bool) async throws -> PrinterStatus {
        let deadline = Date().addingTimeInterval(timeout)
        var last: PrinterStatus?
        while Date() < deadline {
            let s = try await client().status()
            if condition(s) { return s }
            last = s
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTFail("Timeout waiting for \(what); last state \(String(describing: last?.state)) progress \(last?.progress ?? -1)")
        throw CancellationError()
    }

    func metadata(_ file: String) async throws -> [String: Any] {
        let url = URL(string: "http://\(host!):7125/server/files/metadata?filename=\(file)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return ((try JSONSerialization.jsonObject(with: data)) as? [String: Any])?["result"] as? [String: Any] ?? [:]
    }

    func testFullVirtualPrint() async throws {
        let printer = client()
        let info = try await printer.serverInfo()
        XCTAssertEqual(info.klippyState, "ready")

        // 1. Live data: the four heads and the RFID filament data.
        var status = try await printer.status()
        if status.state == .printing || status.state == .paused {
            try await printer.cancel()
            status = try await waitFor("idle") { $0.state != .printing && $0.state != .paused }
        }
        XCTAssertEqual(status.tools.count, 4)
        XCTAssertEqual(status.filaments.count, 4)
        let loaded = status.filaments.map { $0.present ? $0.type : nil }
        XCTAssertTrue(loaded.allSatisfy { $0 != nil }, "u1sim scenario loads all four heads: \(loaded)")

        // 2. Prepare like the app does: profiles that match the loaded spools, two colours.
        var settings = PrintSettings(printer: .snapmakerU1)
        for (i, f) in status.filaments.enumerated() where f.present {
            if let type = f.type, var match = FilamentLibrary.bestMatch(type: type, vendor: f.vendor, printer: .snapmakerU1) {
                match.color = f.color ?? match.color
                settings.filaments[i] = match
            }
        }
        let objects = PlateArranger.arrange([
            ModelObject(name: "Sockel", mesh: box(30, 30, 4), tool: 0),
            ModelObject(name: "Turm", mesh: box(12, 12, 15), tool: 2),
        ], bedSize: settings.bedSize)!
        let recs = PrintAdvisor.recommendations(objects: objects, settings: settings, loadedTypes: loaded)
        XCTAssertFalse(recs.contains { $0.id.hasPrefix("empty-") || $0.id.hasPrefix("mismatch-") }, "\(recs.map(\.id))")
        let job = try SliceJob(name: "Virtueller Testdruck", objects: objects, settings: settings).run()
        XCTAssertGreaterThan(job.estimate.toolChanges, 0)

        // 3. Upload and start, with the slot mapping the app sends.
        let file = "makerslice_virtual_\(Int(Date().timeIntervalSince1970)).gcode"
        let mapping = [0, 2].map { SlotMapping(tool: $0, slot: $0, materialType: settings.filaments[$0].type, color: [255, 255, 255]) }
        try await printer.upload(gcode: Data(job.gcode.utf8), fileName: file, startPrint: true, mapping: mapping)

        // 4. Moonraker understands the file like one from OrcaSlicer.
        let meta = try await metadata(file)
        XCTAssertEqual(meta["layer_count"] as? Int, job.layers.count)
        XCTAssertNotNil(meta["estimated_time"])
        XCTAssertEqual((meta["thumbnails"] as? [Any])?.isEmpty, false, "printer screen preview")
        XCTAssertEqual(meta["filament_type"] as? String, settings.filaments.map(\.type).joined(separator: ";"))

        // 5. Live progress, pause, resume, cancel.
        status = try await waitFor("printing") { $0.state == .printing && $0.progress > 0 }
        XCTAssertEqual(status.fileName, file)
        try await printer.pause()
        status = try await waitFor("paused") { $0.state == .paused }
        let pausedAt = status.progress
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let stillPaused = try await printer.status()
        XCTAssertEqual(stillPaused.progress, pausedAt, accuracy: 0.001, "no progress while paused")
        try await printer.resume()
        status = try await waitFor("resumed") { $0.state == .printing && $0.progress > pausedAt }
        XCTAssertNotNil(status.currentLayer)
        try await printer.cancel()
        status = try await waitFor("cancelled") { $0.state == .cancelled || $0.state == .standby }

        // 6. The file is on the printer and the history knows the job.
        let files = try await printer.files()
        XCTAssertTrue(files.contains { $0.path == file || $0.path.hasSuffix(file) })
        let events = try await printer.recentEvents()
        XCTAssertNotNil(events)

        // 7. Temperatures and light from the app.
        try await printer.setBedTemperature(55)
        _ = try await waitFor("bed target") { abs($0.bed.target - 55) < 0.1 }
        try await printer.setToolTemperature(tool: 1, 200)
        _ = try await waitFor("T2 target") { $0.tools.count > 1 && abs($0.tools[1].target - 200) < 0.1 }
        try await printer.setBedTemperature(0)
        try await printer.setToolTemperature(tool: 1, 0)
    }

    func testPrintRunsToCompletion() async throws {
        let printer = client()
        var status = try await printer.status()
        if status.state == .printing || status.state == .paused {
            try await printer.cancel()
            status = try await waitFor("idle") { $0.state != .printing && $0.state != .paused }
        }
        let settings = PrintSettings(printer: .snapmakerU1)
        let objects = PlateArranger.arrange([ModelObject(name: "Würfel", mesh: box(10, 10, 5))], bedSize: settings.bedSize)!
        let job = try SliceJob(name: "Kurzdruck", objects: objects, settings: settings).run()
        let file = "makerslice_complete_\(Int(Date().timeIntervalSince1970)).gcode"
        try await printer.upload(gcode: Data(job.gcode.utf8), fileName: file, startPrint: true)
        // u1sim runs 600 s jobs; the CI starts it with --speed 40 → ~15 s.
        status = try await waitFor("complete", timeout: 120) { $0.state == .complete }
        XCTAssertEqual(status.progress, 1, accuracy: 0.01)
    }

    func box(_ x: Double, _ y: Double, _ z: Double) -> TriangleMesh {
        let v = [Vec3(0, 0, 0), Vec3(x, 0, 0), Vec3(x, y, 0), Vec3(0, y, 0),
                 Vec3(0, 0, z), Vec3(x, 0, z), Vec3(x, y, z), Vec3(0, y, z)]
        let f: [UInt32] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4,
                           1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7]
        return TriangleMesh(vertices: v, indices: f)
    }
}
