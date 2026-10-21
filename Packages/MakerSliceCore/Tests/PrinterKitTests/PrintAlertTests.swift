@testable import PrinterKit
import XCTest

final class PrintAlertTests: XCTestCase {
    private func status(_ state: PrinterStatus.JobState, message: String? = nil) -> PrinterStatus {
        var s = PrinterStatus()
        s.state = state; s.stateMessage = message; s.fileName = "Turm.gcode"
        return s
    }

    func testNothingForUnchangedOrFirstSight() {
        XCTAssertNil(PrintAlert.alert(printer: "Kobra", old: .printing, new: status(.printing)))
        XCTAssertNil(PrintAlert.alert(printer: "Kobra", old: nil, new: status(.complete)), "no alert for something seen for the first time")
    }

    func testFinishedFailedPausedCancelled() {
        XCTAssertEqual(PrintAlert.alert(printer: "Kobra", old: .printing, new: status(.complete))?.kind, .finished)
        XCTAssertEqual(PrintAlert.alert(printer: "Kobra", old: .printing, new: status(.error, message: "Thermal runaway"))?.kind, .failed)
        XCTAssertEqual(PrintAlert.alert(printer: "Kobra", old: .printing, new: status(.paused))?.kind, .paused)
        XCTAssertEqual(PrintAlert.alert(printer: "Kobra", old: .paused, new: status(.cancelled))?.kind, .cancelled)
        XCTAssertNil(PrintAlert.alert(printer: "Kobra", old: .standby, new: status(.printing)), "starting a print is no alert")
        XCTAssertNil(PrintAlert.alert(printer: "Kobra", old: .complete, new: status(.standby)))
    }

    func testFilamentProblemsGetTheirOwnKind() {
        let a = PrintAlert.alert(printer: "Kobra", old: .printing, new: status(.paused, message: "Abnormal filament retraction"))
        XCTAssertEqual(a?.kind, .filament)
        XCTAssertTrue(a?.title.contains("Filamentproblem") ?? false)
        XCTAssertEqual(PrintAlert.alert(printer: "P1S", old: .printing, new: status(.error, message: "AMS filament runout"))?.kind, .filament)
    }

    func testKeyIsStablePerEvent() {
        let a = PrintAlert.alert(printer: "Kobra", old: .printing, new: status(.complete))
        let b = PrintAlert.alert(printer: "Kobra", old: .paused, new: status(.complete))
        XCTAssertEqual(a?.key, b?.key, "the same job finishing is one event")
    }
}
