@testable import SliceKit
import XCTest

final class CalibrationTests: XCTestCase {
    private func slice(_ plan: CalibrationPlan) throws -> SliceJob.Output {
        let arranged = try XCTUnwrap(PlateArranger.arrange([plan.object], bedSize: plan.settings.bedSize))
        return try SliceJob(name: plan.name, objects: arranged, settings: plan.settings).run()
    }

    private func petg(_ printer: PrinterModel) -> (Filament, PrintSettings) {
        let f = FilamentLibrary.bestMatch(type: "PETG", printer: printer) ?? .petg
        return (f, PrintSettings(printer: printer))
    }

    func testTemperatureTowerStepsAndCommands() throws {
        let (f, base) = petg(.snapmakerU1)
        let plan = CalibrationFactory.plan(.temperature, filament: f, base: base)
        XCTAssertEqual(plan.steps.count, 7)
        XCTAssertEqual(plan.steps[0].value - plan.steps[6].value, 30, "5 °C steps over seven segments")
        XCTAssertEqual(plan.steps.map(\.zFrom), [0, 8, 16, 24, 32, 40, 48])
        XCTAssertEqual(plan.settings.filaments[0].nozzleTemp, Int(plan.steps[0].value))
        let output = try slice(plan)
        let temps = output.gcode.split(separator: "\n").filter { $0.hasPrefix("M104 S") && !$0.hasPrefix("M104 S0") }
        XCTAssertTrue(temps.contains("M104 S\(Int(plan.steps[3].value))"), "the tower changes to the fourth temperature")
        XCTAssertTrue(output.gcode.contains("M104 S0\n"), "footer switches the nozzle off")
        // Layers above the last change carry the lowest temperature.
        XCTAssertEqual(plan.step(atHeight: 50)?.value, plan.steps[6].value)
    }

    func testFlowStaircaseUsesM221AndResetsIt() throws {
        let (f, base) = petg(.kobraS1)
        let plan = CalibrationFactory.plan(.flow, filament: f, base: base)
        XCTAssertEqual(plan.steps.count, 9)
        XCTAssertEqual(plan.steps[4].value, f.flowRatio, accuracy: 0.0006, "the middle step is the current profile")
        let gcode = try slice(plan).gcode
        XCTAssertTrue(gcode.contains("M221 S92"))
        XCTAssertTrue(gcode.contains("M221 S108"))
        XCTAssertTrue(gcode.hasSuffix("") && gcode.contains("M221 S100"), "the flow factor is reset at the end")
    }

    func testPressureAdvanceTower() throws {
        let (f, base) = petg(.snapmakerU1)
        let plan = CalibrationFactory.plan(.pressureAdvance, filament: f, base: base)
        XCTAssertEqual(plan.steps.count, 13)
        XCTAssertEqual(plan.steps.last?.value ?? 0, 0.06, accuracy: 1e-9)
        let gcode = try slice(plan).gcode
        XCTAssertTrue(gcode.contains("SET_PRESSURE_ADVANCE ADVANCE=0.030"))
        XCTAssertTrue(gcode.contains("SET_PRESSURE_ADVANCE ADVANCE=0.060"))
    }

    func testRetractionTowerChangesTheRetractLengthPerHeight() throws {
        let (f, base) = petg(.snapmakerU1)
        let plan = CalibrationFactory.plan(.retraction, filament: f, base: base)
        let gcode = try slice(plan).gcode
        let lengths = Set(gcode.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("G1 E-"), !line.contains("X") else { return nil }
            return String(line.dropFirst(5).prefix { $0.isNumber || $0 == "." })
        })
        XCTAssertTrue(lengths.contains("0.2"), "\(lengths)")
        XCTAssertTrue(lengths.contains("1.6"), "\(lengths)")
        XCTAssertGreaterThan(lengths.count, 5, "every height uses its own length")
    }

    func testMaxFlowTowerRampsTheSpeed() throws {
        let (f, base) = petg(.kobraS1)
        let plan = CalibrationFactory.plan(.maxFlow, filament: f, base: base)
        XCTAssertEqual(plan.steps.count, 11)
        XCTAssertEqual(plan.steps.last?.value ?? 0, 22.1, accuracy: 0.05, "26 mm³/s minus the 15 % margin")
        let gcode = try slice(plan).gcode
        XCTAssertTrue(gcode.contains("M220 S433"), "26 / 6 of the base speed")
        XCTAssertTrue(gcode.contains("M220 S100"))
    }

    func testResultsChangeTheLibraryProfileForThatPrinterOnly() {
        let book = CalibrationBook.shared
        defer { for r in book.all { book.remove(r) } }
        let base = FilamentLibrary.bestMatch(type: "PETG", printer: .snapmakerU1)!
        book.set(CalibrationResult(printer: PrinterModel.snapmakerU1.rawValue, filament: base.name, kind: .temperature, value: 237))
        book.set(CalibrationResult(printer: PrinterModel.snapmakerU1.rawValue, filament: base.name, kind: .flow, value: 0.961))
        book.set(CalibrationResult(printer: PrinterModel.snapmakerU1.rawValue, filament: base.name, kind: .pressureAdvance, value: 0.034))
        let again = FilamentLibrary.bestMatch(type: "PETG", printer: .snapmakerU1)!
        XCTAssertEqual(again.nozzleTemp, 237)
        XCTAssertEqual(again.flowRatio, 0.961, accuracy: 1e-9)
        XCTAssertEqual(again.pressureAdvance ?? 0, 0.034, accuracy: 1e-9)
        XCTAssertEqual(again.calibratedKinds, ["flow", "pressureAdvance", "temperature"])
        // A different printer keeps the library values.
        let other = FilamentLibrary.bestMatch(type: "PETG", printer: .kobraS1)!
        XCTAssertNil(other.calibratedKinds)
    }

    func testMergeKeepsTheNewerResult() {
        let book = CalibrationBook()
        let old = CalibrationResult(printer: "u1", filament: "X", kind: .flow, value: 0.95, date: Date(timeIntervalSince1970: 1000))
        let newer = CalibrationResult(printer: "u1", filament: "X", kind: .flow, value: 0.97, date: Date(timeIntervalSince1970: 2000))
        book.set(old)
        XCTAssertEqual(book.merge([newer]), 1)
        XCTAssertEqual(book.all.first?.value, 0.97)
        XCTAssertEqual(book.merge([old]), 0, "an older result does not replace a newer one")
        let data = CalibrationBook.encode(book.all)!
        XCTAssertEqual(CalibrationBook.decode(data), book.all)
    }
}
