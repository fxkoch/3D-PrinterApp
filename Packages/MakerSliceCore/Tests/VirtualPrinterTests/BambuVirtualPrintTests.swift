import Foundation
import PrinterKit
import SliceKit
import XCTest

/// Virtual prints on a Bambu Lab P1S (tools/virtualprinters/bambu_p1s_sim.py).
/// Set BAMBU_SIM=1 with the simulator running (MQTT :18883, FTPS :18990, state :18884).
final class BambuVirtualPrintTests: XCTestCase {
    private func client(code: String = "12345678") throws -> BambuLANClient {
        guard ProcessInfo.processInfo.environment["BAMBU_SIM"] != nil else { throw XCTSkip("BAMBU_SIM not set") }
        let c = BambuLANClient(connection: PrinterConnection(name: "P1S", host: "127.0.0.1", apiKey: code, model: "bambuP1S", kind: .bambuLAN, serial: "01P00A000000001"))
        c.mqttPort = 18883
        c.ftpsPort = 18990
        return c
    }

    private func box(_ x: Double, _ y: Double, _ z: Double) -> TriangleMesh {
        let v = [Vec3(0, 0, 0), Vec3(x, 0, 0), Vec3(x, y, 0), Vec3(0, y, 0), Vec3(0, 0, z), Vec3(x, 0, z), Vec3(x, y, z), Vec3(0, y, z)]
        let f: [UInt32] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7]
        return TriangleMesh(vertices: v, indices: f)
    }

    private func simState() async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18884/sim/state")!)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func waitFor(_ c: BambuLANClient, _ state: PrinterStatus.JobState, seconds: Double = 12) async throws -> PrinterStatus {
        let end = Date().addingTimeInterval(seconds)
        var s = try await c.status()
        while s.state != state, Date() < end {
            try await Task.sleep(nanoseconds: 300_000_000)
            s = try await c.status()
        }
        return s
    }

    func testStatusShowsAMSAndTemperatures() async throws {
        let c = try client()
        defer { c.disconnect() }
        let s = try await c.status()
        XCTAssertNotEqual(s.state, .printing, "idle, or what the previous test left behind")
        XCTAssertEqual(s.filaments.count, 4)
        XCTAssertEqual(s.filaments[0].type, "PLA")
        XCTAssertEqual(s.filaments[0].color, "#F5F5F0")
        XCTAssertFalse(s.filaments[2].present)
        XCTAssertEqual(s.filamentBox?.humidity, 31)
        XCTAssertEqual(s.firmware, "01.08.02.00")
        XCTAssertNotNil(s.chamber)
    }

    func testWrongAccessCodeIsExplained() async throws {
        let c = try client(code: "00000000")
        do {
            _ = try await c.status()
            XCTFail("must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Zugangscode"), "\(error)")
        }
    }

    func testUploadStartPauseResumeCancel() async throws {
        let c = try client()
        defer { c.disconnect() }
        var settings = PrintSettings(printer: .bambuP1S)
        settings.filaments[0] = FilamentLibrary.defaultFilament(for: .bambuP1S)
        let arranged = try XCTUnwrap(PlateArranger.arrange([ModelObject(name: "Würfel", mesh: box(20, 20, 6))], bedSize: settings.bedSize))
        let out = try SliceJob(name: "würfel", objects: arranged, settings: settings).run()
        _ = try await c.status()
        try await c.upload(gcode: Data(out.gcode.utf8), fileName: "Würfel.gcode", startPrint: true,
                           mapping: [SlotMapping(tool: 0, slot: 0, materialType: "PLA", color: [245, 245, 240])])

        let state = try await simState()
        let uploads = try XCTUnwrap(state["uploads"] as? [String: [String: Any]])
        let upload = try XCTUnwrap(uploads.values.first)
        XCTAssertEqual(upload["valid"] as? Bool, true, "\(upload)")
        XCTAssertEqual((upload["klipper_commands"] as? [String])?.isEmpty, true)
        let start = try XCTUnwrap((state["received"] as? [[String: Any]])?.compactMap { $0["print"] as? [String: Any] }.first { $0["command"] as? String == "project_file" })
        XCTAssertEqual(start["param"] as? String, "Metadata/plate_1.gcode")
        XCTAssertEqual(start["ams_mapping"] as? [Int], [0])
        XCTAssertEqual(start["use_ams"] as? Bool, true)

        var s = try await waitFor(c, .printing)
        XCTAssertEqual(s.state, .printing)
        try await c.pause()
        s = try await waitFor(c, .paused)
        XCTAssertEqual(s.state, .paused)
        XCTAssertNotNil(PrintRecovery.advice(for: s), "a pause gets advice")
        try await c.resume()
        s = try await waitFor(c, .printing)
        XCTAssertEqual(s.state, .printing)
        try await c.cancel()
        s = try await waitFor(c, .cancelled)
        XCTAssertEqual(s.state, .cancelled, "error 0300-400C means cancelled by the user")
    }

    func testLightAndTemperatureCommands() async throws {
        let c = try client()
        defer { c.disconnect() }
        _ = try await c.status()
        try await c.setLight(false)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let s = try await c.status()
        XCTAssertEqual(s.lightOn, false)
        try await c.setBedTemperature(55)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let hot = try await c.status()
        XCTAssertEqual(hot.bed.target, 55)
    }
}
