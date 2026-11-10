@testable import SliceKit
import XCTest

final class BambuP1STests: XCTestCase {
    private func slice(_ s: PrintSettings, objects: [ModelObject]) throws -> SliceJob.Output {
        let arranged = try XCTUnwrap(PlateArranger.arrange(objects, bedSize: s.bedSize))
        return try SliceJob(name: "p1s", objects: arranged, settings: s).run()
    }

    func testMachineProfileAndFilaments() {
        let m = PrinterModel.bambuP1S.machine
        XCTAssertEqual(m.bedSize, 256)
        XCTAssertEqual(m.maxHeight, 250)
        XCTAssertEqual(m.multiMaterial, .filamentSwitcher)
        let filaments = FilamentLibrary.entries(for: .bambuP1S).filter { $0.scope == "p1s" }
        XCTAssertGreaterThan(filaments.count, 50)
        XCTAssertEqual(FilamentLibrary.defaultFilament(for: .bambuP1S).vendor.lowercased().contains("bambu") || FilamentLibrary.defaultFilament(for: .bambuP1S).name.contains("PLA"), true)
        XCTAssertFalse(FilamentLibrary.entries(for: .kobraS1).contains { $0.scope == "p1s" }, "P1S profiles stay with the P1S")
    }

    func testSingleColourGCodeFollowsTheBambuProfile() throws {
        var s = PrintSettings(printer: .bambuP1S)
        s.filaments[0] = FilamentLibrary.defaultFilament(for: .bambuP1S)
        let out = try slice(s, objects: [ModelObject(name: "Würfel", mesh: Fixtures.box(20, 20, 6))])
        let g = out.gcode
        for needed in ["M620 S0A", "T0", "G29 A X", "M73 P", "M73 L1", "M991 S0 P0", "M17 X0.8 Y0.8 Z0.5", "M1002 set_gcode_claim_speed_level : 0"] {
            XCTAssertTrue(g.contains(needed), "missing \(needed)")
        }
        XCTAssertTrue(g.contains("G29.1 Z-0.04"), "textured PEI z trim")
        for klipper in ["SET_PRESSURE_ADVANCE", "SET_VELOCITY_LIMIT", "BED_MESH_CALIBRATE", "SM_PRINT", "G9111", "SET_PRINT_STATS_INFO"] {
            XCTAssertFalse(g.contains(klipper), "Klipper command \(klipper) on a Bambu printer")
        }
        XCTAssertTrue(g.contains("M204 S"), "acceleration via M204")
        // The bed and nozzle are heated before anything else moves for real.
        let bedIndex = try XCTUnwrap(g.range(of: "M190 S")).lowerBound
        let firstLayer = try XCTUnwrap(g.range(of: ";LAYER_CHANGE")).lowerBound
        XCTAssertLessThan(bedIndex, firstLayer)
    }

    func testOtherPlateDropsTheTexturedTrimAndChangesBedTemperature() throws {
        var s = PrintSettings(printer: .bambuP1S)
        s.plateType = .coolPlate
        let out = try slice(s, objects: [ModelObject(name: "Würfel", mesh: Fixtures.box(20, 20, 4))])
        XCTAssertFalse(out.gcode.contains("G29.1 Z-0.04"))
        XCTAssertTrue(out.gcode.contains("; curr_bed_type = Cool Plate"))
    }

    func testMultiColourUsesAMSChangeSequence() throws {
        var s = PrintSettings(printer: .bambuP1S)
        s.filaments[1] = s.filaments[0]
        let a = ModelObject(name: "A", mesh: Fixtures.box(20, 20, 4), tool: 0)
        let b = ModelObject(name: "B", mesh: Fixtures.box(20, 20, 4), tool: 1)
        let out = try slice(s, objects: [a, b])
        XCTAssertTrue(out.gcode.contains("M620 S1A"))
        XCTAssertTrue(out.gcode.contains("M621 S1A"))
        XCTAssertTrue(out.gcode.contains("T1\n"))
        XCTAssertGreaterThan(out.estimate.toolChanges, 0)
    }

    func testAdvisorDoesNotCallTheAMSASlotLikeTheKobra() {
        var s = PrintSettings(printer: .bambuP1S)
        s.filaments[0] = Filament.pla
        s.filaments[0].type = "TPU"
        let tips = PrintAdvisor.materialAdvice(objects: [ModelObject(name: "A", mesh: Fixtures.box(10, 10, 10))], settings: s, usedTools: [0], dryerHumidity: nil)
        XCTAssertTrue(tips.contains { $0.id == "p1s-tpu" })
    }

    func testCommunityHintsAppearOnlyForTheirPrinterAndMaterial() {
        var kobra = PrintSettings(printer: .kobraS1)
        kobra.filaments[0].type = "ABS"
        let tips = PrintAdvisor.materialAdvice(objects: [ModelObject(name: "A", mesh: Fixtures.box(10, 10, 10))], settings: kobra, usedTools: [0], dryerHumidity: nil)
        XCTAssertTrue(tips.contains { $0.id == "community-kobra-abs" })
        XCTAssertFalse(tips.contains { $0.id == "community-p1s-start" })
        let p1s = PrintAdvisor.materialAdvice(objects: [ModelObject(name: "A", mesh: Fixtures.box(10, 10, 10))], settings: PrintSettings(printer: .bambuP1S), usedTools: [0], dryerHumidity: nil)
        XCTAssertTrue(p1s.contains { $0.id == "community-p1s-start" })
        XCTAssertTrue(tips.filter { $0.id.hasPrefix("community") }.allSatisfy { $0.action == nil }, "community hints never change settings on their own")
    }

    func testSkipLevelingHintOnlyWhenRecentlyLevelled() {
        let objects = [ModelObject(name: "A", mesh: Fixtures.box(20, 20, 10))]
        let s = PrintSettings(printer: .kobraS1)
        let recent = PrintAdvisor.recommendations(objects: objects, settings: s, hoursSinceLeveling: 3)
        let tip = recent.first { $0.id == "skip-leveling" }
        XCTAssertEqual(tip?.action, .leveling(false))
        XCTAssertFalse(PrintAdvisor.recommendations(objects: objects, settings: s, hoursSinceLeveling: 30).contains { $0.id == "skip-leveling" })
        XCTAssertFalse(PrintAdvisor.recommendations(objects: objects, settings: s).contains { $0.id == "skip-leveling" })
        var off = s
        off.enableBedLeveling = false
        XCTAssertFalse(PrintAdvisor.recommendations(objects: objects, settings: off, hoursSinceLeveling: 3).contains { $0.id == "skip-leveling" }, "already off")
        var list = objects
        var settings = s
        try? PrintAdvisor.apply(.leveling(false), settings: &settings, objects: &list)
        XCTAssertFalse(settings.enableBedLeveling)
    }

    func testOlderSavedSettingsStillLoadAndNewOnesRoundTrip() throws {
        var s = PrintSettings(printer: .kobraS1)
        s.startVibrationCompensation = true
        s.startFlowCalibration = true
        let back = try JSONDecoder().decode(PrintSettings.self, from: JSONEncoder().encode(s))
        XCTAssertTrue(back.startVibrationCompensation && back.startFlowCalibration)
        let old = try JSONDecoder().decode(PrintSettings.self, from: Data(#"{"printer":"kobraS1","layerHeight":0.2}"#.utf8))
        XCTAssertFalse(old.startVibrationCompensation)
        XCTAssertTrue(old.enableBedLeveling)
    }

    func testP1SGetsTheExpertOptionsWithBambuDefaults() {
        let options = SlicerOptionCatalog.options(for: .bambuP1S)
        XCTAssertGreaterThan(options.count, 250, "the same Orca options as the other printers")
        XCTAssertEqual(SlicerOptionCatalog.option("layer_height")?.vendor[.bambuP1S], "0.2")
        XCTAssertNotNil(SlicerOptionCatalog.option("seam_gap")?.availableFor.contains(.bambuP1S))
    }

    /// A process profile from the internet (own file, no printer_model) is turned into differences to choose from.
    func testProfileFileFromTheInternetBecomesAReport() throws {
        let json = #"{"name":"0.20mm Speed @Kobra S1 (Community)","from":"User","compatible_printers":["Anycubic Kobra S1 0.4 nozzle"],"layer_height":"0.24","sparse_infill_density":"25%","outer_wall_acceleration":"5000"}"#
        let project = try XCTUnwrap(ProjectSettings.fromConfig(Data(json.utf8)))
        XCTAssertEqual(project.profileName, "0.20mm Speed @Kobra S1 (Community)")
        let report = ProfileAdvisor.analyze(project: project, settings: PrintSettings(printer: .kobraS1))
        XCTAssertFalse(report.isEmpty)
        XCTAssertFalse(report.foreignPrinter, "made for the Kobra S1")
        XCTAssertTrue(report.changes.contains { $0.title.lowercased().contains("schichth") }, "layer height is offered")
        XCTAssertTrue(ProfileAdvisor.analyze(project: project, settings: PrintSettings(printer: .snapmakerU1)).foreignPrinter)
        XCTAssertNil(ProjectSettings.fromConfig(Data("no json".utf8)))
    }
}
