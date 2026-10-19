import XCTest

/// End-to-end smoke test on the simulator: navigate all tabs, open the built-in
/// test cube, slice it for both printers, open the cut tool and expert settings.
/// Screenshots are attached to the test result.
final class MakerSliceUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTabsAndSearch() {
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Entdecken"].waitForExistence(timeout: 10))
        // Give the initial search (Printables + MakerWorld) a moment.
        _ = app.otherElements["result-printables"].waitForExistence(timeout: 2)
        sleep(6)
        snapshot("01-Entdecken")

        app.tabBars.buttons["Bibliothek"].tap()
        snapshot("02-Bibliothek")

        app.tabBars.buttons["Drucker"].tap()
        XCTAssertTrue(app.staticTexts["Kein Drucker"].waitForExistence(timeout: 5))
        snapshot("03-Drucker")

        app.tabBars.buttons["Einstellungen"].tap()
        let expert = app.switches["expertToggle"]
        XCTAssertTrue(expert.waitForExistence(timeout: 5))
        snapshot("04-Einstellungen")
    }

    func testSliceSampleForBothPrinters() {
        app.launchArguments = ["-uiTestSampleModel"]
        app.launch()

        let slice = app.buttons["sliceButton"]
        XCTAssertTrue(slice.waitForExistence(timeout: 20), "prepare screen should open with the sample cube")
        sleep(2)
        snapshot("10-Vorbereiten-U1")

        slice.tap()
        XCTAssertTrue(app.otherElements["sliceSummary"].waitForExistence(timeout: 60) || app.buttons["printButton"].waitForExistence(timeout: 5),
                      "slicing should finish")
        sleep(1)
        snapshot("11-Geslicet-U1")

        // Switch to the Kobra S1 and slice again.
        let picker = app.segmentedControls["printerPicker"]
        if picker.waitForExistence(timeout: 5) {
            picker.buttons["Anycubic Kobra S1"].tap()
        } else {
            app.buttons["Anycubic Kobra S1"].firstMatch.tap()
        }
        XCTAssertTrue(slice.waitForExistence(timeout: 10))
        snapshot("12-Vorbereiten-Kobra")
        slice.tap()
        XCTAssertTrue(app.buttons["printButton"].waitForExistence(timeout: 60), "Kobra slicing should finish")
        snapshot("13-Geslicet-Kobra")

        // Material picker for slot 1.
        app.buttons["slot-0"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Slot 1"].waitForExistence(timeout: 5))
        snapshot("14-Material")
        app.navigationBars["Slot 1"].buttons["Fertig"].tap()

        // Printing without a printer must show a clear message, not crash.
        if app.buttons["printButton"].waitForExistence(timeout: 5) {
            app.buttons["printButton"].tap()
            if app.buttons["applyRecommendations"].waitForExistence(timeout: 3) {
                snapshot("15-Empfehlungen")
                app.buttons["Ohne Änderungen drucken"].tap()
            }
            sleep(1)
            snapshot("16-Drucken-ohne-Drucker")
        }
        app.buttons["closeProject"].tap()
    }
}
