import XCTest
@testable import SliceKit

final class FilamentSetupTests: XCTestCase {
    private func otherPETG() throws -> Filament {
        try XCTUnwrap(FilamentLibrary.all.map(\.filament).first { $0.type == "PETG" && $0.name != "Generic PETG" })
    }

    /// OrcaSlicer's order; the U1 measures PA only when its dynamic flow calibration is switched on for a job, which
    /// prints started by the app do not do.
    func testNewFilamentNeedsTemperaturePressureAdvanceAndFlow() throws {
        let book = CalibrationBook()
        for printer in PrinterModel.allCases {
            let plan = FilamentSetup.plan(for: try otherPETG(), printer: printer, book: book)
            XCTAssertEqual(plan.steps.filter { $0.onlyIf == nil }.map(\.kind), [.temperature, .pressureAdvance, .flow], printer.rawValue)
            XCTAssertEqual(plan.steps.filter { $0.onlyIf != nil }.map(\.kind), [.maxFlow, .retraction])
        }
    }

    func testHandEnteredValuesDoNotCountAsCalibrated() throws {
        let book = CalibrationBook()
        let f = try otherPETG()
        book.set(CalibrationResult(printer: PrinterModel.snapmakerU1.rawValue, filament: f.name, kind: .temperature, value: 235, source: "manual"))
        XCTAssertTrue(FilamentSetup.plan(for: f, printer: .snapmakerU1, book: book).steps.contains { $0.kind == .temperature })
        XCTAssertTrue(CalibrationAdvice.open(printer: .snapmakerU1, filament: f.name, book: book).contains(.temperature))
    }

    func testStartsFromACalibratedFilamentOfTheSameType() throws {
        let book = CalibrationBook()
        book.set(CalibrationResult(printer: PrinterModel.snapmakerU1.rawValue, filament: "Generic PETG", kind: .temperature, value: 240))
        book.set(CalibrationResult(printer: PrinterModel.snapmakerU1.rawValue, filament: "Generic PETG", kind: .retraction, value: 0.6))
        book.set(CalibrationResult(printer: PrinterModel.kobraS1.rawValue, filament: "Generic PETG", kind: .flow, value: 0.9)) // other printer
        book.set(CalibrationResult(printer: PrinterModel.snapmakerU1.rawValue, filament: "Generic PLA", kind: .flow, value: 0.9)) // other type
        let plan = FilamentSetup.plan(for: try otherPETG(), printer: .snapmakerU1, book: book)
        XCTAssertEqual(plan.filament.nozzleTemp, 240, "the tower is centred on the known value")
        XCTAssertEqual(plan.filament.retractLength, 0.6)
        XCTAssertEqual(Set(plan.seeds.map(\.kind)), [.temperature, .retraction])
        XCTAssertTrue(plan.steps.contains { $0.kind == .temperature }, "seeds are only a start: the test still runs")
    }

    func testCalibratedValuesAreSkipped() throws {
        let book = CalibrationBook()
        let f = try otherPETG()
        book.set(CalibrationResult(printer: PrinterModel.snapmakerU1.rawValue, filament: f.name, kind: .temperature, value: 235))
        let plan = FilamentSetup.plan(for: f, printer: .snapmakerU1, book: book)
        XCTAssertFalse(plan.steps.contains { $0.kind == .temperature })
        XCTAssertTrue(plan.skipped.contains { $0.kind == .temperature && $0.reason.contains("235") })
        XCTAssertEqual(plan.filament.nozzleTemp, 235)
    }
}
