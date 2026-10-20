@testable import SliceKit
import XCTest

final class ProfileAdvisorTests: XCTestCase {
    private func project(_ json: String, gcode: String? = nil) throws -> ProjectSettings {
        var p = try XCTUnwrap(ProjectSettings.parse(Data(json.utf8)))
        if let gcode { p = p.withLayerGCodes(LayerGCode.parse(Data(gcode.utf8))) }
        return p
    }

    func testTemperatureTowerProfile() throws {
        let json = ##"{"print_settings_id":"0.20mm Standard @BBL X1C","printer_model":"Bambu Lab X1 Carbon","layer_height":"0.2","ironing_type":"top","print_flow_ratio":"0.95","filament_type":["PETG"],"nozzle_temperature":["290"],"filament_flow_ratio":["0.93"],"seam_gap":"0"}"##
        let gcode = ##"<?xml version="1.0"?><custom_gcodes_per_layer><plate><plate_info id="1"/><layer top_z="0.2" type="4" extruder="1" color="" extra="M104 S290" gcode="M104 S290"/><layer top_z="5.2" type="4" extruder="1" color="" extra="M104 S280" gcode="M104 S280"/><layer top_z="9" type="0" extruder="1" color="#FF0000" extra="" gcode="M600"/></plate></custom_gcodes_per_layer>"##
        let p = try project(json, gcode: gcode)
        XCTAssertEqual(p.layerGCodes.map(\.z), [0.2, 5.2, 9])

        var settings = PrintSettings(printer: .kobraS1)
        settings.filaments[0] = FilamentLibrary.bestMatch(type: "PETG", printer: .kobraS1)!
        let report = ProfileAdvisor.analyze(project: p, settings: settings)
        XCTAssertEqual(report.profileName, "0.20mm Standard @BBL X1C")
        XCTAssertTrue(report.foreignPrinter)
        let ids = Set(report.changes.map(\.id))
        XCTAssertTrue(ids.contains("p-ironing_type"))
        XCTAssertTrue(ids.contains("p-print_flow_ratio"))
        XCTAssertTrue(ids.contains("f0-nozzle_temperature"))
        XCTAssertTrue(ids.contains("f0-filament_flow_ratio"))
        XCTAssertTrue(ids.contains("g-0.2") && ids.contains("g-5.2"))
        XCTAssertFalse(ids.contains("g-9"), "colour changes are not taken over")
        XCTAssertFalse(ids.contains("p-layer_height") && settings.layerHeight == 0.2)

        let applied = ProfileAdvisor.apply(report.important, to: settings)
        XCTAssertTrue(applied.ironing)
        XCTAssertEqual(applied.filaments[0].nozzleTemp, 290)
        XCTAssertEqual(applied.filaments[0].flowRatio, 0.93, accuracy: 1e-9)
        XCTAssertEqual(applied.layerGCodes.count, 2)
        XCTAssertEqual(applied.extraOptions["print_flow_ratio"], "0.95")
        XCTAssertEqual(OrcaJob.processOverrides(applied)["print_flow_ratio"], "0.95")
    }

    func testNothingSpecialMeansNoChanges() throws {
        let settings = PrintSettings(printer: .snapmakerU1)
        let overrides = OrcaJob.processOverrides(settings)
        let json = try JSONSerialization.data(withJSONObject: ["layer_height": overrides["layer_height"]!, "wall_loops": overrides["wall_loops"]!])
        let p = try XCTUnwrap(ProjectSettings.parse(json))
        XCTAssertTrue(ProfileAdvisor.analyze(project: p, settings: settings).isEmpty)
    }

    func testLayerGCodeAppearsInGCodeAndCloudJob() throws {
        var settings = PrintSettings(printer: .snapmakerU1)
        settings.layerGCodes = [LayerGCode(z: 0.6, lines: ["M104 S250", "G28"])]
        let cube = ModelObject(name: "w", mesh: Fixtures.box(10, 10, 4))
        let arranged = try XCTUnwrap(PlateArranger.arrange([cube], bedSize: settings.bedSize))
        let out = try SliceJob(name: "t", objects: arranged, settings: settings).run()
        let gcode = out.gcode
        XCTAssertTrue(gcode.contains("M104 S250"))
        XCTAssertFalse(gcode.contains("; vom Modell eingefügt (Höhe 0.6)\nG28"), "only harmless commands are taken over")
        let job = try OrcaJob(objects: arranged, settings: settings, name: "t")
        let zip = try ZipArchive(data: job.model)
        let xml = try XCTUnwrap(zip.contents(of: "Metadata/custom_gcode_per_layer.xml"))
        XCTAssertEqual(LayerGCode.parse(xml).first?.lines, ["M104 S250"])
    }

    func testEverySettingIsExplainedWithAPicture() {
        for option in SlicerOptionCatalog.all {
            let detail = SlicerOptionDetails.detail(for: option.key)
            XCTAssertNotNil(detail, "\(option.key) has no detailed explanation")
            XCTAssertNotNil(detail?.diagram, "\(option.key) has no picture")
            XCTAssertFalse(option.summary.isEmpty, "\(option.key) has no summary")
        }
    }
}
