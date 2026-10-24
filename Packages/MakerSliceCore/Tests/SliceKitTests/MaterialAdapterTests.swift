@testable import SliceKit
import XCTest

final class MaterialAdapterTests: XCTestCase {
    private var petg: Filament {
        FilamentLibrary.entries(for: .kobraS1).map(\.filament).first { MaterialAdapter.family($0.type) == "PETG" } ?? Filament.pla
    }

    func testFamilies() {
        XCTAssertEqual(MaterialAdapter.family("PLA Basic"), "PLA")
        XCTAssertEqual(MaterialAdapter.family("PLA-CF"), "PLA")
        XCTAssertEqual(MaterialAdapter.family("PETG-HF"), "PETG")
        XCTAssertEqual(MaterialAdapter.family("pet"), "PETG")
        XCTAssertEqual(MaterialAdapter.family("PA6-CF"), "PA")
        XCTAssertFalse(MaterialAdapter.mismatch(projectType: "PLA", filament: .pla))
        XCTAssertTrue(MaterialAdapter.mismatch(projectType: "PLA", filament: petg))
        XCTAssertFalse(MaterialAdapter.mismatch(projectType: nil, filament: petg))
    }

    func testTemperatureTowerKeepsItsStepsAroundTheNewBase() {
        // A PLA tower: 230, 225, 220 … around the author's 215 °C; PETG base 240 °C → 255, 250, 245.
        var f = petg
        f.nozzleTemp = 240; f.nozzleTempMin = 220; f.nozzleTempMax = 270
        let out = MaterialAdapter.translate(["M104 S230", "M104 S215", "M104 S0", "M117 hello", "M140 S60"], projectNozzle: 215, projectBed: 60, filament: f)
        XCTAssertEqual(out[0], "M104 S255")
        XCTAssertEqual(out[1], "M104 S240")
        XCTAssertEqual(out[2], "M104 S0", "off stays off")
        XCTAssertEqual(out[3], "M117 hello")
        XCTAssertEqual(out[4], "M140 S\(f.bedTemp)", "bed follows the filament too")
    }

    func testWithoutReferenceTheFilamentsOwnTemperatureIsUsed() {
        var f = petg
        f.nozzleTemp = 240
        XCTAssertEqual(MaterialAdapter.translate(["M104 S200"], projectNozzle: nil, projectBed: nil, filament: f), ["M104 S240"])
    }

    func testReportKeepsTheSelectedMaterialAndExplainsIt() throws {
        let config = #"{"print_settings_id":"Tower","filament_type":["PLA"],"nozzle_temperature":["215"],"nozzle_temperature_initial_layer":["220"],"textured_plate_temp":["60"],"fan_max_speed":["100"]}"#
        var project = try XCTUnwrap(ProjectSettings.fromConfig(Data(config.utf8), layerGCodeXML: Data(#"<custom_gcodes_per_layer><plate><layer top_z="5.2" type="4" extruder="1" color="" extra="M104 S205" gcode="M104 S205"/></plate></custom_gcodes_per_layer>"#.utf8)))
        project.filamentTypes = ["PLA"]
        var settings = PrintSettings(printer: .kobraS1)
        settings.filaments[0] = petg
        let report = ProfileAdvisor.analyze(project: project, settings: settings)
        XCTAssertFalse(report.changes.contains { if case .filament = $0.payload { return true } else { return false } }, "PLA's temperatures must not replace PETG's")
        XCTAssertTrue(report.materialNotes.contains { $0.contains("PLA") && $0.contains(petg.type) })
        let gcode = try XCTUnwrap(report.changes.first { if case .layerGCode = $0.payload { return true } else { return false } })
        if case .layerGCode(let code) = gcode.payload {
            XCTAssertEqual(code.lines, ["M104 S\(petg.nozzleTemp + (205 - 215))"], "the tower's step is kept, around PETG's base")
        }
        // Same material: nothing is replaced, the file's values are offered as before.
        var same = PrintSettings(printer: .kobraS1)
        same.filaments[0].nozzleTemp = 200
        same.filaments[0].type = "PLA"
        XCTAssertTrue(ProfileAdvisor.analyze(project: project, settings: same).changes.contains { if case .filament = $0.payload { return true } else { return false } })
    }

    func testSliceTimeAdaptationOnlyWhenTheMaterialDiffers() throws {
        let config = #"{"filament_type":["PLA"],"nozzle_temperature":["215"]}"#
        let project = try XCTUnwrap(ProjectSettings.fromConfig(Data(config.utf8)))
        var s = PrintSettings(printer: .kobraS1)
        s.layerGCodes = [LayerGCode(z: 5, lines: ["M104 S205"])]
        s.filaments[0] = petg
        XCTAssertEqual(s.adaptingMaterial(of: project).layerGCodes.first?.lines, ["M104 S\(petg.nozzleTemp - 10)"])
        s.filaments[0] = .pla
        XCTAssertEqual(s.adaptingMaterial(of: project).layerGCodes.first?.lines, ["M104 S205"], "same material: untouched")
    }
}
