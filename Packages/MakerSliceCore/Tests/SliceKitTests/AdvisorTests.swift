import Foundation
@testable import SliceKit
import XCTest

final class AdvisorTests: XCTestCase {
    func ids(_ r: [Recommendation]) -> Set<String> { Set(r.map(\.id)) }

    func testOverhangSuggestsSupport() throws {
        let t = try XCTUnwrap(PlateArranger.arrange([ModelObject(name: "T", mesh: Fixtures.tShape())], bedSize: 270))
        var s = PrintSettings()
        let recs = PrintAdvisor.recommendations(objects: t, settings: s)
        let support = try XCTUnwrap(recs.first { $0.id == "support" })
        XCTAssertEqual(support.action, .support(.buildPlateOnly))
        var objects = t
        try PrintAdvisor.apply(support.action!, settings: &s, objects: &objects)
        XCTAssertEqual(s.support, .buildPlateOnly)
        XCTAssertFalse(ids(PrintAdvisor.recommendations(objects: t, settings: s)).contains("support"))
    }

    func testFlatTopSuggestsIroningAndSmallSuggestsFine() throws {
        let cube = try XCTUnwrap(PlateArranger.arrange([ModelObject(name: "C", mesh: Fixtures.box(40, 40, 10))], bedSize: 270))
        XCTAssertTrue(ids(PrintAdvisor.recommendations(objects: cube, settings: PrintSettings())).contains("ironing"))
        let tiny = try XCTUnwrap(PlateArranger.arrange([ModelObject(name: "c", mesh: Fixtures.box(8, 8, 8))], bedSize: 270))
        let recs = PrintAdvisor.recommendations(objects: tiny, settings: PrintSettings())
        XCTAssertTrue(ids(recs).contains("fine"))
        XCTAssertFalse(ids(recs).contains("brim"), "a small cube does not tip over (Bambu/Orca auto brim)")
        let pillar = try XCTUnwrap(PlateArranger.arrange([ModelObject(name: "p", mesh: Fixtures.box(8, 8, 60))], bedSize: 270))
        XCTAssertTrue(ids(PrintAdvisor.recommendations(objects: pillar, settings: PrintSettings())).contains("brim"), "8 × 8 × 60 mm tips over")
    }

    func testTooLargeSplitsAutomatically() throws {
        var s = PrintSettings(printer: .kobraS1)
        var objects = [ModelObject(name: "Long", mesh: Fixtures.box(400, 40, 20))]
        let recs = PrintAdvisor.recommendations(objects: objects, settings: s)
        let split = try XCTUnwrap(recs.first { $0.id.hasPrefix("split-") })
        XCTAssertEqual(split.severity, .warning)
        try PrintAdvisor.apply(split.action!, settings: &s, objects: &objects)
        XCTAssertGreaterThan(objects.count, 2)
        let out = try SliceJob(name: "split", objects: objects, settings: s).run()
        XCTAssertFalse(out.layers.isEmpty)
    }

    func testLoadedFilamentMismatch() throws {
        var s = PrintSettings(printer: .kobraS1)
        var objects = try XCTUnwrap(PlateArranger.arrange([ModelObject(name: "C", mesh: Fixtures.box(20, 20, 20), tool: 1)], bedSize: 250))
        let recs = PrintAdvisor.recommendations(objects: objects, settings: s, loadedTypes: ["PLA", "PETG", nil, nil])
        let mismatch = try XCTUnwrap(recs.first { $0.id == "mismatch-1" })
        try PrintAdvisor.apply(mismatch.action!, settings: &s, objects: &objects)
        XCTAssertEqual(s.filaments[1].type, "PETG")
        let empty = PrintAdvisor.recommendations(objects: objects, settings: s, loadedTypes: ["PLA", "NONE"])
        XCTAssertTrue(ids(empty).contains("empty-1"))
    }

    func testMultiColorKobraWithoutTowerWarns() throws {
        var s = PrintSettings(printer: .kobraS1)
        s.primeTower = false; s.primeTowerAuto = false
        let objs = try XCTUnwrap(PlateArranger.arrange([
            ModelObject(name: "A", mesh: Fixtures.box(20, 20, 5), tool: 0),
            ModelObject(name: "B", mesh: Fixtures.box(20, 20, 5), tool: 1),
        ], bedSize: 250))
        XCTAssertTrue(ids(PrintAdvisor.recommendations(objects: objs, settings: s)).contains("tower"))
    }

    func testSnapmakerForumTipsForBrimAndSupport() throws {
        let t = try XCTUnwrap(PlateArranger.arrange([ModelObject(name: "T", mesh: Fixtures.tShape())], bedSize: 270))
        var s = PrintSettings()
        s.support = .buildPlateOnly
        s.layerHeight = 0.2
        s.supportTopZDistance = 0.2
        var recs = PrintAdvisor.recommendations(objects: t, settings: s)
        XCTAssertEqual(recs.first { $0.id == "support-z" }?.action, .supportTopZ(0.25), "0.25 mm at 0.2 mm layers")
        s.filaments[0] = try XCTUnwrap(FilamentLibrary.bestMatch(type: "PETG", printer: s.printer))
        s.supportInterfaceSlot = 1
        recs = PrintAdvisor.recommendations(objects: t, settings: s)
        XCTAssertEqual(recs.first { $0.id == "support-foot" }?.action, .supportTopZ(0), "PLA contact on a PETG part: 0 mm")
        XCTAssertNil(recs.first { $0.id == "support-z" }, "one rule per situation")
        s.brimWidth = 5
        s.elephantFootCompensation = 0.15
        recs = PrintAdvisor.recommendations(objects: t, settings: s)
        var objects = t
        let gap = try XCTUnwrap(recs.first { $0.id == "brim-gap" })
        try PrintAdvisor.apply(gap.action!, settings: &s, objects: &objects)
        XCTAssertEqual(s.elephantFootCompensation, 0)
    }

    /// The setting a tip changes, as (name, value). Tips that change the same setting must not both be shown with different values.
    private func settingChanges(_ action: Recommendation.Action) -> [(String, String)] {
        switch action {
        case .supportTopZ(let z): return [("support top z", "\(z)")]
        case .supportDistances(let z, let xy): return [("support top z", "\(z)"), ("support xy", "\(xy)")]
        case .elephantFoot(let v): return [("elephant foot", "\(v)")]
        case .brim(let w): return [("brim", "\(w)")]
        case .zHop(let v): return [("z hop", "\(v)")]
        case .retraction(let slot, let length): return [("retraction \(slot)", "\(length)")]
        case .filamentNozzle(let slot, let temp): return [("nozzle \(slot)", "\(temp)")]
        case .filamentFan(let slot, let speed): return [("fan \(slot)", "\(speed)")]
        case .support(let mode): return [("support", "\(mode)")]
        default: return []
        }
    }

    /// For every material combination: tips never set one setting to two values, and applying a tip never brings
    /// the same tip back with a new value (that was the back and forth on the printer).
    func testRecommendationsDoNotPushEachOtherBackAndForth() throws {
        let t = try XCTUnwrap(PlateArranger.arrange([ModelObject(name: "T", mesh: Fixtures.tShape())], bedSize: 270))
        for partType in ["PETG", "PLA"] {
            for contactType in [nil, "PETG", "PLA"] {
                for topZ in [0.0, 0.2] {
                    for brim in [0.0, 5.0] {
                        var s = PrintSettings(printer: .snapmakerU1)
                        s.support = .buildPlateOnly
                        s.filaments[0] = try XCTUnwrap(FilamentLibrary.bestMatch(type: partType, printer: s.printer))
                        if let contactType {
                            s.filaments[1] = try XCTUnwrap(FilamentLibrary.bestMatch(type: contactType, printer: s.printer))
                            s.supportInterfaceSlot = 1
                        }
                        s.supportTopZDistance = topZ
                        s.brimWidth = brim
                        s.zHop = 0.4
                        s.filaments[0].nozzleTemp = 250
                        s.filaments[0].retractLength = 1.0
                        let case_ = "part \(partType), contact \(contactType ?? "part"), z \(topZ), brim \(brim)"
                        let recs = PrintAdvisor.recommendations(objects: t, settings: s)
                        var seen: [String: String] = [:]
                        for rec in recs {
                            for (name, value) in rec.action.map(settingChanges) ?? [] {
                                if let other = seen[name] {
                                    XCTAssertEqual(other, value, "\(case_): \"\(name)\" set to two values")
                                }
                                seen[name] = value
                            }
                        }
                        for rec in recs {
                            guard let action = rec.action else { continue }
                            var after = s
                            var objects = t
                            try PrintAdvisor.apply(action, settings: &after, objects: &objects)
                            let again = PrintAdvisor.recommendations(objects: objects, settings: after)
                            if let back = again.first(where: { $0.id == rec.id }) {
                                XCTAssertNil(back.action, "\(case_): \(rec.id) comes back with a new value")
                            }
                        }
                    }
                }
            }
        }
    }

    /// PETG tips quote the PETG in the slot with its own values, and vanish once those values are the advised ones.
    func testPETGTipsUseTheFilamentInTheSlot() throws {
        // The part prints from slot 2, so the PETG in slot 2 is the one in use.
        let t = try XCTUnwrap(PlateArranger.arrange([ModelObject(name: "T", mesh: Fixtures.tShape(), tool: 1)], bedSize: 270))
        var s = PrintSettings(printer: .snapmakerU1)
        s.filaments[1] = try XCTUnwrap(FilamentLibrary.bestMatch(type: "PETG", printer: s.printer))
        s.filaments[1].nozzleTemp = 250
        s.filaments[1].retractLength = 1.0
        var objects = t
        let temp = try XCTUnwrap(PrintAdvisor.recommendations(objects: t, settings: s).first { $0.id == "petg-temp-1" })
        XCTAssertTrue(temp.title.contains(s.filaments[1].name), "the tip names the filament in the slot")
        XCTAssertEqual(temp.action, .filamentNozzle(slot: 1, temp: 240))
        XCTAssertEqual(PrintAdvisor.recommendations(objects: t, settings: s).first { $0.id == "petg-retract-1" }?.action, .retraction(slot: 1, length: 0.6))
        try PrintAdvisor.apply(temp.action!, settings: &s, objects: &objects)
        XCTAssertEqual(s.filaments[1].nozzleTemp, 240)
        XCTAssertNil(PrintAdvisor.recommendations(objects: t, settings: s).first { $0.id == "petg-temp-1" })
    }

    /// Vase mode: the advice to switch supports off must not be undone by the advice to switch them on.
    func testVaseModeDoesNotTurnSupportsBackOn() throws {
        var objs = [ModelObject(name: "Overhang", mesh: Fixtures.tShape())]
        var s = PrintSettings()
        s.support = .buildPlateOnly
        s.spiralVase = true
        let recs = PrintAdvisor.recommendations(objects: objs, settings: s)
        let off = try XCTUnwrap(recs.first { $0.id == "vase-support" })
        XCTAssertEqual(off.action, .support(.off))
        try PrintAdvisor.apply(off.action!, settings: &s, objects: &objs)
        let after = PrintAdvisor.recommendations(objects: objs, settings: s).map(\.id)
        XCTAssertFalse(after.contains("support"))
        XCTAssertFalse(after.contains("support-everywhere"))
        XCTAssertFalse(after.contains("vase-support"))
    }

    func testSurfaceAndPETGSupportTips() throws {
        let t = try XCTUnwrap(PlateArranger.arrange([ModelObject(name: "T", mesh: Fixtures.tShape())], bedSize: 270))
        var s = PrintSettings()
        s.layerHeight = 0.12
        s.outerWallSpeed = 200
        var objects = t
        var recs = PrintAdvisor.recommendations(objects: t, settings: s)
        let speed = try XCTUnwrap(recs.first { $0.id == "surface-speed" })
        try PrintAdvisor.apply(speed.action!, settings: &s, objects: &objects)
        XCTAssertEqual(s.outerWallSpeed, 100)
        s.layerHeight = 0.2
        recs = PrintAdvisor.recommendations(objects: t, settings: s)
        XCTAssertNil(recs.first { $0.id == "surface-speed" }, "not asked for normal layers")
        s.support = .buildPlateOnly
        s.filaments[0] = try XCTUnwrap(FilamentLibrary.bestMatch(type: "PETG", printer: s.printer))
        recs = PrintAdvisor.recommendations(objects: t, settings: s)
        let petg = try XCTUnwrap(recs.first { $0.id == "support-petg" })
        try PrintAdvisor.apply(petg.action!, settings: &s, objects: &objects)
        XCTAssertEqual(s.supportTopZDistance, 0.28, accuracy: 1e-9)
        XCTAssertEqual(s.supportXYDistance, 0.6, accuracy: 1e-9)
    }

    func testU1TowerPETGHopAndKobraTips() throws {
        let objs = [ModelObject(name: "A", mesh: Fixtures.box(20, 20, 20), tool: 0), ModelObject(name: "B", mesh: Fixtures.box(20, 20, 20), tool: 1)]
        var s = PrintSettings(printer: .snapmakerU1)
        s.primeTower = true
        s.purgeVolume = 0
        s.primeTowerWidth = 35
        var recs = PrintAdvisor.recommendations(objects: objs, settings: s)
        var o = objs
        let waste = try XCTUnwrap(recs.first { $0.id == "u1-tower-waste" })
        try PrintAdvisor.apply(waste.action!, settings: &s, objects: &o)
        XCTAssertEqual(s.primeTowerWidth, 25)
        XCTAssertEqual(s.purgeVolume, 15)
        s.primeTower = false; s.primeTowerAuto = false
        recs = PrintAdvisor.recommendations(objects: objs, settings: s)
        XCTAssertEqual(recs.first { $0.id == "u1-tower" }?.action, .primeTower(true))
        s.filaments[0] = try XCTUnwrap(FilamentLibrary.bestMatch(type: "PETG", printer: s.printer))
        s.zHop = 0.4
        recs = PrintAdvisor.recommendations(objects: objs, settings: s)
        let hop = try XCTUnwrap(recs.first { $0.id == "petg-zhop" })
        try PrintAdvisor.apply(hop.action!, settings: &s, objects: &o)
        XCTAssertEqual(s.zHop, 0)
        let kobra = PrintAdvisor.recommendations(objects: objs, settings: PrintSettings(printer: .kobraS1))
        XCTAssertTrue(kobra.contains { $0.id == "kobra-spaghetti" })
    }

    /// With a brim the advisor must not ask for elephant-foot compensation and then for removing it again.
    func testElephantFootAndBrimTipsDoNotAlternate() throws {
        var objs = [ModelObject(name: "A", mesh: Fixtures.box(8, 8, 40))]
        var s = PrintSettings(printer: .snapmakerU1)
        s.filaments[0] = try XCTUnwrap(FilamentLibrary.bestMatch(type: "PETG", printer: s.printer))
        s.elephantFootCompensation = 0
        s.brimWidth = 0
        XCTAssertTrue(ids(PrintAdvisor.recommendations(objects: objs, settings: s)).contains("petg-foot"))
        s.brimWidth = 10
        for _ in 0..<3 {
            let recs = PrintAdvisor.recommendations(objects: objs, settings: s)
            XCTAssertFalse(ids(recs).contains("petg-foot"))
            guard let gap = recs.first(where: { $0.id == "brim-gap" }) else { break }
            try PrintAdvisor.apply(gap.action!, settings: &s, objects: &objs)
        }
        let recs = ids(PrintAdvisor.recommendations(objects: objs, settings: s))
        XCTAssertFalse(recs.contains("brim-gap")); XCTAssertFalse(recs.contains("petg-foot"))
        XCTAssertEqual(s.elephantFootCompensation, 0)
    }

    /// PLA supports on a PETG part stay PLA (easy to remove) but get a dense foot where they stand on the part.
    func testSupportOfAMaterialThatDoesNotBondGetsADenseFoot() throws {
        // A table: the support under the top stands on the base plate of the part.
        var table = TriangleMesh()
        for part in [Fixtures.box(30, 30, 2), Fixtures.box(6, 30, 13, at: Vec3(0, 0, 1.5)), Fixtures.box(30, 30, 2, at: Vec3(0, 0, 14))] {
            table.indices += part.indices.map { $0 + UInt32(table.vertices.count) }
            table.vertices += part.vertices
        }
        var objs = [ModelObject(name: "A", mesh: table, tool: 0)]
        var s = PrintSettings(printer: .snapmakerU1)
        s.filaments[0] = try XCTUnwrap(FilamentLibrary.bestMatch(type: "PETG", printer: s.printer))
        s.support = .everywhere
        s.supportSlot = 1   // PLA
        let rec = try XCTUnwrap(PrintAdvisor.recommendations(objects: objs, settings: s).first { $0.id == "support-foot" })
        XCTAssertEqual(rec.severity, .info)
        try PrintAdvisor.apply(rec.action!, settings: &s, objects: &objs)
        XCTAssertEqual(s.supportSlot, 1, "the supports keep their own material"); XCTAssertEqual(s.supportTopZDistance, 0)

        func footLength(_ s: PrintSettings) throws -> Double {
            let arranged = try XCTUnwrap(PlateArranger.arrange(objs, bedSize: s.bedSize))
            let layers = try Slicer(settings: s).slice(arranged)
            // Support lines in the two layers right above the base plate (z 2…2.5).
            var length = 0.0
            for layer in layers where layer.z > 2.05 && layer.z < 2.5 {
                for e in layer.islands.flatMap(\.extrusions) where e.role == .support || e.role == .supportInterface {
                    for (p, q) in zip(e.points, e.points.dropFirst()) { length += hypot(q.mmX - p.mmX, q.mmY - p.mmY) }
                }
            }
            return length
        }
        let dense = try footLength(s)
        s.supportSlot = nil   // same material as the part: the usual thin lines
        let thin = try footLength(s)
        XCTAssertGreaterThan(thin, 0)
        XCTAssertGreaterThan(dense, thin * 2.5, "closed foot instead of thin lines")
    }

    func testIroningIsOnlyAHintForPETG() throws {
        let cube = [ModelObject(name: "A", mesh: Fixtures.box(40, 40, 10))]
        var s = PrintSettings(printer: .snapmakerU1)
        var recs = PrintAdvisor.recommendations(objects: cube, settings: s)
        let pla = try XCTUnwrap(recs.first { $0.id == "ironing" })
        XCTAssertEqual(pla.action, .ironingTuned(speed: 20, flow: 0.10, spacing: 0.1))
        s.filaments[0] = try XCTUnwrap(FilamentLibrary.bestMatch(type: "PETG", printer: s.printer))
        recs = PrintAdvisor.recommendations(objects: cube, settings: s)
        XCTAssertFalse(recs.contains { $0.id == "ironing" })
        let petg = try XCTUnwrap(recs.first { $0.id == "ironing-petg" })
        XCTAssertEqual(petg.severity, .info)
        var o = cube
        try PrintAdvisor.apply(petg.action!, settings: &s, objects: &o)
        XCTAssertTrue(s.ironing); XCTAssertEqual(s.ironingSpeed, 15); XCTAssertEqual(s.ironingSpacing, 0.1)
    }

    func testFanAdviceForPETGAndABS() throws {
        let objs = [ModelObject(name: "A", mesh: Fixtures.box(20, 20, 20))]
        var s = PrintSettings()
        var petg = try XCTUnwrap(FilamentLibrary.bestMatch(type: "PETG", printer: s.printer))
        petg.fanSpeed = 0.9
        s.filaments[0] = petg
        var o = objs
        let rec = try XCTUnwrap(PrintAdvisor.recommendations(objects: objs, settings: s).first { $0.id == "fan-petg-0" })
        try PrintAdvisor.apply(rec.action!, settings: &s, objects: &o)
        XCTAssertEqual(s.filaments[0].fanSpeed, 0.4)
        XCTAssertNil(PrintAdvisor.recommendations(objects: objs, settings: s).first { $0.id == "fan-petg-0" })
    }

    func testQuietAirGCodeForTheU1() throws {
        var s = PrintSettings(printer: .snapmakerU1)
        let arranged = try XCTUnwrap(PlateArranger.arrange([ModelObject(name: "c", mesh: Fixtures.box(20, 20, 6))], bedSize: s.bedSize))
        let quiet = try SliceJob(name: "q", objects: arranged, settings: s).run().gcode
        XCTAssertTrue(quiet.contains("SET_PURIFIER_MODE MODE=1 DESIRE_TEMP=42 ALARM_TEMP=48 FAN_SPEED=0.30"), "exhaust starts low")
        XCTAssertTrue(quiet.contains("SET_PURIFIER FAN=inner SPEED=0.35"), "filter fan at 35 %")
        s.quietAir = false
        let normal = try SliceJob(name: "n", objects: arranged, settings: s).run().gcode
        XCTAssertTrue(normal.contains("FAN_SPEED=0.6"))
        XCTAssertFalse(normal.contains("SET_PURIFIER FAN=inner"))
    }
}
