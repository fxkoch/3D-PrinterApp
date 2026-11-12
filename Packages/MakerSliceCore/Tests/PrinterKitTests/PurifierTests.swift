import XCTest
@testable import PrinterKit

final class PurifierTests: XCTestCase {
    func testTopCoverFansAreParsed() {
        var s = PrinterStatus()
        s.apply(["purifier": ["power_detected": true, "mode": 1, "inner_fan_work_time": 325464.9, "inner_fan_rpm": 1500.0,
                              "exhaust_fan": ["speed": 0.3], "inner_fan": ["speed": 0.35]] as [String: Any]])
        XCTAssertEqual(s.purifier?.innerSpeed, 0.35)
        XCTAssertEqual(s.purifier?.exhaustSpeed, 0.3)
        XCTAssertEqual(s.purifier?.mode, "Abluft (kühlt die Kammer)")
        XCTAssertEqual(try XCTUnwrap(s.purifier).innerHours, 90.4, accuracy: 0.1)
    }

    func testNoTopCoverNoPanel() {
        var s = PrinterStatus()
        s.apply(["purifier": ["power_detected": false, "mode": 0] as [String: Any]])
        XCTAssertNil(s.purifier)
    }
}
