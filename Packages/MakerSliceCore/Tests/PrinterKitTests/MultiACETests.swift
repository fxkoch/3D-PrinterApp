import XCTest
@testable import PrinterKit

final class MultiACETests: XCTestCase {
    /// Trimmed from a real U1 (software 2.1.0) with multiACE v1.27b and an ACE Pro 2, mode "multi".
    private let aceObject: [String: Any] = [
        "mode": "multi", "swap_in_progress": false,
        "head_source": [
            "0": NSNull(),
            "1": ["ace_index": 0, "slot": 1, "type": "PETG", "subtype": "", "color": "A9754F", "brand": ""],
            "2": ["ace_index": 0, "slot": 2, "type": "PLA", "subtype": "Basic", "color": "E8DCC0", "brand": "Generic"],
            "3": ["ace_index": 0, "slot": 3, "type": "PETG", "subtype": "Basic", "color": "000000", "brand": "Generic"],
        ],
        "aces": [[
            "idx": 0, "connected": true, "model": "ACE 2 Pro", "temp": 51, "gate_status": [0, 1, 1], "humidity": 22, "humidity_effective": 22.0,
            "dryer_status": ["status": "keeping", "target_temp": 50, "duration": 14400, "remain_time": 9731],
            "slots": [
                ["index": 0, "status": "unknown", "material": "", "color": [0, 0, 0]],
                ["index": 1, "status": "ready", "material": "PETG", "color": [169, 117, 79]],
                ["index": 2, "status": "unknown", "material": "", "color": [0, 0, 0]],
            ],
        ]],
    ]

    func testParsesUnitsAndHeads() {
        var s = PrinterStatus()
        s.apply(["ace": aceObject])
        let ace = try! XCTUnwrap(s.ace)
        XCTAssertEqual(ace.mode, "multi")
        XCTAssertTrue(ace.isMultiMode)
        XCTAssertEqual(ace.units.count, 1)
        XCTAssertEqual(ace.units[0].model, "ACE 2 Pro")
        XCTAssertEqual(ace.units[0].humidity, 22)
        XCTAssertEqual(ace.units[0].slots[1].color, "#A9754F")
        XCTAssertFalse(ace.units[0].slots[0].present)
        // A spool without RFID chip: the gate sensor sees it, but no material is reported.
        XCTAssertTrue(ace.units[0].slots[2].present)
        XCTAssertNil(ace.units[0].slots[2].material)
        XCTAssertNil(ace.headSlots[0])
        XCTAssertEqual(ace.headSlots[2]?.material, "PLA Basic")
    }

    func testHeadSourcesBecomeLoadedFilaments() {
        var s = PrinterStatus()
        s.apply(["ace": aceObject])
        XCTAssertEqual(s.filaments.count, 4)
        XCTAssertFalse(s.filaments[0].present)
        XCTAssertEqual(s.filaments[1].type, "PETG")
        XCTAssertEqual(s.filaments[1].color, "#A9754F")
        XCTAssertEqual(s.filaments[2].subType, "Basic")
        XCTAssertEqual(s.filaments[3].color, "#000000")
    }

    func testDryerBecomesFilamentBox() {
        var s = PrinterStatus()
        s.apply(["ace": aceObject])
        let box = try! XCTUnwrap(s.filamentBox)
        XCTAssertTrue(box.drying)
        XCTAssertEqual(box.dryingTarget, 50)
        XCTAssertEqual(box.humidity, 22)
        XCTAssertEqual(Int(box.dryingRemainingMinutes ?? 0), 162)
    }

    func testPrinterWithoutACEStaysUntouched() {
        var s = PrinterStatus()
        s.apply(["print_stats": ["state": "standby"]])
        XCTAssertNil(s.ace)
        XCTAssertNil(s.filamentBox)
        XCTAssertTrue(PrinterStatus.queryObjects.contains("ace"))
    }

    func testCommands() {
        XCTAssertEqual(MultiACECommand.load(head: 2), "ACE_LOAD_HEAD HEAD=2")
        XCTAssertEqual(MultiACECommand.unload(head: 0), "ACE_UNLOAD_HEAD HEAD=0")
        XCTAssertEqual(MultiACECommand.startDrying(unit: 0, temperature: 55, minutes: 300), "ACE_DRY ACE=0 TEMP=55 DURATION=300")
        XCTAssertEqual(MultiACECommand.startDrying(unit: 1, temperature: 50, minutes: 240), "ACE_DRY ACE=1 TEMP=50 DURATION=240")
        XCTAssertEqual(MultiACECommand.maxDryingTemperature(kind: "v1"), 55)
        XCTAssertEqual(MultiACECommand.maxDryingTemperature(kind: "v2"), 65)
        XCTAssertEqual(MultiACECommand.maxDryingTemperature(kind: nil), 55)
        XCTAssertEqual(MultiACECommand.stopDrying(unit: 1), "ACE_STOP_DRYING ACE=1")
    }
}

final class BambuAMSStatusTests: XCTestCase {
    func testClassicAMSHumidityLevelAndNoFixedActiveSlot() {
        var s = PrinterStatus()
        s.applyBambu(["nozzle_temper": 210, "nozzle_target_temper": 220,
                      "ams": ["tray_now": "255", "ams": [["id": "0", "humidity": "2", "tray": [["id": "0", "tray_type": "PLA", "tray_color": "FF0000FF"]]]]]])
        XCTAssertEqual(s.filamentBox?.humidity, 70, "level 2 = 60–80 %")
        XCTAssertNil(s.activeTool, "one nozzle: no tool number")
        XCTAssertNil(s.filamentBox?.activeSlot, "255 = nothing loaded")
        s.applyBambu(["ams": ["ams": [["id": "0", "humidity_raw": "34", "tray": [] as [[String: Any]]]]]])
        XCTAssertEqual(s.filamentBox?.humidity, 34, "AMS 2 Pro reports %")
    }
}


/// Stand-in for the multiACE web backend's preflight inbox.
final class FakeMultiACEInbox: URLProtocol {
    nonisolated(unsafe) static var requests: [(method: String, url: URL, bytes: Int)] = []
    nonisolated(unsafe) static var probeStatus = 200
    nonisolated(unsafe) static var postStatus = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var bytes = request.httpBody?.count ?? 0
        if bytes == 0, let stream = request.httpBodyStream {
            stream.open(); var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes += n }
            stream.close()
        }
        Self.requests.append((request.httpMethod ?? "GET", request.url!, bytes))
        let code = request.httpMethod == "POST" ? Self.postStatus : Self.probeStatus
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true,"pending":false}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class MultiACEInboxTests: XCTestCase {
    private func client() -> MoonrakerClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeMultiACEInbox.self]
        return MoonrakerClient(connection: PrinterConnection(name: "U1", host: "192.168.1.50"), session: URLSession(configuration: config))
    }

    func testSendsTheFileToTheInboxOnTheWebPort() async throws {
        FakeMultiACEInbox.requests = []; FakeMultiACEInbox.probeStatus = 200; FakeMultiACEInbox.postStatus = 200
        try await client().sendToMultiACE(gcode: Data("G1 X1\n".utf8), fileName: "Zwiebel.gcode")
        XCTAssertEqual(FakeMultiACEInbox.requests.map(\.method), ["GET", "POST"])
        let post = try XCTUnwrap(FakeMultiACEInbox.requests.last)
        XCTAssertEqual(post.url.absoluteString, "http://192.168.1.50/multiace/api/preflight/inbox")
        XCTAssertGreaterThan(post.bytes, 6)
    }

    func testOldMultiACEIsReportedNotUploaded() async {
        FakeMultiACEInbox.requests = []; FakeMultiACEInbox.probeStatus = 404
        do {
            try await client().sendToMultiACE(gcode: Data("G1".utf8), fileName: "a.gcode")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("0.99.8b"))
        }
        XCTAssertEqual(FakeMultiACEInbox.requests.map(\.method), ["GET"], "nothing is uploaded")
    }

    func testAlreadyProcessedFileIsExplained() async {
        FakeMultiACEInbox.requests = []; FakeMultiACEInbox.probeStatus = 200; FakeMultiACEInbox.postStatus = 409
        do {
            try await client().sendToMultiACE(gcode: Data("G1".utf8), fileName: "a.gcode")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("neu slicen"))
        }
    }
}
