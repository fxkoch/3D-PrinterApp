import ClaudeKit
import Foundation
@testable import PrintAssistant
@testable import PrinterKit
@testable import SliceKit
import XCTest

@MainActor
final class PrintAssistantTests: XCTestCase {
    var host: FakeHost!
    var box: AssistantToolbox!

    override func setUp() async throws {
        host = FakeHost()
        box = AssistantToolbox(host: host)
    }

    func json(_ output: ToolOutput) throws -> JSONValue {
        XCTAssertFalse(output.isError, output.content)
        return try JSONDecoder().decode(JSONValue.self, from: Data(output.content.utf8))
    }

    func testToolDefinitionsAreValid() async {
        let names = AssistantToolbox.tools.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "unique names")
        for tool in AssistantToolbox.tools {
            XCTAssertEqual(tool.inputSchema["type"]?.string, "object", tool.name)
            XCTAssertNotNil(tool.inputSchema["properties"]?.object, tool.name)
            XCTAssertTrue(tool.name.allSatisfy { $0.isLowercase || $0 == "_" }, tool.name)
            for req in tool.inputSchema["required"]?.array ?? [] {
                XCTAssertNotNil(tool.inputSchema["properties"]?[req.string ?? ""], "\(tool.name): \(req)")
            }
        }
    }

    func testOverviewAndPrinterStatusAreLive() async throws {
        var o = try json(await box.run("get_overview", [:]))
        XCTAssertEqual(o["printers"]?.array?.count, 2)
        XCTAssertEqual(o["open_project"]?["objects"]?.int, 2)
        XCTAssertEqual(o["printers"]?.array?.first?["progress_percent"]?.int, 42)

        host.printers[0].status?.progress = 0.5
        o = try json(await box.run("get_overview", [:]))
        XCTAssertEqual(o["printers"]?.array?.first?["progress_percent"]?.int, 50, "reads the current value")

        let s = try json(await box.run("get_printer_status", ["printer": "kobra"]))
        let kobra = try XCTUnwrap(s.array?.first)
        XCTAssertEqual(kobra["name"]?.string, "Kobra im Keller")
        XCTAssertEqual(kobra["ace_pro"]?["humidity_percent"]?.number, 48)
        XCTAssertEqual(kobra["loaded_filament"]?.array?.first?["name"]?.string, "Anycubic PETG")
    }

    func testProjectDescription() async throws {
        let p = try json(await box.run("get_project", [:]))
        XCTAssertEqual(p["objects"]?.array?.first?["size_mm"]?["x"]?.number, 20)
        XCTAssertEqual(p["settings"]?["layerHeight"]?.number, 0.2)
        XCTAssertNil(p["settings"]?["filaments"])
        XCTAssertEqual(p["recommendations"]?.array?.first?["id"]?.string, "brim")
        XCTAssertEqual(p["slice"]?["state"]?.string, "nicht geslicet")
    }

    func testUpdateSettings() async throws {
        let out = await box.run("update_print_settings", ["changes": ["layerHeight": 0.12, "infillDensity": 25,
                                                                       "support": "buildPlateOnly", "ironing": true]])
        XCTAssertFalse(out.isError, out.content)
        XCTAssertTrue(out.content.contains("layerHeight: 0.2 → 0.12"), out.content)
        let s = host.project!.settings
        XCTAssertEqual(s.layerHeight, 0.12)
        XCTAssertEqual(s.infillDensity, 0.25, accuracy: 1e-9)
        XCTAssertEqual(s.support, .buildPlateOnly)
        XCTAssertTrue(s.ironing)
    }

    func testUpdateSettingsRejectsBadInput() async {
        let before = host.project!.settings
        for changes: JSONValue in [["layerHeight": 0.8], ["support": "trees"], ["foo": 1], ["printer": "kobraS1"],
                                   ["wallLoops": 2.5], ["ironing": "vielleicht"]] {
            let out = await box.run("update_print_settings", ["changes": changes])
            XCTAssertTrue(out.isError, "\(changes) → \(out.content)")
        }
        XCTAssertEqual(host.project!.settings, before, "nothing applied")
        let enumError = await box.run("update_print_settings", ["changes": ["support": "trees"]])
        XCTAssertTrue(enumError.content.contains("buildPlateOnly"), "lists allowed values")
    }

    func testSetFilament() async throws {
        var out = await box.run("set_filament", ["slot": 2, "type": "PETG", "color": "#ff0000"])
        XCTAssertFalse(out.isError, out.content)
        XCTAssertEqual(host.project!.settings.filaments[1].type.uppercased().hasPrefix("PETG"), true)
        XCTAssertEqual(host.project!.settings.filaments[1].color, "#FF0000")
        out = await box.run("set_filament", ["slot": 9, "type": "PLA"])
        XCTAssertTrue(out.isError)
        let profiles = try json(await box.run("list_filament_profiles", ["query": "petg"]))
        XCTAssertFalse(profiles.array?.isEmpty ?? true)
        let name = try XCTUnwrap(profiles.array?.first?["name"]?.string)
        out = await box.run("set_filament", ["slot": 1, "profile": .string(name)])
        XCTAssertFalse(out.isError, out.content)
        XCTAssertEqual(host.project!.settings.filaments[0].name, name)
    }

    func testEditObjectAndRecommendation() async {
        var out = await box.run("edit_object", ["object": 1, "action": "scale", "value": 2])
        XCTAssertFalse(out.isError, out.content)
        XCTAssertEqual(host.edits.last?.1, .scale(factor: 2))
        out = await box.run("edit_object", ["object": 1, "action": "scale", "value": 50])
        XCTAssertTrue(out.isError, "too big for the bed")
        out = await box.run("edit_object", ["object": 3, "action": "remove"])
        XCTAssertTrue(out.isError)
        out = await box.run("edit_object", ["object": 2, "action": "set_slot", "value": 3])
        XCTAssertEqual(host.edits.last?.1, .setSlot(3))
        out = await box.run("apply_recommendation", ["id": "brim"])
        XCTAssertEqual(out.content, "Übernommen: Brim hinzufügen")
        out = await box.run("apply_recommendation", ["id": "nope"])
        XCTAssertTrue(out.isError)
    }

    func testPrinterCommandsNeedConfirmation() async {
        host.confirmAnswer = false
        var out = await box.run("printer_command", ["command": "cancel"])
        XCTAssertFalse(out.isError)
        XCTAssertTrue(out.content.contains("abgelehnt"))
        XCTAssertTrue(host.commands.isEmpty, "nothing sent without consent")
        XCTAssertEqual(host.confirmations.last?.0, "Druck abbrechen?")

        host.confirmAnswer = true
        out = await box.run("printer_command", ["command": "set_bed_temperature", "value": 60, "printer": "Kobra"])
        XCTAssertFalse(out.isError, out.content)
        XCTAssertEqual(host.commands.last?.0, .bedTemperature(60))
        XCTAssertEqual(host.commands.last?.1, "Kobra im Keller")

        out = await box.run("printer_command", ["command": "set_nozzle_temperature", "value": 400])
        XCTAssertTrue(out.isError, "out of range")
    }

    func testSendNeedsSliceAndConfirmation() async {
        var out = await box.run("send_to_printer", [:])
        XCTAssertTrue(out.isError, "not sliced yet")
        out = await box.run("slice", [:])
        XCTAssertFalse(out.isError, out.content)
        XCTAssertTrue(out.content.contains("\"print_time\":\"1 h 5 min\""), out.content)
        host.confirmAnswer = false
        out = await box.run("send_to_printer", ["start_print": true])
        XCTAssertTrue(out.content.contains("abgelehnt"))
        XCTAssertEqual(host.sent, 0)
        host.confirmAnswer = true
        out = await box.run("send_to_printer", ["start_print": true])
        XCTAssertEqual(host.sent, 1)
        XCTAssertTrue(host.confirmations.last?.1.contains("1 h 5 min") ?? false)
    }

    func testCloudSliceOnlyWhenConfigured() async {
        let out = await box.run("slice", ["cloud": true])
        XCTAssertTrue(out.isError)
    }

    func testNoProjectExplainsWhatToDo() async {
        host.project = nil
        let out = await box.run("get_project", [:])
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.content.contains("open_library_item"))
    }

    func testLibraryAndLog() async throws {
        let lib = try json(await box.run("list_library", [:]))
        XCTAssertEqual(lib.array?.first?["name"]?.string, "Benchy")
        let out = await box.run("open_library_item", ["index": 1])
        XCTAssertEqual(out.content, "Geöffnet: Benchy")
        let bad = await box.run("open_library_item", ["index": 5])
        XCTAssertTrue(bad.isError)
        let log = try json(await box.run("get_event_log", ["limit": 1]))
        XCTAssertEqual(log.array?.count, 1)
    }

    func testUnknownTool() async {
        let out = await box.run("rm_rf", [:])
        XCTAssertTrue(out.isError)
    }
}

// MARK: - Fake app

@MainActor
final class FakeHost: AssistantHost {
    var printers: [AssistantPrinter]
    var project: AssistantProject?
    var edits: [(Int, ObjectEdit)] = []
    var commands: [(PrinterCommand, String)] = []
    var confirmations: [(String, String)] = []
    var confirmAnswer = true
    var sent = 0
    var selected = "U1 Werkstatt"

    init() {
        var u1 = PrinterStatus()
        u1.state = .printing
        u1.progress = 0.42
        u1.printDuration = 1800
        u1.bed = .init(temperature: 60, target: 60)
        u1.tools = [.init(temperature: 220, target: 220)]
        var kobra = PrinterStatus()
        kobra.state = .standby
        kobra.filaments = [.init(present: true, vendor: "Anycubic", type: "PETG", color: "#112233")]
        var box = PrinterStatus.FilamentBox()
        box.humidity = 48
        kobra.filamentBox = box
        printers = [
            AssistantPrinter(name: "U1 Werkstatt", model: .snapmakerU1, host: "u1.local", isSelected: true, status: u1, error: nil),
            AssistantPrinter(name: "Kobra im Keller", model: .kobraS1, host: "192.168.1.9", isSelected: false, status: kobra, error: nil),
        ]
        project = AssistantProject(
            name: "Testprojekt",
            objects: [AssistantObject(index: 1, name: "Würfel", size: Vec3(20, 20, 20), slot: 1),
                      AssistantObject(index: 2, name: "Deckel", size: Vec3(40, 40, 3), slot: 1)],
            settings: PrintSettings(printer: .snapmakerU1),
            recommendations: [Recommendation(id: "brim", title: "Brim hinzufügen", detail: "kleine Auflage", icon: "x",
                                             severity: .suggestion, action: .brim(5))],
            slice: .idle, warning: nil)
    }

    var assistantPrinters: [AssistantPrinter] {
        printers.map { var p = $0; p.isSelected = p.name == selected; return p }
    }
    var assistantProject: AssistantProject? { project }
    var assistantLibrary: [AssistantLibraryItem] { [AssistantLibraryItem(name: "Benchy", source: "Printables", added: Date())] }
    var cloudSlicingAvailable: Bool { false }

    func assistantEvents(limit: Int) -> [PrinterEvent] {
        Array([PrinterEvent(level: .error, message: "Düse verstopft", source: "U1"),
               PrinterEvent(level: .info, message: "Druck gestartet", source: "U1")].prefix(limit))
    }

    func assistantSetSettings(_ settings: PrintSettings) throws {
        project?.settings = settings
        project?.slice = .idle
    }

    func assistantEdit(object index: Int, _ edit: ObjectEdit) throws { edits.append((index, edit)) }
    func assistantApply(recommendationID: String) throws { project?.settings.brimWidth = 5 }

    func assistantSlice(cloud: Bool) async throws -> (PrintEstimate, engine: String) {
        let e = PrintEstimate(seconds: 3900, filamentMM: [0: 1000], filamentGrams: [0: 12.3], layerCount: 100, toolChanges: 0)
        project?.slice = .done(e, engine: "Test")
        return (e, "Test")
    }

    func assistantSelectPrinter(named name: String) throws { selected = name }
    func assistantRun(_ command: PrinterCommand, on printerName: String) async throws { commands.append((command, printerName)) }
    func assistantSend(startPrint: Bool) async throws -> String { sent += 1; return "Druck gestartet." }
    func assistantOpenLibrary(index: Int) async throws -> String { "Geöffnet: Benchy" }
    func assistantImport(data: Data, fileName: String, title: String) async throws -> String { "Geöffnet: \(title)" }

    func assistantConfirm(title: String, detail: String) async -> Bool {
        confirmations.append((title, detail))
        return confirmAnswer
    }
}
