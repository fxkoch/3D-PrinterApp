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
        sleep(1)
        snapshot("02-Bibliothek")

        app.tabBars.buttons["Drucker"].tap()
        sleep(1)
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

    /// Search Printables, open a model, download a file and slice it – the full "find & print" flow.
    func testSearchDownloadAndSlice() {
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Entdecken"].waitForExistence(timeout: 10))
        app.segmentedControls.buttons["Printables"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("calibration cube\n")
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'result-printables'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "Printables search should return results")
        sleep(2)
        snapshot("20-Suche")
        card.tap()
        let print = app.staticTexts["Drucken"].firstMatch
        XCTAssertTrue(print.waitForExistence(timeout: 30), "model files should load")
        snapshot("21-Modell")
        print.tap()
        let slice = app.buttons["sliceButton"]
        XCTAssertTrue(slice.waitForExistence(timeout: 60), "downloaded model should open in the prepare screen")
        sleep(2)
        snapshot("22-Download-vorbereitet")
        slice.tap()
        XCTAssertTrue(app.buttons["printButton"].waitForExistence(timeout: 120), "downloaded model should slice")
        snapshot("23-Download-geslicet")
    }

    /// Cut the sample cube with the cut tool and check that two parts result.
    func testCutTool() {
        app.launchArguments = ["-uiTestSampleModel"]
        app.launch()
        XCTAssertTrue(app.buttons["sliceButton"].waitForExistence(timeout: 20))
        // The objects panel must be visible above the bottom bar before its menu can open; the
        // layout height varies, so scroll in small steps and retry.
        let menu = app.buttons["objectMenu"].firstMatch
        let cut = app.buttons["Teilen …"].firstMatch
        let scroll = app.scrollViews.element(boundBy: 0)
        var opened = false
        for attempt in 0..<5 {
            if menu.waitForExistence(timeout: 3), menu.isHittable {
                menu.tap()
                if cut.waitForExistence(timeout: 3) { opened = true; break }
            }
            if attempt < 2 { scroll.swipeUp() } else { scroll.swipeDown() }
            sleep(1)
        }
        XCTAssertTrue(opened, "object menu should offer the cut tool")
        cut.tap()
        XCTAssertTrue(app.buttons["confirmCut"].waitForExistence(timeout: 5))
        sleep(2)
        snapshot("30-Teilen")
        app.buttons["confirmCut"].tap()
        XCTAssertTrue(app.staticTexts["Würfel 20 mm – Teil 2"].waitForExistence(timeout: 10), "cut should create two parts")
        snapshot("31-Geteilt")
        app.buttons["sliceButton"].tap()
        XCTAssertTrue(app.buttons["printButton"].waitForExistence(timeout: 60))
        snapshot("32-Geteilt-geslicet")
    }

    /// Full virtual print: slice the sample for the virtual Kobra S1 running on the CI Mac, send it,
    /// then watch it print in the printer tab (live data incl. the ACE Pro).
    func testVirtualKobraPrint() throws {
        app.launchArguments = ["-uiTestVirtualKobra", "-uiTestSampleModel"]
        app.launch()
        let slice = app.buttons["sliceButton"]
        XCTAssertTrue(slice.waitForExistence(timeout: 20))
        slice.tap()
        let print = app.buttons["printButton"]
        XCTAssertTrue(print.waitForExistence(timeout: 60))
        print.tap()
        if app.buttons["Ohne Änderungen drucken"].waitForExistence(timeout: 3) {
            snapshot("30-Kobra-Empfehlungen")
            app.buttons["Ohne Änderungen drucken"].tap()
        }
        XCTAssertTrue(app.staticTexts["An den Drucker gesendet"].waitForExistence(timeout: 40), "upload + start on the virtual printer")
        snapshot("31-Kobra-gesendet")
        app.buttons["Zum Drucker"].tap()
        XCTAssertTrue(app.staticTexts["Druckt"].firstMatch.waitForExistence(timeout: 30), "printer tab shows the running print")
        snapshot("32-Kobra-druckt")
        app.staticTexts["Virtueller Kobra S1"].firstMatch.tap()
        sleep(3)
        snapshot("33-Kobra-Live")
        app.swipeUp()
        sleep(1)
        snapshot("34-Kobra-ACE")
    }
}
