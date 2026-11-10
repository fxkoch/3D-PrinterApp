@testable import PrinterKit
import XCTest

final class PrintPhaseTests: XCTestCase {
    private func status(_ state: PrinterStatus.JobState, layer: Int? = nil, total: Int? = nil, progress: Double = 0,
                        nozzle: (Double, Double) = (25, 0), bed: (Double, Double) = (25, 0)) -> PrinterStatus {
        var s = PrinterStatus()
        s.state = state
        s.currentLayer = layer
        s.totalLayers = total
        s.progress = progress
        s.tools = [PrinterStatus.Heater(temperature: nozzle.0, target: nozzle.1)]
        s.bed = PrinterStatus.Heater(temperature: bed.0, target: bed.1)
        return s
    }

    func testHeatingBeforeTheFirstLayer() {
        let p = status(.printing, layer: 0, nozzle: (120, 250), bed: (60, 70)).phase
        XCTAssertEqual(p.step, .heating)
        XCTAssertEqual(p.detail, "Bett 60/70 °C · Düse 120/250 °C")
    }

    func testPreparingWhenHotButNotPrintingYet() {
        XCTAssertEqual(status(.printing, layer: 0, nozzle: (250, 250), bed: (70, 70)).phase.step, .preparing)
    }

    func testPrintingShowsLayer() {
        let p = status(.printing, layer: 12, total: 240, progress: 0.05, nozzle: (250, 250), bed: (70, 70)).phase
        XCTAssertEqual(p.step, .printing)
        XCTAssertEqual(p.title, "Druckt Schicht 12 von 240")
        XCTAssertEqual(p.detail, "5 %")
    }

    func testHeatingLaterInThePrintIsStillPrinting() {
        // A short temperature dip mid-print (e.g. filament change) must not look like "heating up".
        XCTAssertEqual(status(.printing, layer: 50, total: 240, progress: 0.2, nozzle: (200, 250)).phase.step, .printing)
    }

    func testPausedCompleteAndIdle() {
        XCTAssertEqual(status(.paused, layer: 5, total: 10).phase.title, "Pausiert")
        XCTAssertEqual(status(.paused, layer: 5, total: 10).phase.detail, "bei Schicht 5 von 10")
        XCTAssertEqual(status(.complete).phase.step, .done)
        XCTAssertNil(status(.standby).phase.step)
    }
}
