@testable import SliceKit
import XCTest

final class CalibrationAdviceTests: XCTestCase {
    func testNoGoodTemperatureStepPointsToDryingAndRetraction() {
        let items = CalibrationAdvice.whenNoStepIsGood(.temperature, filamentType: "PETG")
        XCTAssertEqual(items.first?.id, "dry")
        XCTAssertTrue(items.contains { $0.run == .retraction })
        XCTAssertTrue(items.first { $0.id == "dry" }?.detail.contains("PETG") ?? false)
    }

    func testOpenTestsFollowTheOrderAndSkipSavedOnes() {
        let book = CalibrationBook()
        XCTAssertEqual(CalibrationAdvice.open(printer: .kobraS1, filament: "Generic PETG", book: book), CalibrationAdvice.order)
        book.set(CalibrationResult(printer: PrinterModel.kobraS1.rawValue, filament: "Generic PETG", kind: .temperature, value: 235))
        let open = CalibrationAdvice.open(printer: .kobraS1, filament: "Generic PETG", book: book)
        XCTAssertEqual(open.first, .retraction)
        XCTAssertFalse(open.contains(.temperature))
        XCTAssertEqual(CalibrationAdvice.open(printer: .kobraS1, filament: "Other", book: book).first, .temperature, "results are per filament")
    }

    func testEveryKindHasAdvice() {
        for kind in CalibrationKind.allCases { XCTAssertFalse(CalibrationAdvice.whenNoStepIsGood(kind, filamentType: "PLA").isEmpty) }
    }
}
