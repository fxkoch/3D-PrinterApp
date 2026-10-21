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
        XCTAssertTrue(app.staticTexts["Standard-Einstellungen"].waitForExistence(timeout: 5),
                      "expert mode should reveal the default settings (switch was \(before ?? "nil"), is \(expert.value as? String ?? "nil"))")
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
        scene.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)).tap()   // front face = fixed
        scene.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38)).tap()   // top face = load
        sleep(1)
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
        let scan = app.buttons["weakSpotScan"]
        for _ in 0..<4 where !scan.isHittable { app.swipeUp() }
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        scan.tap()
        XCTAssertTrue(app.buttons["reinforceRun"].waitForExistence(timeout: 600), "scan should finish and offer the reinforcement")
        snapshot("99c-Schwachstellen")
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
}
