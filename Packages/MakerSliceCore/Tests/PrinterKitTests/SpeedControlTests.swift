import XCTest
@testable import PrinterKit

final class SpeedControlTests: XCTestCase {
    func testKlipperSpeedFactorIsReportedInPercent() {
        var s = PrinterStatus()
        s.apply(["gcode_move": ["speed_factor": 0.5]])
        XCTAssertEqual(s.speedPercent, 50)
        XCTAssertNil(s.speedMode)
        XCTAssertTrue(PrinterStatus.queryObjects.contains("gcode_move"))
    }

    func testPresets() {
        XCTAssertEqual(SpeedControl.percentPresets.map(\.percent), [50, 100, 125])
        XCTAssertEqual(SpeedControl.modeNames[1], "Leise")
        XCTAssertTrue(SpeedControl.percentPresets.allSatisfy { SpeedControl.percentRange.contains($0.percent) })
    }
}
