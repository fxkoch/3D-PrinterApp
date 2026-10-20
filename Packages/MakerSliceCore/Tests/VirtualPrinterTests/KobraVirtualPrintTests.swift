import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PrinterKit
import SliceKit
import XCTest

/// Virtual prints on an Anycubic Kobra S1 with ACE Pro (tools/virtualprinters/kobra_s1_sim.py):
/// LAN handshake with real signature and AES, MQTT over TLS, upload, start with ACE slot mapping.
/// Set KOBRA_HOST=127.0.0.1 with the simulator running.
final class KobraVirtualPrintTests: XCTestCase {
    var host: String!

    override func setUpWithError() throws {
        guard let h = ProcessInfo.processInfo.environment["KOBRA_HOST"] else { throw XCTSkip("KOBRA_HOST not set") }
        host = h
    }

    func simState() async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://\(host!):18910/sim/state")!)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testLANHandshake() async throws {
        let creds = try await AnycubicHandshake.perform(host: host)
        XCTAssertEqual(creds.host, "127.0.0.1")
        XCTAssertEqual(creds.port, 9883)
        XCTAssertEqual(creds.modelID, 20025)
        XCTAssertEqual(creds.deviceID.count, 32)
        XCTAssertFalse(creds.password.isEmpty)
    }

    #if canImport(Network)
    func waitFor(_ client: AnycubicLANClient, _ what: String, timeout: Double = 30,
                 _ condition: (PrinterStatus) -> Bool) async throws -> PrinterStatus {
        let deadline = Date().addingTimeInterval(timeout)
        var last: PrinterStatus?
        while Date() < deadline {
            let s = try await client.status()
            if condition(s) { return s }
            last = s
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        XCTFail("Timeout waiting for \(what); last \(String(describing: last?.state)) \(last?.progress ?? -1)")
        throw CancellationError()
    }

    func testFullVirtualPrintWithACE() async throws {
        let client = AnycubicLANClient(connection: PrinterConnection(name: "Virtueller Kobra S1", host: host,
                                                                     model: PrinterModel.kobraS1.rawValue, kind: .anycubicLAN))
        defer { client.disconnect() }

        // 1. Live data incl. the four ACE slots and humidity.
        var status = try await waitFor(client, "ACE data") { $0.filaments.count == 4 && $0.filamentBox?.humidity != nil }
        XCTAssertEqual(status.filaments.map(\.type), ["PLA", "PLA", "PETG", nil])
        XCTAssertFalse(status.filaments[3].present)
        XCTAssertEqual(status.filamentBox?.humidity ?? 0, 46, accuracy: 5)
        XCTAssertEqual(status.state, .standby)

        // 2. Two colours: slot 1 (white PLA) and slot 3 (red PETG) – advisor flags PETG/humidity sensibly.
        var settings = PrintSettings(printer: .kobraS1)
        settings.filaments[0] = FilamentLibrary.bestMatch(type: "PLA", printer: .kobraS1)!
        settings.filaments[1] = FilamentLibrary.bestMatch(type: "PETG", printer: .kobraS1)!
        let objects = PlateArranger.arrange([
            ModelObject(name: "Teil A", mesh: box(25, 25, 4), tool: 0),
            ModelObject(name: "Teil B", mesh: box(15, 15, 4), tool: 1),
        ], bedSize: settings.bedSize)!
        let advice = PrintAdvisor.recommendations(objects: objects, settings: settings,
                                                  loadedTypes: ["PLA", "PETG"], dryerHumidity: status.filamentBox?.humidity)
        XCTAssertTrue(advice.contains { $0.id == "ace-humid" }, "\(advice.map(\.id))")
        let job = try SliceJob(name: "Kobra Testdruck", objects: objects, settings: settings).run()
        XCTAssertTrue(job.gcode.contains("G9111"))

        // 3. Upload + start with the ACE mapping (model slot → ACE slot).
        let mapping = [SlotMapping(tool: 0, slot: 0, materialType: "PLA", color: [245, 245, 240]),
                       SlotMapping(tool: 1, slot: 2, materialType: "PETG", color: [210, 40, 40])]
        let file = "makerslice_kobra_\(Int(Date().timeIntervalSince1970)).gcode"
        try await client.upload(gcode: Data(job.gcode.utf8), fileName: file, startPrint: true, mapping: mapping)

        var sim = try await simState()
        let files = try XCTUnwrap(sim["files"] as? [String: Any])
        let analysis = try XCTUnwrap((files[file] as? [String: Any])?["analysis"] as? [String: Any])
        XCTAssertEqual(analysis["problems"] as? [String], [], "the simulator's G-code check")
        XCTAssertEqual(analysis["layers"] as? Int, job.layers.count)
        let sent = try XCTUnwrap((sim["task"] as? [String: Any])?["mapping"] as? [[String: Any]])
        XCTAssertEqual(sent.map { $0["ams_index"] as? Int }, [0, 2])
        XCTAssertEqual(sent.map { $0["material_type"] as? String }, ["PLA", "PETG"])

        // 4. Progress, pause, resume, stop.
        status = try await waitFor(client, "printing") { $0.state == .printing && $0.progress > 0 && $0.currentLayer != nil }
        XCTAssertEqual(status.fileName, file)
        XCTAssertEqual(status.totalLayers, job.layers.count)
        try await client.pause()
        status = try await waitFor(client, "paused") { $0.state == .paused }
        try await client.resume()
        status = try await waitFor(client, "resumed") { $0.state == .printing }
        try await client.cancel()
        status = try await waitFor(client, "stopped") { $0.state == .cancelled || $0.state == .standby }

        // 5. Drying, light, temperatures.
        try await client.setDrying(true, temperature: 50, minutes: 360)
        status = try await waitFor(client, "drying") { $0.filamentBox?.drying == true }
        try await client.setDrying(false)
        try await client.setLight(false)
        _ = try await waitFor(client, "light off") { $0.lightOn == false }
        try await client.setBedTemperature(60)
        _ = try await waitFor(client, "bed target") { abs($0.bed.target - 60) < 0.5 }
        try await client.setBedTemperature(0)
        sim = try await simState()
        XCTAssertEqual(sim["light"] as? Bool, false)
        let events = try await client.recentEvents()
        XCTAssertTrue(events.contains { $0.message.contains("gestartet") })
    }

    func testPrintRunsToCompletion() async throws {
        let client = AnycubicLANClient(connection: PrinterConnection(name: "Virtueller Kobra S1", host: host,
                                                                     model: PrinterModel.kobraS1.rawValue, kind: .anycubicLAN))
        defer { client.disconnect() }
        let settings = PrintSettings(printer: .kobraS1)
        let objects = PlateArranger.arrange([ModelObject(name: "Würfel", mesh: box(10, 10, 4))], bedSize: settings.bedSize)!
        let job = try SliceJob(name: "Kurz", objects: objects, settings: settings).run()
        _ = try await waitFor(client, "idle") { $0.state != .printing && $0.state != .paused }
        try await client.upload(gcode: Data(job.gcode.utf8), fileName: "makerslice_short.gcode", startPrint: true,
                                mapping: [SlotMapping(tool: 0, slot: 0, materialType: "PLA", color: [255, 255, 255])])
        // The CI simulates prints of 10–30 min at ×30 speed → 20–60 s.
        let done = try await waitFor(client, "finished", timeout: 120) { $0.state == .complete }
        XCTAssertEqual(done.fileName, "makerslice_short.gcode")
    }
    #endif

    func box(_ x: Double, _ y: Double, _ z: Double) -> TriangleMesh {
        let v = [Vec3(0, 0, 0), Vec3(x, 0, 0), Vec3(x, y, 0), Vec3(0, y, 0),
                 Vec3(0, 0, z), Vec3(x, 0, z), Vec3(x, y, z), Vec3(0, y, z)]
        let f: [UInt32] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4,
                           1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7]
        return TriangleMesh(vertices: v, indices: f)
    }
}
