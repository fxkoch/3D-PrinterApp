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
        let before = expert.value as? String
        if before != "1" {
            // The switch sits at the right end of its row: tap there, not in the middle of the label.
            expert.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        sleep(1)
        snapshot("49-Expertenmodus-an")
        let after = expert.value as? String   // read now: the switch leaves the screen while scrolling
        // Expert mode adds several sections (assistant, cloud slicing, …) above the defaults: the form only
        // builds rows that are on screen, so scroll down until the section exists. Short drags instead of swipes:
        // a full swipe can jump past the short section in one go, and then it no longer exists either.
        // Depending on the iOS version the section header is reported in capitals ("STANDARD-EINSTELLUNGEN").
        let defaults = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Standard-Einstellungen")).firstMatch
        for _ in 0..<16 where !defaults.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        }
        XCTAssertTrue(defaults.waitForExistence(timeout: 5),
                      "expert mode should reveal the default settings (switch was \(before ?? "nil"), is \(after ?? "nil"))")
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

    /// The add-printer screen finds the (virtual) printer by itself – no IP address typed in.
    func testFindsPrinterWithoutTypingAnAddress() throws {
        app.launchArguments += ["-uiTestScanHost", "127.0.0.1"]
        app.launch()
        app.tabBars.buttons["Drucker"].tap()
        let add = app.buttons["Drucker hinzufügen"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let found = app.buttons["found-127.0.0.1"]
        XCTAssertTrue(found.waitForExistence(timeout: 20), "the scan should list the virtual Kobra S1")
        snapshot("90-Drucker-gefunden")
        found.tap()
        let hostField = app.textFields["printerHost"]
        XCTAssertEqual(hostField.value as? String, "127.0.0.1")
        XCTAssertTrue(app.staticTexts["Anycubic Kobra S1"].exists || app.buttons["Anycubic Kobra S1"].exists)
        snapshot("91-Drucker-uebernommen")
    }

    /// Bambu Lab P1S: choosing it asks for serial number and access code instead of just an address.
    func testAddBambuP1S() {
        app.launch()
        app.tabBars.buttons["Drucker"].tap()
        let add = app.buttons["Drucker hinzufügen"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let model = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Modell'")).firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 10))
        model.tap()
        let p1s = app.buttons["Bambu Lab P1S"].firstMatch
        XCTAssertTrue(p1s.waitForExistence(timeout: 5))
        p1s.tap()
        XCTAssertTrue(app.textFields["printerSerial"].waitForExistence(timeout: 5), "serial number field")
        XCTAssertTrue(app.secureTextFields["printerAccessCode"].exists, "access code field")
        app.textFields["printerSerial"].tap()
        app.textFields["printerSerial"].typeText("01P00A000000001")
        app.textFields["printerHost"].tap()
        app.textFields["printerHost"].typeText("192.168.1.77")
        snapshot("92-Drucker-Bambu")
        app.buttons["savePrinter"].tap()
        XCTAssertTrue(app.staticTexts["Bambu Lab P1S"].waitForExistence(timeout: 10) || app.buttons["Bambu Lab P1S"].waitForExistence(timeout: 2))
    }

    /// The printer makers' own model libraries (built into Slicer Next / Snapmaker Orca) open in the app.
    func testPrinterMakerPortalsOpen() {
        app.launch()
        app.tabBars.buttons["Entdecken"].tap()
        for (i, name) in ["Anycubic Maker Online", "Snapmaker Modelle"].enumerated() {
            app.buttons["portals"].firstMatch.tap()
            if i == 0 { snapshot("85-Portal-Menue") }
            let item = app.buttons[name].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), "\(name) should be in the portal menu")
            item.tap()
            sleep(12)
            snapshot("86-Portal-\(i)")
            app.buttons["Fertig"].tap()
            sleep(1)
        }
    }

    /// A multi-colour model is recognised: the app asks which filament prints which colour and slices it with colour changes.
    func testMultiColorModelAsksForFilaments() {
        app.launchArguments += ["-uiTestMultiColorModel"]
        app.launch()
        let done = app.buttons["colorSetupDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 20), "multi-colour models should open the colour assignment")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Farbe 3'")).firstMatch.exists)
        snapshot("98-Farben-zuordnen")
        // Print colour 3 with slot 4 instead.
        app.buttons["map-2-slot-3"].tap()
        XCTAssertTrue(app.buttons["pick-filament-2"].exists)
        app.buttons["pick-filament-2"].tap()
        XCTAssertTrue(app.buttons["editFilament"].waitForExistence(timeout: 5), "the filament profile can be adjusted")
        snapshot("99-Filament-anpassen")
        app.buttons["Fertig"].firstMatch.tap()
        done.tap()
        XCTAssertTrue(app.buttons["sliceButton"].waitForExistence(timeout: 10))
        sleep(2)
        snapshot("97-Mehrfarb-Vorschau")
        app.buttons["sliceButton"].tap()
        XCTAssertTrue(app.buttons["printButton"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["Wechsel"].exists, "the colours need tool changes")
    }

    /// Screenshots of the simple mode for a review of how much it asks of the user.
    func testSimpleModeReview() {
        app.launchArguments += ["-uiTestMultiColorModel", "-uiTestVirtualKobra"]
        app.launch()
        if app.buttons["colorSetupDone"].waitForExistence(timeout: 20) { app.buttons["colorSetupDone"].tap() }
        let scroll = app.scrollViews["prepareScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        for i in 0..<5 {
            snapshot("7\(i)-Einfach-Vorbereiten")
            scroll.swipeUp(velocity: .slow)
        }
        app.buttons["closeProject"].tap()
        app.tabBars.buttons["Drucker"].tap()
        sleep(3)
        snapshot("75-Einfach-Drucker")
        app.tabBars.buttons["Einstellungen"].tap()
        sleep(1)
        snapshot("76-Einfach-Einstellungen")
    }

    /// Calibration: pick a test, prepare and slice the print, enter the best step and see the value saved.
    func testCalibrationFlow() throws {
        app.launchArguments += ["-uiTestVirtualKobra"]
        app.launch()
        app.tabBars.buttons["Drucker"].tap()
        let link = app.buttons["calibrateLink"]
        for _ in 0..<5 where !link.exists { app.swipeUp() }
        XCTAssertTrue(link.waitForExistence(timeout: 20), "the printer page offers calibration")
        link.tap()
        let temperature = app.buttons["calibration-temperature"]
        XCTAssertTrue(temperature.waitForExistence(timeout: 10))
        snapshot("A0-Kalibrieren")
        temperature.tap()
        let prepare = app.buttons["prepareCalibration"]
        for _ in 0..<6 where !prepare.exists { app.swipeUp() }
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        snapshot("A1-Temperaturturm")
        prepare.tap()
        XCTAssertTrue(app.buttons["sliceButton"].waitForExistence(timeout: 20), "the calibration print opens in the prepare screen")
        XCTAssertTrue(app.buttons["enterCalibrationResult"].exists)
        snapshot("A2-Kalibrierdruck")
        app.buttons["sliceButton"].tap()
        XCTAssertTrue(app.buttons["printButton"].waitForExistence(timeout: 90), "the tower slices")
        app.buttons["enterCalibrationResult"].tap()
        let picker = app.buttons["bestStep"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS '°C'")).element(boundBy: 3).tap()
        let save = app.buttons["saveCalibration"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        snapshot("A3-Ergebnis")
        save.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'automatisch'")).firstMatch.waitForExistence(timeout: 5))
        snapshot("A4-Gespeichert")
        // "No step was good" leads to what to do next, and the open tests are offered.
        let none = app.buttons["noStepGood"]
        for _ in 0..<4 where !none.isHittable { app.swipeUp() }
        none.tap()
        XCTAssertTrue(app.staticTexts["Filament trocknen"].waitForExistence(timeout: 5), "advice: dry the filament first")
        let retraction = app.buttons["Rückzug-Test starten"]
        for _ in 0..<4 where !retraction.exists { app.swipeUp() }
        XCTAssertTrue(retraction.waitForExistence(timeout: 5), "advice offers the retraction test")
        snapshot("A5-Keine-Stufe-gut")
    }

    /// The complete calibration: all tests listed, results entered in one place and saved with one tap.
    func testCompleteCalibrationSavesAllChosenValues() throws {
        app.launchArguments += ["-uiTestVirtualKobra"]
        app.launch()
        app.tabBars.buttons["Drucker"].tap()
        let link = app.buttons["calibrateLink"]
        for _ in 0..<5 where !link.exists { app.swipeUp() }
        XCTAssertTrue(link.waitForExistence(timeout: 20))
        link.tap()
        let overview = app.buttons["calibrationOverview"]
        XCTAssertTrue(overview.waitForExistence(timeout: 10))
        overview.tap()
        let step = app.buttons["overviewStep-temperature"]
        for _ in 0..<4 where !step.exists { app.swipeUp() }
        XCTAssertTrue(step.waitForExistence(timeout: 10), "result picker for the temperature tower")
        step.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS '°C'")).element(boundBy: 2).tap()
        let retraction = app.buttons["overviewStep-retraction"]
        for _ in 0..<6 where !retraction.exists { app.swipeUp() }
        retraction.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS ' mm'")).element(boundBy: 1).tap()
        let save = app.buttons["overviewSaveAll"]
        for _ in 0..<8 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.label.contains("2 gewählte"), save.label)
        snapshot("A6-Komplett-Kalibrierung")
        save.tap()
        let done = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '2 Werte gespeichert'")).firstMatch
        for _ in 0..<4 where !done.exists { app.swipeUp() }
        XCTAssertTrue(done.waitForExistence(timeout: 5))
    }

    /// Photo → shape: a drawn star becomes a printable plate that opens in the prepare screen.
    func testPhotoShapeFromAPhoto() throws {
        app.launchArguments += ["-uiTestPhotoShape"]
        app.launch()
        app.tabBars.buttons["Bibliothek"].tap()
        XCTAssertTrue(app.navigationBars["Bibliothek"].waitForExistence(timeout: 10))
        let add = app.buttons["libraryAdd"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        // The menu in the navigation bar is not reported as hittable, and the plain tap then fails while
        // trying to scroll it into view: tap its centre instead.
        add.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let entry = app.buttons["libraryPhotoShape"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.otherElements["photoShapePreview"].waitForExistence(timeout: 30), "the 3D preview of the star")
        snapshot("B1-Foto-Form")
        let save = app.buttons["photoShapeSave"]
        for _ in 0..<4 where !save.isHittable { app.swipeUp() }
        save.tap()
        XCTAssertTrue(app.buttons["sliceButton"].waitForExistence(timeout: 30), "the shape opens for printing")
        snapshot("B2-Foto-Form-Druck")
    }

    /// Claude assistant without an API key: the ✨ button in the prepare screen, the Claude tab and the setup screen.
    func testClaudeAssistantSetup() {
        app.launchArguments = ["-uiTestSampleModel"]
        app.launch()

        let ask = app.buttons["askClaude"]
        XCTAssertTrue(ask.waitForExistence(timeout: 20), "prepare screen should show the Claude button")
        ask.tap()
        XCTAssertTrue(app.staticTexts["Claude einrichten"].waitForExistence(timeout: 5), "sheet asks for setup without a key")
        sleep(1)
        snapshot("30-Claude-im-Projekt")
        app.buttons["Fertig"].tap()

        app.buttons["closeProject"].tap()
        let tab = app.tabBars.buttons["Claude"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
        XCTAssertTrue(app.staticTexts["Claude einrichten"].waitForExistence(timeout: 5))
        snapshot("31-Claude-Tab")

        app.buttons["Jetzt einrichten"].tap()
        XCTAssertTrue(app.secureTextFields["claudeKey"].waitForExistence(timeout: 5), "setup screen with key field")
        XCTAssertTrue(app.staticTexts["Claude Opus 5.5"].exists, "model picker lists Opus 5.5")
        sleep(1)
        snapshot("32-Claude-Einrichtung")
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

    /// Colour change at a height: the object prints with another slot from there; the slicer reports the changes.
    func testColorChangeAtHeight() {
        app.launchArguments += ["-uiTestSampleModel"]
        app.launch()
        XCTAssertTrue(app.buttons["sliceButton"].waitForExistence(timeout: 20))
        let menu = app.buttons["objectMenu"].firstMatch
        let entry = app.buttons["colorChangeMenu"].firstMatch
        let scroll = app.scrollViews["prepareScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        var opened = false
        for _ in 0..<5 {
            if menu.waitForExistence(timeout: 3), menu.frame.maxY < scroll.frame.minY + scroll.frame.height * 0.6 {
                menu.tap()
                if entry.waitForExistence(timeout: 3) { opened = true; break }
            }
            scroll.swipeUp(velocity: .slow)
            sleep(1)
        }
        XCTAssertTrue(opened, "object menu should offer colour changes")
        entry.tap()
        XCTAssertTrue(app.buttons["addColorChange"].waitForExistence(timeout: 5))
        app.buttons["addColorChange"].tap()
        sleep(1)
        snapshot("95-Farbwechsel")
        app.buttons["colorChangesDone"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Slot 2'")).firstMatch.waitForExistence(timeout: 5),
                      "the object row should list the colour change")
        app.buttons["sliceButton"].tap()
        XCTAssertTrue(app.buttons["printButton"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["Wechsel"].exists, "tool changes should be reported after slicing")
        snapshot("96-Farbwechsel-geslicet")
    }

    /// Strength check: pick two faces on the sample cube, calculate, ask for improvements.
    func testStrengthCheck() {
        app.launchArguments += ["-uiTestSampleModel"]
        app.launch()
        XCTAssertTrue(app.buttons["sliceButton"].waitForExistence(timeout: 20))
        let menu = app.buttons["objectMenu"].firstMatch
        let entry = app.buttons["strengthMenu"].firstMatch
        let scroll = app.scrollViews["prepareScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        var opened = false
        for _ in 0..<5 {
            if menu.waitForExistence(timeout: 3), menu.frame.maxY < scroll.frame.minY + scroll.frame.height * 0.6 {
                menu.tap()
                if entry.waitForExistence(timeout: 3) { opened = true; break }
            }
            scroll.swipeUp(velocity: .slow)
            sleep(1)
        }
        XCTAssertTrue(opened, "object menu should offer the strength check")
        entry.tap()
        let scene = app.otherElements["strengthScene"].firstMatch
        XCTAssertTrue(scene.waitForExistence(timeout: 10))
        sleep(2)
        snapshot("97-Festigkeit-leer")
        // The app suggests supports and a load by itself; tapping the model asks what the spot is.
        XCTAssertTrue(app.buttons["strengthRun"].isEnabled, "automatic suggestion makes the check ready")
        scene.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.66)).tap()
        let asSupport = app.buttons["Hier wird es festgehalten (Halterung)"]
        XCTAssertTrue(asSupport.waitForExistence(timeout: 5), "tap opens the question")
        asSupport.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Halterung 2'")).firstMatch.waitForExistence(timeout: 5), "second support added")
        snapshot("98-Festigkeit-Flaechen")
        app.buttons["strengthRun"].tap()
        XCTAssertTrue(app.staticTexts["Ergebnis"].waitForExistence(timeout: 120) || app.staticTexts["ERGEBNIS"].waitForExistence(timeout: 5),
                      "the result should appear")
        sleep(1)
        snapshot("99-Festigkeit-Ergebnis")
        let suggest = app.buttons["strengthSuggest"]
        if suggest.waitForExistence(timeout: 5) {
            suggest.tap()
            XCTAssertTrue(app.buttons["Übernehmen"].firstMatch.waitForExistence(timeout: 180) || app.staticTexts["Es wird nichts Besseres gefunden, als du schon eingestellt hast."].exists)
            snapshot("99b-Festigkeit-Vorschlaege")
        }
    }

    /// Weak-spot scan without any load.
    func testWeakSpotScan() {
        app.launchArguments += ["-uiTestSampleModel"]
        app.launch()
        XCTAssertTrue(app.buttons["sliceButton"].waitForExistence(timeout: 20))
        let menu = app.buttons["objectMenu"].firstMatch
        let entry = app.buttons["strengthMenu"].firstMatch
        let scroll = app.scrollViews["prepareScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        var opened = false
        for _ in 0..<5 {
            if menu.waitForExistence(timeout: 3), menu.frame.maxY < scroll.frame.minY + scroll.frame.height * 0.6 {
                menu.tap()
                if entry.waitForExistence(timeout: 3) { opened = true; break }
            }
            scroll.swipeUp(velocity: .slow)
            sleep(1)
        }
        XCTAssertTrue(opened)
        entry.tap()
        let more = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Mehr:'")).firstMatch
        for _ in 0..<6 where !more.isHittable { app.swipeUp() }
        more.tap()
        let scan = app.buttons["weakSpotScan"]
        for _ in 0..<4 where !scan.isHittable { app.swipeUp() }
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        scan.tap()
        XCTAssertTrue(app.buttons["reinforceRun"].waitForExistence(timeout: 600), "scan should finish and offer the reinforcement")
        snapshot("99c-Schwachstellen")
    }

    /// Standard filament check on the virtual Kobra S1, and the notification settings.
    func testFilamentCheckAndNotificationSettings() throws {
        app.launchArguments += ["-uiTestVirtualKobra"]
        app.launch()
        app.tabBars.buttons["Drucker"].tap()
        let printer = app.staticTexts["Virtueller Kobra S1"].firstMatch
        XCTAssertTrue(printer.waitForExistence(timeout: 20))
        printer.tap()
        let button = app.buttons["filamentCheckButton"]
        for _ in 0..<5 where !button.exists || !button.isHittable { app.swipeUp(); sleep(1) }
        XCTAssertTrue(button.waitForExistence(timeout: 20))
        button.tap()
        XCTAssertTrue(app.buttons["filamentRecheck"].waitForExistence(timeout: 15), "re-check button")
        XCTAssertTrue(app.staticTexts["Meldung des Druckers"].waitForExistence(timeout: 15), "traffic lights from the printer status")
        app.buttons["filamentRecheck"].tap()
        sleep(2)
        snapshot("34-Filament-pruefen")
        app.buttons["Fertig"].tap()
        // Filament control: the Kobra explains why the ACE cannot be operated from the app.
        let control = app.buttons["filamentControlButton"]
        for _ in 0..<4 where !control.isHittable { app.swipeUp() }
        control.tap()
        XCTAssertTrue(app.buttons["loadSlot"].waitForExistence(timeout: 10), "the ACE can be loaded from the app")
        XCTAssertTrue(app.buttons["unloadFilament"].exists)
        XCTAssertTrue(app.buttons["retractSlot"].exists)
        snapshot("34b-Filament-bedienen")
        app.buttons["Fertig"].tap()
        app.tabBars.buttons["Einstellungen"].tap()
        let toggle = app.switches["notifyToggle"]
        for _ in 0..<4 where !toggle.exists { app.swipeUp() }
        snapshot("35-Einstellungen-unten")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "notification switch in the settings")
        snapshot("35-Benachrichtigungen")
    }

    /// Live view of the virtual Kobra S1: its camera is started over MQTT and the FLV video arrives.
    func testLiveViewWithCamera() throws {
        app.launchArguments += ["-uiTestVirtualKobra"]
        app.launch()
        app.tabBars.buttons["Drucker"].tap()
        let live = app.buttons["liveButton"]
        XCTAssertTrue(live.waitForExistence(timeout: 30), "printer dashboard should offer the live view")
        live.tap()
        let camera = app.otherElements["liveCamera"]
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        let started = Date()
        while (camera.value as? String) != "live", Date().timeIntervalSince(started) < 40 { sleep(1) }
        XCTAssertEqual(camera.value as? String, "live", "video frames should arrive from the virtual camera")
        XCTAssertTrue(app.staticTexts["Aktueller Schritt"].exists || app.staticTexts["AKTUELLER SCHRITT"].exists)
        snapshot("97-Live-Ansicht")
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

    private func simState() -> [String: Any] {
        var result: [String: Any] = [:]
        let done = expectation(description: "sim state")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:17125/sim/state")!)
        request.timeoutInterval = 5
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, _, _ in
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { result = json }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 8)
        return result
    }

    /// Virtual Snapmaker U1 with multiACE (tools/virtualprinters/u1_multiace_sim.py): the app shows the ACE, loads a tool
    /// head from its ACE slot and starts the dryer – the simulator records the exact commands.
    func testVirtualU1WithMultiACE() throws {
        app.launchArguments += ["-uiTestVirtualU1ACE"]
        app.launch()
        app.tabBars.buttons["Drucker"].tap()
        let printer = app.staticTexts["Virtueller U1 (ACE)"].firstMatch
        XCTAssertTrue(printer.waitForExistence(timeout: 20))
        printer.tap()
        let details = app.staticTexts["aceMode"].firstMatch
        for _ in 0..<5 where !details.exists { app.swipeUp(); sleep(1) }
        XCTAssertTrue(details.waitForExistence(timeout: 20), "the app should show the ACE of the U1")
        XCTAssertTrue(app.staticTexts["ACE Pro 2 (multiACE)"].exists || app.staticTexts["ACE PRO 2 (MULTIACE)"].exists)
        XCTAssertTrue(app.staticTexts["aceMode"].label.contains("Mehrfarbig"), app.staticTexts["aceMode"].label)
        snapshot("90-U1-ACE")

        let control = app.buttons["filamentControlButton"]
        for _ in 0..<4 where !control.isHittable { app.swipeUp() }
        control.tap()
        XCTAssertTrue(app.buttons["loadSlot"].waitForExistence(timeout: 10), "load is offered for the ACE")
        XCTAssertTrue(app.buttons["retractSlot"].exists, "pulling back into the ACE is offered")
        XCTAssertFalse(app.buttons["unloadFilament"].exists, "no blind 'unload everything'")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '3 '")).firstMatch.tap()
        app.buttons["loadSlot"].tap()
        snapshot("91-U1-ACE-laden")
        // The confirmation dialog repeats the button title (without the identifier).
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Slot 3 laden' AND identifier != 'loadSlot'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let started = Date()
        while !((simState()["scripts"] as? [String]) ?? []).contains("ACE_LOAD_HEAD HEAD=2"), Date().timeIntervalSince(started) < 20 { sleep(1) }
        XCTAssertTrue(((simState()["scripts"] as? [String]) ?? []).contains("ACE_LOAD_HEAD HEAD=2"), "load command reached the printer")
        app.buttons["Fertig"].tap()
        sleep(6)
        for _ in 0..<5 where !app.buttons["dryButton"].exists { app.swipeUp(); sleep(1) }
        snapshot("92-U1-ACE-geladen")
        let dry = app.buttons["dryButton"]
        XCTAssertTrue(dry.waitForExistence(timeout: 10))
        XCTAssertTrue(dry.isEnabled, "drying is offered once a spool is loaded")
        dry.tap()
        let start = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Starten:'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        let t0 = Date()
        while !((simState()["scripts"] as? [String]) ?? []).contains(where: { $0.hasPrefix("ACE_START_DRYING TEMP=") }), Date().timeIntervalSince(t0) < 20 { sleep(1) }
        XCTAssertTrue(((simState()["scripts"] as? [String]) ?? []).contains(where: { $0.hasPrefix("ACE_START_DRYING TEMP=") }), "dryer command reached the printer")
    }
}
