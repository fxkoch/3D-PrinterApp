import Foundation
@testable import PrinterKit
import XCTest

final class PrinterKitTests: XCTestCase {
    func testBaseURL() {
        XCTAssertEqual(PrinterConnection(name: "U1", host: "192.168.1.50").baseURL?.absoluteString, "http://192.168.1.50:7125")
        XCTAssertEqual(PrinterConnection(name: "U1", host: "u1.local:80").baseURL?.absoluteString, "http://u1.local:80")
        XCTAssertEqual(PrinterConnection(name: "U1", host: " http://10.0.0.2 ").baseURL?.absoluteString, "http://10.0.0.2:7125")
        XCTAssertNil(PrinterConnection(name: "U1", host: "").baseURL)
    }

    func testSanitizeFileName() {
        XCTAssertEqual(MoonrakerClient.sanitize("Würfel/Test"), "W_rfel_Test.gcode")
        XCTAssertEqual(MoonrakerClient.sanitize("cube.gcode"), "cube.gcode")
    }

    func testParseStatus() throws {
        let json = """
        {"print_stats": {"state": "printing", "filename": "cube.gcode", "print_duration": 600, "message": "",
                         "info": {"current_layer": 10, "total_layer": 50}},
         "display_status": {"progress": 0.25},
         "heater_bed": {"temperature": 59.8, "target": 60},
         "extruder": {"temperature": 219.5, "target": 220},
         "extruder2": {"temperature": 25, "target": 0},
         "toolhead": {"extruder": "extruder2", "position": [1, 2, 3, 4]},
         "print_task_config": {"filament_exist": [true, false, true, false],
                               "filament_vendor": ["Snapmaker", "NONE", "Generic", "NONE"],
                               "filament_type": ["PLA", "NONE", "PETG", "NONE"],
                               "filament_sub_type": ["SnapSpeed", "NONE", "NONE", "NONE"],
                               "filament_color_rgba": ["FF0000FF", "FFFFFFFF", "00FF00FF", "FFFFFFFF"]}}
        """
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        var s = PrinterStatus()
        s.apply(dict)
        XCTAssertEqual(s.state, .printing)
        XCTAssertEqual(s.progress, 0.25)
        XCTAssertEqual(s.currentLayer, 10)
        XCTAssertEqual(s.tools.count, 3)
        XCTAssertEqual(s.tools[0].target, 220)
        XCTAssertEqual(s.activeTool, 2)
        XCTAssertEqual(s.remainingSeconds ?? 0, 1800, accuracy: 0.1)
        XCTAssertEqual(s.filaments.count, 4)
        XCTAssertEqual(s.filaments[0].displayName, "Snapmaker PLA SnapSpeed")
        XCTAssertEqual(s.filaments[0].color, "#FF0000")
        XCTAssertFalse(s.filaments[1].present)
        XCTAssertEqual(s.filaments[1].displayName, "Leer")
    }
}
