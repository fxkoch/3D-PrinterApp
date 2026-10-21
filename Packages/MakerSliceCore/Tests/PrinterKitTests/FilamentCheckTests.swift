@testable import PrinterKit
import XCTest

final class FilamentCheckTests: XCTestCase {
    private func status(message: String? = nil, state: PrinterStatus.JobState = .paused, slots: [Bool] = [true, true, true, true], active: Int? = 0,
                        nozzle: Double = 210, target: Double = 220, humidity: Double = 30) -> PrinterStatus {
        var s = PrinterStatus()
        s.state = state; s.stateMessage = message
        s.filaments = slots.map { PrinterStatus.LoadedFilament(present: $0, type: $0 ? "PETG" : nil) }
        s.filamentBox = PrinterStatus.FilamentBox(temperature: 24, humidity: humidity, activeSlot: active)
        s.tools = [.init(temperature: nozzle, target: target)]
        return s
    }

    func testAbnormalRetractionMessageIsAProblemAndRecoverable() {
        let s = status(message: "Abnormal filament retraction")
        let check = FilamentCheck.evaluate(s)
        XCTAssertEqual(check.items.first { $0.id == "message" }?.level, .problem)
        XCTAssertEqual(check.overall, .problem)
        XCTAssertTrue(FilamentCheck.isFilamentMessage(s.stateMessage))
        let advice = PrintRecovery.advice(for: { var x = s; x.progress = 0.4; return x }())
        XCTAssertEqual(advice?.verdict, .resume)
        XCTAssertTrue(advice?.reasons.contains { $0.contains("zurückgezogen") } ?? false)
    }

    func testHealthyIdlePrinterIsAllGreen() {
        let check = FilamentCheck.evaluate(status(state: .standby, nozzle: 200, target: 200))
        XCTAssertEqual(check.overall, .ok, "\(check.items)")
    }

    func testEmptyActiveSlotAndMoistureAreFlagged() {
        let check = FilamentCheck.evaluate(status(slots: [false, true, true, true], active: 0, humidity: 55), expectedType: "PETG")
        XCTAssertEqual(check.items.first { $0.id == "active" }?.level, .problem)
        XCTAssertEqual(check.items.first { $0.id == "humidity" }?.level, .warning)
    }

    func testWrongMaterialInSlotWarns() {
        var s = status(state: .standby)
        s.filaments[0].type = "PLA"
        XCTAssertEqual(FilamentCheck.evaluate(s, expectedType: "PETG").items.first { $0.id == "active" }?.level, .warning)
    }

    func testColdNozzleIsNotAProblemButSaysSo() {
        let item = FilamentCheck.evaluate(status(state: .standby, nozzle: 30, target: 0)).items.first { $0.id == "nozzle" }
        XCTAssertEqual(item?.level, .unknown)
    }

    func testPrinterMessagesInTheLogCount() {
        let check = FilamentCheck.evaluate(status(state: .standby), messages: ["Slot 2: Filament clog detected"])
        XCTAssertEqual(check.items.first { $0.id == "message" }?.level, .problem)
    }

    func testStepsAreComplete() {
        XCTAssertGreaterThanOrEqual(FilamentCheck.steps.count, 6)
    }
}
