@testable import PrinterKit
import XCTest

final class DryingAdviceTests: XCTestCase {
    func testPETGInADryerLimitedTo55() throws {
        let plan = try XCTUnwrap(DryingAdvice.plan(types: ["PETG", "PETG", "PETG", "PETG"]))
        XCTAssertEqual(plan.temperature, 55, "the dryer's maximum, PETG would take more")
        XCTAssertNil(plan.limitedBy)
        XCTAssertGreaterThan(plan.minutes, 6 * 60, "longer than at 65 °C")
        XCTAssertEqual(plan.types, ["PETG"])
    }

    func testPLAAmongOthersSetsTheTemperatureForAll() throws {
        let plan = try XCTUnwrap(DryingAdvice.plan(types: ["PLA", "PETG", "PETG", ""]))
        XCTAssertEqual(plan.temperature, 50, "PLA does not take more")
        XCTAssertEqual(plan.limitedBy, "PLA")
        XCTAssertEqual(plan.types, ["PLA", "PETG"])
        XCTAssertGreaterThanOrEqual(plan.minutes, 7 * 60, "PETG needs longer at 50 °C")
    }

    func testTPUOrPVALowersItFurtherAndNylonTakesLonger() throws {
        XCTAssertEqual(DryingAdvice.plan(types: ["PETG", "TPU"])?.temperature, 45)
        XCTAssertEqual(DryingAdvice.plan(types: ["PA-CF"])?.temperature, 55)
        XCTAssertGreaterThanOrEqual(DryingAdvice.plan(types: ["PA"])?.minutes ?? 0, 10 * 60)
    }

    func testNothingLoadedGivesNoPlan() {
        XCTAssertNil(DryingAdvice.plan(types: ["", "NONE"]))
        XCTAssertNil(DryingAdvice.plan(types: []))
    }

    func testSummaryReadsNaturally() throws {
        let plan = try XCTUnwrap(DryingAdvice.plan(types: ["PLA"]))
        XCTAssertEqual(plan.summary, "50 °C, 6 h")
        XCTAssertTrue(plan.explanation.contains("PLA"))
    }
}
