@testable import PrinterKit
import XCTest

final class PrintRecoveryTests: XCTestCase {
    private func status(_ state: PrinterStatus.JobState, message: String?, progress: Double, nozzle: Double = 210, bed: Double = 60) -> PrinterStatus {
        var s = PrinterStatus()
        s.state = state; s.stateMessage = message; s.progress = progress
        s.tools = [.init(temperature: nozzle, target: nozzle > 100 ? 220 : 0)]
        s.bed = .init(temperature: bed, target: bed > 40 ? 60 : 0)
        return s
    }

    func testNothingToAdviseWhilePrintingOrIdle() {
        XCTAssertNil(PrintRecovery.advice(for: status(.printing, message: nil, progress: 0.4)))
        XCTAssertNil(PrintRecovery.advice(for: status(.standby, message: nil, progress: 0)))
    }

    func testFilamentRunoutMidPrintCanBeResumed() {
        let advice = PrintRecovery.advice(for: status(.paused, message: "Filament runout", progress: 0.4))
        XCTAssertEqual(advice?.verdict, .resume)
        XCTAssertFalse(advice?.steps.isEmpty ?? true)
    }

    func testHeaterFaultIsNeverResumed() {
        XCTAssertEqual(PrintRecovery.advice(for: status(.error, message: "Thermal runaway", progress: 0.9))?.verdict, .discard)
    }

    func testDetachedPartIsDiscarded() {
        XCTAssertEqual(PrintRecovery.advice(for: status(.paused, message: "part detached from bed", progress: 0.5))?.verdict, .discard)
    }

    func testClogDependsOnProgress() {
        XCTAssertEqual(PrintRecovery.advice(for: status(.paused, message: "extruder clog", progress: 0.2))?.verdict, .discard)
        XCTAssertEqual(PrintRecovery.advice(for: status(.paused, message: "extruder clog", progress: 0.8))?.verdict, .checkFirst)
    }

    func testColdPartIsNotResumedBlindly() {
        XCTAssertEqual(PrintRecovery.advice(for: status(.paused, message: nil, progress: 0.4, nozzle: 30, bed: 25))?.verdict, .discard)
        XCTAssertEqual(PrintRecovery.advice(for: status(.paused, message: nil, progress: 0.9, nozzle: 30, bed: 25))?.verdict, .checkFirst)
    }

    func testBarelyStartedPrintIsRestarted() {
        XCTAssertEqual(PrintRecovery.advice(for: status(.paused, message: "Filament runout", progress: 0.02))?.verdict, .discard)
    }

    func testPlainUserPauseCanContinue() {
        XCTAssertEqual(PrintRecovery.advice(for: status(.paused, message: nil, progress: 0.5))?.verdict, .resume)
    }
}
