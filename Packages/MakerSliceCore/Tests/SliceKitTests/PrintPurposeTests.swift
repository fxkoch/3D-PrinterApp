import XCTest
@testable import SliceKit

final class PrintPurposeTests: XCTestCase {
    func testEveryGoalIsRepeatableAndSwitchingBackRestores() {
        let start = PrintSettings(printer: .snapmakerU1)
        for goal in PrintPurpose.allCases {
            var once = start
            once.apply(goal)
            var twice = once
            twice.apply(goal)
            XCTAssertEqual(once, twice, "\(goal) applied twice")
            XCTAssertEqual(once.purpose, goal)
            var back = once
            back.apply(.balanced)
            var balanced = start
            balanced.apply(.balanced)
            XCTAssertEqual(back.wallLoops, balanced.wallLoops, "\(goal) → balanced")
            XCTAssertEqual(back.infillDensity, balanced.infillDensity)
            XCTAssertEqual(back.layerHeight, balanced.layerHeight)
            XCTAssertEqual(back.outerWallSpeed, balanced.outerWallSpeed)
        }
    }

    func testGoalsDifferWhereTheyShould() {
        func settings(_ goal: PrintPurpose) -> PrintSettings { var s = PrintSettings(printer: .snapmakerU1); s.apply(goal); return s }
        XCTAssertGreaterThan(settings(.robust).wallLoops, settings(.balanced).wallLoops)
        XCTAssertGreaterThan(settings(.strong).infillDensity, settings(.robust).infillDensity)
        XCTAssertLessThan(settings(.light).infillDensity, settings(.saving).infillDensity)
        XCTAssertGreaterThan(settings(.fast).layerHeight, settings(.balanced).layerHeight)
        XCTAssertLessThan(settings(.fine).layerHeight, settings(.balanced).layerHeight)
        XCTAssertEqual(settings(.fine).seamPosition, .corner)
        XCTAssertEqual(settings(.saving).skirtLoops, 0)
        // Shells keep their thickness with thicker layers.
        let fast = settings(.fast)
        XCTAssertGreaterThanOrEqual(Double(fast.topLayers) * fast.layerHeight, 0.8)
    }

    func testGoalsFollowTheFilament() {
        var s = PrintSettings(printer: .snapmakerU1)
        s.filaments[1] = .tpu
        s.apply(.fast, usedTools: [1])
        XCTAssertEqual(s.infillPattern, .gyroid, "TPU always gyroid")
        var p = PrintSettings(printer: .snapmakerU1)
        p.filaments[0] = .petg
        p.filaments[0].fanSpeed = 0.6
        p.apply(.robust, usedTools: [0])
        XCTAssertLessThanOrEqual(p.filaments[0].fanSpeed, 0.3)
        XCTAssertNotNil(PrintPurpose.robust.note(for: .petg))
        // Unused slots stay as they are.
        var q = PrintSettings(printer: .snapmakerU1)
        q.filaments[3] = .tpu
        q.apply(.fast, usedTools: [0])
        XCTAssertEqual(q.infillPattern, .grid)
    }

    func testAdvisorLeavesAChosenGoalAlone() throws {
        var s = PrintSettings(printer: .snapmakerU1)
        let small = [ModelObject(name: "Klein", mesh: Fixtures.box(8, 8, 8))]
        XCTAssertTrue(PrintAdvisor.recommendations(objects: small, settings: s).contains { $0.id == "fine" })
        s.apply(.fast)
        XCTAssertFalse(PrintAdvisor.recommendations(objects: small, settings: s).contains { $0.id == "fine" })
        // Auto-tuning keeps the goal's layer height.
        XCTAssertEqual(AutoTune.run(objects: small, settings: s).settings.layerHeight, s.layerHeight)
    }

    func testOldSettingsDecodeAsBalanced() throws {
        let data = try JSONEncoder().encode(PrintSettings())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["purpose"] = nil
        let decoded = try JSONDecoder().decode(PrintSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.purpose, .balanced)
    }
}
