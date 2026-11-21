import XCTest
@testable import SliceKit

final class TroubleshooterTests: XCTestCase {
    private func settings(_ filament: Filament, slot: Int = 0) -> PrintSettings {
        var s = PrintSettings()
        s.filaments[slot] = filament
        return s
    }

    func testEveryProblemHasHelpForEveryCommonMaterial() {
        for f in [Filament.pla, .petg, .tpu, .abs] {
            for problem in PrintProblem.allCases {
                let fixes = PrintTroubleshooter.fixes(for: problem, settings: settings(f), slot: 0)
                XCTAssertFalse(fixes.isEmpty, "\(problem) / \(f.type)")
                XCTAssertEqual(Set(fixes.map(\.id)).count, fixes.count, "unique ids: \(problem) / \(f.type)")
            }
        }
    }

    func testStringingWithPETGQuotesTheSlotsValues() throws {
        var s = settings(.petg, slot: 2)
        s.zHop = 0.4
        let fixes = PrintTroubleshooter.fixes(for: .stringing, settings: s, slot: 2)
        XCTAssertEqual(fixes.first?.id, "dry", "drying first")
        XCTAssertTrue(fixes.contains { $0.calibration == .retraction && $0.detail.contains("1.0 mm") || $0.detail.contains("1,0 mm") })
        let temp = try XCTUnwrap(fixes.first { if case .filament(.temperature, _) = $0.change { return true } else { return false } })
        XCTAssertEqual(temp.change, .filament(.temperature, 245))
        XCTAssertTrue(temp.title.contains("250 → 245"))
        XCTAssertTrue(fixes.contains { $0.change == .setting(.zHop(0)) })
    }

    func testChangesAreOnlyOfferedWhenTheyChangeSomething() {
        var s = settings(.pla)
        s.elephantFootCompensation = 0.2
        s.brimWidth = 0
        XCTAssertFalse(PrintTroubleshooter.fixes(for: .elephantFoot, settings: s, slot: 0).contains { $0.id == "foot" })
        s.elephantFootCompensation = 0.1
        XCTAssertTrue(PrintTroubleshooter.fixes(for: .elephantFoot, settings: s, slot: 0).contains { $0.change == .setting(.elephantFoot(0.2)) })

        s.slowDownOverhangs = true
        s.overhangSpeed = 25
        XCTAssertFalse(PrintTroubleshooter.fixes(for: .overhangs, settings: s, slot: 0).contains { $0.id == "overhang-speed" })
        s.slowDownOverhangs = false
        XCTAssertTrue(PrintTroubleshooter.fixes(for: .overhangs, settings: s, slot: 0).contains { $0.change == .setting(.overhangSlowdown(speed: 25)) })
    }

    func testTemperatureStaysInsideTheFilamentsRange() {
        var f = Filament.pla
        f.nozzleTemp = f.nozzleTempMin + 2
        let fixes = PrintTroubleshooter.fixes(for: .stringing, settings: settings(f), slot: 0)
        XCTAssertFalse(fixes.contains { if case .filament(.temperature, _) = $0.change { return true } else { return false } },
                       "no cooler step below the filament's minimum")
    }

    func testGapsOfferToRemoveCalibrationSpeedSteps() throws {
        var s = settings(.pla)
        s.layerGCodes = [LayerGCode(z: 28, lines: ["M220 S400"])]
        let fixes = PrintTroubleshooter.fixes(for: .gaps, settings: s, slot: 0)
        XCTAssertEqual(fixes.first?.id, "speed-factor")
        XCTAssertTrue(fixes.contains { $0.change == .setting(.removeLeftoverCommands) })
        let flow = try XCTUnwrap(fixes.first { $0.id == "maxflow-down" })
        XCTAssertEqual(flow.change, .filament(.maxFlow, 9.6))
    }

    func testSettingChangesApply() throws {
        var s = settings(.petg)
        var objects: [ModelObject] = []
        for problem in PrintProblem.allCases {
            for fix in PrintTroubleshooter.fixes(for: problem, settings: s, slot: 0) {
                if case .setting(let action) = fix.change { try PrintAdvisor.apply(action, settings: &s, objects: &objects) }
            }
        }
        XCTAssertEqual(s.seamPosition, .corner)
        XCTAssertGreaterThanOrEqual(s.wallLoops, 4)
        XCTAssertEqual(s.supportSpacing, 2)
        // Warping +5, first layer +5, elephant foot −5.
        XCTAssertEqual(s.filaments[0].bedTemp, Filament.petg.bedTemp + 5)
        XCTAssertEqual(s.firstLayerSpeed, 30)
        XCTAssertEqual(s.zHop, 0)
    }
}
