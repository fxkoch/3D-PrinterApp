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
