import XCTest

/// End-to-end smoke test on the simulator: navigate all tabs, open the built-in
/// test cube, slice it for both printers, open the cut tool and expert settings.
/// Screenshots are attached to the test result.
final class MakerSliceUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"]
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

    /// Expert mode: the complete settings list of the vendor slicer, for both printers.
    func testAllSlicerSettings() {
        app.launch()
        app.tabBars.buttons["Einstellungen"].tap()
        let expert = app.switches["expertToggle"]
        XCTAssertTrue(expert.waitForExistence(timeout: 5))
        if expert.value as? String != "1" { expert.tap() }
        for (i, model) in ["Snapmaker U1", "Anycubic Kobra S1"].enumerated() {
            let row = app.staticTexts[model].firstMatch
            for _ in 0..<4 { app.swipeDown() }
            for _ in 0..<6 where !row.exists || !row.isHittable { app.swipeUp() }
            row.tap()
            let all = app.staticTexts["Alle Slicer-Einstellungen"].firstMatch
            for _ in 0..<12 where !all.exists { app.swipeUp() }
            XCTAssertTrue(all.waitForExistence(timeout: 5), "list of all slicer settings should be offered for \(model)")
            all.tap()
            XCTAssertTrue(app.navigationBars["Slicer-Einstellungen"].waitForExistence(timeout: 5))
            snapshot("4\(i)-Alle-Einstellungen-\(model)")
            app.swipeDown()
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            search.typeText("Naht")
            sleep(1)
            snapshot("4\(i)-Suche-Naht-\(model)")
            for _ in 0..<4 where !app.navigationBars["Einstellungen"].exists {
                app.navigationBars.buttons.element(boundBy: 0).tap()
                sleep(1)
            }
        }
    }

    /// The drawn example pictures of the setting explanations.
    func testDiagramGallery() {
        app.launchArguments = ["-uiTestDiagrams"]
        app.launch()
        let gallery = app.scrollViews["diagramGallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 10))
        for i in 0..<10 {
            snapshot("5\(i)-Beispielbilder")
            gallery.swipeUp()
        }
    }

    /// A downloaded model with its own profile: the app asks before taking it over.
    func testAsksBeforeTakingOverModelProfile() {
        app.launchArguments += ["-uiTestProfileModel"]
        app.launch()
        let apply = app.buttons["profileApply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 20), "the profile question should appear")
        snapshot("60-Profil-Rueckfrage")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Düsentemperatur'")).firstMatch.exists)
        apply.tap()
        XCTAssertTrue(app.buttons["sliceButton"].waitForExistence(timeout: 10))
        XCTAssertFalse(apply.exists, "the question must go away after the choice")
        snapshot("61-Profil-uebernommen")
    }

    /// Several plates: objects that don't fit spill onto new plates; plates can be added and switched.
    func testMultiplePlates() {
        app.launchArguments += ["-uiTestPlates"]
        app.launch()
        XCTAssertTrue(app.buttons["sliceButton"].waitForExistence(timeout: 20))
        for plate in 1...3 {
            XCTAssertTrue(app.buttons["plate-\(plate)"].exists, "plate \(plate) should exist")
        }
        XCTAssertFalse(app.buttons["plate-4"].exists, "the two small cubes share a plate with a big one")
        XCTAssertTrue(app.buttons["sliceAllButton"].exists)
        snapshot("70-Mehrere-Platten")
        app.buttons["addPlate"].tap()
        XCTAssertTrue(app.buttons["plate-4"].waitForExistence(timeout: 5))
        app.buttons["plate-2"].tap()
        XCTAssertTrue(app.staticTexts["Objekte auf Platte 2"].waitForExistence(timeout: 5))
        snapshot("71-Platte-2")
    }

    /// The MakerWorld web view opens and shows the site (no login needed for this check).
    func testMakerWorldBrowserOpens() {
        app.launch()
        app.tabBars.buttons["Entdecken"].tap()
        app.buttons["portals"].firstMatch.tap()
        snapshot("79-Portale")
        app.buttons["MakerWorld"].firstMatch.tap()
        sleep(12)
        snapshot("80-MakerWorld-Browser")
        let signIn = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Anmelden' OR label CONTAINS[c] 'Sign in' OR label CONTAINS[c] 'Log in'")).firstMatch
        if signIn.exists { signIn.tap(); sleep(6); snapshot("81-MakerWorld-Login") }
    }

    func testSliceSampleForBothPrinters() {
        app.launchArguments += ["-uiTestSampleModel"]
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
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        for _ in 0..<3 where !slice.exists {
            picker.buttons["Anycubic Kobra S1"].tap()
            _ = slice.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(slice.exists, "switching to the Kobra S1 should reset the slice")
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
        app.launchArguments += ["-uiTestSampleModel"]
        app.launch()
        XCTAssertTrue(app.buttons["sliceButton"].waitForExistence(timeout: 20))
        // The objects panel must be visible above the bottom bar before its menu can open; the
        // layout height varies, so scroll in small steps and retry.
        let menu = app.buttons["objectMenu"].firstMatch
        let cut = app.buttons["Teilen …"].firstMatch
        let scroll = app.scrollViews["prepareScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        var opened = false
        for _ in 0..<5 {
            // The bottom bar covers the lower part of the panels; scroll the menu into the free area.
            if menu.waitForExistence(timeout: 3), menu.frame.maxY < scroll.frame.minY + scroll.frame.height * 0.6 {
                menu.tap()
                if cut.waitForExistence(timeout: 3) { opened = true; break }
            }
            scroll.swipeUp(velocity: .slow)
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
        app.launchArguments += ["-uiTestVirtualKobra", "-uiTestSampleModel"]
        app.launch()
        let slice = app.buttons["sliceButton"]
        XCTAssertTrue(slice.waitForExistence(timeout: 20))
        // Once the printer reports its ACE slots, the app offers to use them.
        let useLoaded = app.buttons["useLoadedFilaments"]
        XCTAssertTrue(useLoaded.waitForExistence(timeout: 30), "ACE Pro spools should be offered")
        useLoaded.tap()
        sleep(1)
        snapshot("29-Kobra-Material-uebernommen")
        XCTAssertTrue(app.buttons["slot-2"].label.contains("PETG"), app.buttons["slot-2"].label)
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
        let printing = app.staticTexts["Druckt"].firstMatch, finished = app.staticTexts["Fertig"].firstMatch
        XCTAssertTrue(printing.waitForExistence(timeout: 30) || finished.exists, "printer tab shows the print")
        snapshot("32-Kobra-druckt")
        app.staticTexts["Virtueller Kobra S1"].firstMatch.tap()
        sleep(3)
        snapshot("33-Kobra-Live")
        app.swipeUp()
        sleep(1)
        snapshot("34-Kobra-ACE")
    }
}
