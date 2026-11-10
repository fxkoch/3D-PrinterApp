import ClaudeKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MakerWorldKit
import PrinterKit
import SliceKit

/// The tools Claude gets in MakerSlice, and their execution against the live app.
@MainActor
public final class AssistantToolbox {
    public weak var host: AssistantHost?
    let printables: PrintablesClient

    public init(host: AssistantHost?, session: URLSession = .shared) {
        self.host = host
        self.printables = PrintablesClient(session: session)
    }

    // MARK: - Definitions

    private static func schema(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }),
         "additionalProperties": false]
    }

    public static let tools: [ClaudeTool] = [
        ClaudeTool(name: "get_overview",
                   description: "Live-Überblick über die App: eingerichtete Drucker (online, Zustand, ausgewählt), ob ein Projekt geöffnet ist, Anzahl Modelle in der Bibliothek, ob Cloud-Slicing eingerichtet ist. Zuerst aufrufen, wenn unklar ist, worum es geht.",
                   inputSchema: schema()),
        ClaudeTool(name: "get_printer_status",
                   description: "Live-Zustand eines Druckers: Druckfortschritt, Restzeit, Schicht, Temperaturen (Bett, Düsen, Kammer), Lüfter, Licht, eingelegtes Filament je Slot (RFID/ACE Pro), ACE-Pro-Feuchte und Trocknung, Fehlermeldung. Ohne Namen: alle Drucker.",
                   inputSchema: schema(["printer": ["type": "string", "description": "Name des Druckers (optional)"]])),
        ClaudeTool(name: "get_project",
                   description: "Das geöffnete Druckprojekt live: Objekte (Nummer, Name, Größe in mm, Material-Slot), alle Slicer-Einstellungen mit ihren Schlüsseln, Material je Slot, offene Empfehlungen mit IDs, Slice-Zustand mit Druckzeit und Filamentverbrauch, Warnungen.",
                   inputSchema: schema()),
        ClaudeTool(name: "update_print_settings",
                   description: "Ändert Slicer-Einstellungen des geöffneten Projekts. Schlüssel genau wie in get_project → settings (z. B. layerHeight in mm, infillDensity 0…1, infillPattern, wallLoops, support = off/buildPlateOnly/everywhere, brimWidth in mm, ironing, seamPosition, spiralVase, fuzzySkin, plateType). Die Änderung wird sofort übernommen und ist in der App sichtbar; ein vorhandenes Slice-Ergebnis verfällt.",
                   inputSchema: schema(["changes": ["type": "object", "description": "Schlüssel → neuer Wert",
                                                    "additionalProperties": true]], required: ["changes"])),
        ClaudeTool(name: "list_filament_profiles",
                   description: "Sucht Filamentprofile für den Drucker des Projekts (Name, Hersteller, Typ, Temperaturen). Ohne Suchbegriff: die druckereigenen Profile.",
                   inputSchema: schema(["query": ["type": "string", "description": "z. B. „PETG“, „Polymaker“, „Silk“"]])),
        ClaudeTool(name: "set_filament",
                   description: "Setzt das Material eines Slots im geöffneten Projekt: per Profilname (aus list_filament_profiles) oder Materialtyp (PLA, PETG, TPU, ABS, ASA …), optional mit Farbe #RRGGBB.",
                   inputSchema: schema(["slot": ["type": "integer", "description": "Slot 1–4"],
                                        "profile": ["type": "string", "description": "Exakter Profilname"],
                                        "type": ["type": "string", "description": "Materialtyp, falls kein Profilname"],
                                        "color": ["type": "string", "description": "#RRGGBB"]], required: ["slot"])),
        ClaudeTool(name: "edit_object",
                   description: "Bearbeitet ein Objekt des Projekts (Nummer aus get_project): drehen um Z (value = Grad), skalieren (value = Faktor, 1.5 = 150 %), flach legen, duplizieren, entfernen, Material-Slot setzen (value = 1–4), automatisch passend teilen (zu große Teile mit Zapfen zerlegen). Die Platte wird danach neu angeordnet.",
                   inputSchema: schema(["object": ["type": "integer", "description": "Objektnummer (1 = erstes)"],
                                        "action": ["type": "string", "enum": ["rotate", "scale", "lay_flat", "duplicate", "remove", "set_slot", "auto_split"]],
                                        "value": ["type": "number"]], required: ["object", "action"])),
        ClaudeTool(name: "apply_recommendation",
                   description: "Übernimmt eine Empfehlung des Druckberaters (ID aus get_project → recommendations).",
                   inputSchema: schema(["id": ["type": "string"]], required: ["id"])),
        ClaudeTool(name: "slice",
                   description: "Slicet das geöffnete Projekt und wartet auf das Ergebnis (Druckzeit, Filament, Schichten). cloud = true nutzt OrcaSlicer in der Cloud (1–3 Minuten, nur wenn eingerichtet).",
                   inputSchema: schema(["cloud": ["type": "boolean"]])),
        ClaudeTool(name: "select_printer",
                   description: "Wählt den Drucker aus, an den gedruckt wird.",
                   inputSchema: schema(["name": ["type": "string"]], required: ["name"])),
        ClaudeTool(name: "printer_command",
                   description: "Steuert einen Drucker: pause, resume, cancel, set_bed_temperature (value °C, 0 = aus), set_nozzle_temperature (value °C, tool 1–4), light_on, light_off. Der Nutzer muss jeden Befehl in der App bestätigen.",
                   inputSchema: schema(["printer": ["type": "string", "description": "Name; ohne Angabe der ausgewählte Drucker"],
                                        "command": ["type": "string", "enum": ["pause", "resume", "cancel", "set_bed_temperature",
                                                                               "set_nozzle_temperature", "light_on", "light_off"]],
                                        "value": ["type": "number"], "tool": ["type": "integer"]], required: ["command"])),
        ClaudeTool(name: "send_to_printer",
                   description: "Schickt das geslicte Projekt an den ausgewählten Drucker und startet den Druck (start_print = false: nur hochladen). Der Nutzer muss bestätigen.",
                   inputSchema: schema(["start_print": ["type": "boolean"]])),
        ClaudeTool(name: "get_event_log",
                   description: "Die letzten Einträge des Ereignis- und Fehlerprotokolls (Drucker und App).",
                   inputSchema: schema(["limit": ["type": "integer", "description": "Standard 20"]])),
        ClaudeTool(name: "list_library",
                   description: "Modelle in der Bibliothek der App (Nummer, Name, Quelle, Datum).",
                   inputSchema: schema()),
        ClaudeTool(name: "open_library_item",
                   description: "Öffnet ein Modell aus der Bibliothek als Druckprojekt (ein offenes Projekt wird ersetzt).",
                   inputSchema: schema(["index": ["type": "integer", "description": "Nummer aus list_library"]], required: ["index"])),
        ClaudeTool(name: "search_models",
                   description: "Sucht kostenlose 3D-Modelle auf Printables (Titel, Autor, Likes, Downloads, ID, Link).",
                   inputSchema: schema(["query": ["type": "string"], "limit": ["type": "integer", "description": "Standard 8"]],
                                       required: ["query"])),
        ClaudeTool(name: "download_model",
                   description: "Lädt ein Printables-Modell (ID aus search_models) in die Bibliothek und öffnet es als Projekt. Optional eine bestimmte Datei per Name.",
                   inputSchema: schema(["model_id": ["type": "string"], "file": ["type": "string"]], required: ["model_id"])),
    ]

    public static let systemPrompt = """
    Du bist der Claude-Assistent in MakerSlice, einer iPhone-App zum Finden, Slicen und Drucken von 3D-Modellen \
    auf dem Snapmaker U1 und dem Anycubic Kobra S1 (mit ACE Pro). Du hast über Werkzeuge Live-Zugriff auf die App: \
    Druckerzustand, das geöffnete Projekt mit allen Slicer-Einstellungen, Bibliothek, Protokoll und Modellsuche. \
    Du kannst das Projekt mitgestalten: Einstellungen ändern, Material setzen, Objekte drehen, skalieren und teilen, \
    Empfehlungen übernehmen, slicen und – nach Bestätigung durch den Nutzer – drucken oder den Drucker steuern.

    So arbeitest du:
    - Antworte auf Deutsch, kurz und konkret, wie ein erfahrener Maker. Zahlen mit Einheit.
    - Hole aktuelle Daten immer über die Werkzeuge, statt zu raten; Werte ändern sich live.
    - Begründe Änderungen in einem Satz (z. B. „Brim 5 mm, weil die Auflagefläche klein ist“).
    - Ändere nur, was zur Bitte passt. Bei größeren Umbauten (Material, Skalierung, Teilen) erst kurz vorschlagen, \
    außer der Nutzer hat ausdrücklich darum gebeten.
    - Druckerbefehle und Drucken bestätigt der Nutzer selbst in der App; frage nicht zusätzlich im Text nach.
    - Achte auf Druckerbesonderheiten: TPU nicht über die ACE Pro; feuchtes Filament (ACE-Feuchte über ~40 %) trocknen; \
    Bauraum U1 270 mm, Kobra S1 250 mm.
    - Wenn kein Projekt offen ist und eines gebraucht wird, biete an, eines aus der Bibliothek zu öffnen oder ein Modell zu suchen.
    """

    // MARK: - Execution

    public func run(_ name: String, _ input: JSONValue) async -> ToolOutput {
        guard let host else { return .error("Die App ist nicht verfügbar.") }
        do {
            return ToolOutput(try await execute(name, input.object ?? [:], host))
        } catch let error as AssistantError {
            return .error(error.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func execute(_ name: String, _ input: [String: JSONValue], _ host: AssistantHost) async throws -> String {
        switch name {
        case "get_overview":
            return overview(host).jsonString
        case "get_printer_status":
            let wanted = try printers(named: input["printer"]?.string, host, allIfNil: true)
            return JSONValue.array(wanted.map(describe)).jsonString
        case "get_project":
            return describe(try project(host)).jsonString
        case "update_print_settings":
            let p = try project(host)
            guard let changes = input["changes"]?.object else { throw AssistantError("„changes“ fehlt.") }
            let (updated, summary) = try SettingsPatch.apply(changes, to: p.settings)
            try host.assistantSetSettings(updated)
            return summary.isEmpty ? "Keine Änderung – die Werte waren schon so." : "Übernommen: " + summary.joined(separator: "; ")
        case "list_filament_profiles":
            let printer = host.assistantProject?.settings.printer ?? host.assistantPrinters.first(where: \.isSelected)?.model ?? .snapmakerU1
            return filamentProfiles(query: input["query"]?.string, printer: printer).jsonString
        case "set_filament":
            return try setFilament(input, host)
        case "edit_object":
            return try editObject(input, host)
        case "apply_recommendation":
            let p = try project(host)
            guard let id = input["id"]?.string else { throw AssistantError("„id“ fehlt.") }
            guard let rec = p.recommendations.first(where: { $0.id == id }) else {
                throw AssistantError("Keine Empfehlung mit ID „\(id)“. Offene: \(p.recommendations.filter { $0.action != nil }.map(\.id).joined(separator: ", "))")
            }
            try host.assistantApply(recommendationID: id)
            return "Übernommen: \(rec.title)"
        case "slice":
            _ = try project(host)
            let cloud = input["cloud"]?.bool ?? false
            if cloud && !host.cloudSlicingAvailable {
                throw AssistantError("Cloud-Slicing ist nicht eingerichtet (Einstellungen → Profi-Slicing).")
            }
            let (estimate, engine) = try await host.assistantSlice(cloud: cloud)
            return describe(estimate, engine: engine).jsonString
        case "select_printer":
            guard let n = input["name"]?.string else { throw AssistantError("„name“ fehlt.") }
            let printer = try printers(named: n, host, allIfNil: false)[0]
            try host.assistantSelectPrinter(named: printer.name)
            return "Ausgewählt: \(printer.name) (\(printer.model.displayName))"
        case "printer_command":
            return try await printerCommand(input, host)
        case "send_to_printer":
            let p = try project(host)
            guard case .done(let estimate, _) = p.slice else {
                throw AssistantError("Das Projekt ist noch nicht geslicet. Rufe zuerst slice auf.")
            }
            guard let printer = host.assistantPrinters.first(where: \.isSelected) else {
                throw AssistantError("Kein Drucker eingerichtet.")
            }
            let start = input["start_print"]?.bool ?? true
            let detail = "„\(p.name)“ an \(printer.name): \(estimate.formattedTime), \(Int(estimate.totalGrams.rounded())) g Filament, \(p.settings.layerHeight) mm Schichthöhe."
            guard await host.assistantConfirm(title: start ? "Druck starten?" : "Auf den Drucker laden?", detail: detail) else {
                return "Der Nutzer hat abgelehnt. Nichts wurde gesendet."
            }
            return try await host.assistantSend(startPrint: start)
        case "get_event_log":
            let limit = max(1, min(input["limit"]?.int ?? 20, 100))
            let f = ISO8601DateFormatter()
            return JSONValue.array(host.assistantEvents(limit: limit).map {
                ["time": .string(f.string(from: $0.date)), "level": .string($0.level.rawValue), "source": .string($0.source),
                 "message": .string($0.message)]
            }).jsonString
        case "list_library":
            let f = ISO8601DateFormatter()
            return JSONValue.array(host.assistantLibrary.enumerated().map { i, item in
                ["index": .number(Double(i + 1)), "name": .string(item.name), "source": .string(item.source),
                 "added": .string(f.string(from: item.added))]
            }).jsonString
        case "open_library_item":
            guard let index = input["index"]?.int, (1...host.assistantLibrary.count).contains(index) else {
                throw AssistantError("Ungültige Nummer. Die Bibliothek hat \(host.assistantLibrary.count) Modelle.")
            }
            return try await host.assistantOpenLibrary(index: index)
        case "search_models":
            guard let q = input["query"]?.string, !q.isEmpty else { throw AssistantError("„query“ fehlt.") }
            let limit = max(1, min(input["limit"]?.int ?? 8, 20))
            let results = try await printables.search(q, limit: limit)
            return JSONValue.array(results.prefix(limit).map { r in
                var o: [String: JSONValue] = ["id": .string(r.modelID), "title": .string(r.title), "source": "Printables"]
                if let a = r.author { o["author"] = .string(a) }
                if let l = r.likes { o["likes"] = .number(Double(l)) }
                if let d = r.downloads { o["downloads"] = .number(Double(d)) }
                if let u = r.pageURL { o["url"] = .string(u.absoluteString) }
                return .object(o)
            }).jsonString
        case "download_model":
            guard let id = input["model_id"]?.string else { throw AssistantError("„model_id“ fehlt.") }
            let files = try await printables.files(modelID: id)
            guard !files.isEmpty else { throw AssistantError("Dieses Modell hat keine druckbaren Dateien.") }
            let wanted = input["file"]?.string?.lowercased()
            let file = wanted.flatMap { w in files.first { $0.name.lowercased().contains(w) } } ?? files[0]
            let data = try await printables.download(file, modelID: id)
            let title = (file.name as NSString).deletingPathExtension
            let opened = try await host.assistantImport(data: data, fileName: file.name, title: title)
            let others = files.filter { $0.id != file.id }.map(\.name)
            return opened + (others.isEmpty ? "" : " Weitere Dateien im Modell: \(others.prefix(10).joined(separator: ", "))")
        default:
            throw AssistantError("Unbekanntes Werkzeug „\(name)“.")
        }
    }

    // MARK: - Helpers

    private func project(_ host: AssistantHost) throws -> AssistantProject {
        guard let p = host.assistantProject else {
            throw AssistantError("Es ist kein Projekt geöffnet. Öffne ein Modell aus der Bibliothek (list_library / open_library_item) oder suche eines.")
        }
        return p
    }

    private func printers(named name: String?, _ host: AssistantHost, allIfNil: Bool) throws -> [AssistantPrinter] {
        let all = host.assistantPrinters
        guard !all.isEmpty else { throw AssistantError("Es ist noch kein Drucker eingerichtet (Tab „Drucker“).") }
        guard let name, !name.isEmpty else {
            return allIfNil ? all : [all.first(where: \.isSelected) ?? all[0]]
        }
        if let exact = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return [exact] }
        let matches = all.filter { $0.name.localizedCaseInsensitiveContains(name) || $0.model.displayName.localizedCaseInsensitiveContains(name) }
        guard matches.count == 1 else {
            throw AssistantError("Drucker „\(name)“ nicht eindeutig gefunden. Vorhanden: \(all.map(\.name).joined(separator: ", "))")
        }
        return matches
    }

    private func overview(_ host: AssistantHost) -> JSONValue {
        var o: [String: JSONValue] = [
            "printers": .array(host.assistantPrinters.map { p in
                var d: [String: JSONValue] = ["name": .string(p.name), "model": .string(p.model.displayName),
                                              "selected": .bool(p.isSelected), "online": .bool(p.isOnline)]
                if let s = p.status {
                    d["state"] = .string(s.state.displayName)
                    if s.state == .printing || s.state == .paused { d["progress_percent"] = .number((s.progress * 100).rounded()) }
                }
                if let e = p.error { d["error"] = .string(e) }
                return .object(d)
            }),
            "library_count": .number(Double(host.assistantLibrary.count)),
            "cloud_slicing": .bool(host.cloudSlicingAvailable),
        ]
        if let p = host.assistantProject {
            o["open_project"] = ["name": .string(p.name), "objects": .number(Double(p.objects.count)),
                                 "printer": .string(p.settings.printer.displayName)]
        } else {
            o["open_project"] = .null
        }
        return .object(o)
    }

    private func describe(_ p: AssistantPrinter) -> JSONValue {
        var d: [String: JSONValue] = ["name": .string(p.name), "model": .string(p.model.displayName), "host": .string(p.host),
                                      "selected": .bool(p.isSelected), "online": .bool(p.isOnline)]
        if let e = p.error { d["error"] = .string(e) }
        guard let s = p.status else { return .object(d) }
        func r(_ v: Double) -> JSONValue { .number((v * 10).rounded() / 10) }
        d["state"] = .string(s.state.displayName)
        if let m = s.stateMessage { d["message"] = .string(m) }
        if let f = s.fileName { d["file"] = .string(f) }
        if s.state == .printing || s.state == .paused || s.state == .complete {
            d["progress_percent"] = .number((s.progress * 1000).rounded() / 10)
            if let l = s.currentLayer { d["layer"] = .number(Double(l)) }
            if let t = s.totalLayers { d["total_layers"] = .number(Double(t)) }
            if let rem = s.remainingSeconds { d["remaining_minutes"] = .number((rem / 60).rounded()) }
            d["elapsed_minutes"] = .number((s.printDuration / 60).rounded())
        }
        d["bed"] = ["temperature": r(s.bed.temperature), "target": r(s.bed.target)]
        d["nozzles"] = .array(s.tools.enumerated().map { i, h in
            ["tool": .number(Double(i + 1)), "temperature": r(h.temperature), "target": r(h.target)]
        })
        if let a = s.activeTool { d["active_tool"] = .number(Double(a + 1)) }
        if let c = s.chamber { d["chamber"] = ["temperature": r(c.temperature), "target": r(c.target)] }
        if let f = s.fanPercent { d["part_fan_percent"] = r(f) }
        if let l = s.lightOn { d["light"] = .bool(l) }
        if !s.filaments.isEmpty {
            d["loaded_filament"] = .array(s.filaments.enumerated().map { i, f in
                var o: [String: JSONValue] = ["slot": .number(Double(i + 1)), "present": .bool(f.present), "name": .string(f.displayName)]
                if let c = f.color { o["color"] = .string(c) }
                return .object(o)
            })
        }
        if let box = s.filamentBox {
            var b: [String: JSONValue] = ["drying": .bool(box.drying)]
            if let h = box.humidity { b["humidity_percent"] = r(h) }
            if let t = box.temperature { b["temperature"] = r(t) }
            if let m = box.dryingRemainingMinutes, box.drying { b["drying_remaining_minutes"] = r(m) }
            d["ace_pro"] = .object(b)
        }
        if let fw = s.firmware { d["firmware"] = .string(fw) }
        return .object(d)
    }

    private func describe(_ p: AssistantProject) -> JSONValue {
        func r(_ v: Double) -> JSONValue { .number((v * 10).rounded() / 10) }
        var o: [String: JSONValue] = [
            "name": .string(p.name),
            "printer": .string(p.settings.printer.displayName),
            "bed_size_mm": .number(p.settings.bedSize),
            "objects": .array(p.objects.map { obj in
                ["object": .number(Double(obj.index)), "name": .string(obj.name), "slot": .number(Double(obj.slot)),
                 "size_mm": ["x": r(obj.size.x), "y": r(obj.size.y), "z": r(obj.size.z)]]
            }),
            "filaments": .array(p.settings.filaments.enumerated().map { i, f in
                ["slot": .number(Double(i + 1)), "profile": .string(f.name), "type": .string(f.type), "color": .string(f.color),
                 "nozzle_temp": .number(Double(f.nozzleTemp)), "bed_temp": .number(Double(f.bedTemp))]
            }),
            "settings": .object(SettingsPatch.json(p.settings)),
            "recommendations": .array(p.recommendations.map { rec in
                ["id": .string(rec.id), "title": .string(rec.title), "detail": .string(rec.detail),
                 "applicable": .bool(rec.action != nil)]
            }),
        ]
        if let w = p.warning { o["warning"] = .string(w) }
        switch p.slice {
        case .idle: o["slice"] = ["state": "nicht geslicet"]
        case .slicing(let phase, let fraction):
            o["slice"] = ["state": "läuft", "phase": .string(phase), "percent": .number((fraction * 100).rounded())]
        case .done(let estimate, let engine): o["slice"] = describe(estimate, engine: engine)
        case .failed(let m): o["slice"] = ["state": "fehlgeschlagen", "error": .string(m)]
        }
        return .object(o)
    }

    private func describe(_ e: PrintEstimate, engine: String) -> JSONValue {
        ["state": "fertig", "engine": .string(engine), "print_time": .string(e.formattedTime),
         "print_minutes": .number((e.seconds / 60).rounded()), "layers": .number(Double(e.layerCount)),
         "filament_grams_total": .number((e.totalGrams * 10).rounded() / 10),
         "filament_grams_per_slot": .object(Dictionary(uniqueKeysWithValues: e.filamentGrams.map {
             (String($0.key + 1), JSONValue.number(($0.value * 10).rounded() / 10))
         })),
         "tool_changes": .number(Double(e.toolChanges))]
    }

    private func filamentProfiles(query: String?, printer: PrinterModel) -> JSONValue {
        let entries = FilamentLibrary.entries(for: printer)
        let list: [FilamentLibrary.Entry]
        if let q = query?.trimmingCharacters(in: .whitespaces), !q.isEmpty {
            let words = q.lowercased().split(separator: " ")
            list = entries.filter { e in
                let hay = "\(e.filament.name) \(e.filament.vendor) \(e.filament.type)".lowercased()
                return words.allSatisfy { hay.contains($0) }
            }
        } else {
            list = entries.filter { $0.scope != "any" }
        }
        return .array(list.prefix(25).map { e in
            ["name": .string(e.filament.name), "vendor": .string(e.filament.vendor), "type": .string(e.filament.type),
             "nozzle_temp": .number(Double(e.filament.nozzleTemp)), "bed_temp": .number(Double(e.filament.bedTemp))]
        })
    }

    private func setFilament(_ input: [String: JSONValue], _ host: AssistantHost) throws -> String {
        let p = try project(host)
        var settings = p.settings
        guard let slot = input["slot"]?.int, (1...settings.filaments.count).contains(slot) else {
            throw AssistantError("„slot“ muss 1–\(settings.filaments.count) sein.")
        }
        let old = settings.filaments[slot - 1]
        var filament: Filament
        if let name = input["profile"]?.string {
            let entries = FilamentLibrary.entries(for: settings.printer).map(\.filament)
            guard let match = entries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                ?? entries.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else {
                throw AssistantError("Kein Profil „\(name)“. Suche mit list_filament_profiles.")
            }
            filament = match
        } else if let type = input["type"]?.string {
            guard let match = FilamentLibrary.bestMatch(type: type, printer: settings.printer) else {
                throw AssistantError("Kein Profil für Typ „\(type)“.")
            }
            filament = match
        } else {
            filament = old
        }
        if let color = input["color"]?.string {
            let hex = color.hasPrefix("#") ? color : "#" + color
            guard hex.count == 7, hex.dropFirst().allSatisfy(\.isHexDigit) else { throw AssistantError("Farbe bitte als #RRGGBB.") }
            filament.color = hex.uppercased()
        } else if filament.name != old.name {
            filament.color = old.color
        }
        settings.filaments[slot - 1] = filament
        try host.assistantSetSettings(settings)
        return "Slot \(slot): \(old.name) → \(filament.name) (\(filament.color), Düse \(filament.nozzleTemp) °C, Bett \(filament.bedTemp) °C)"
    }

    private func editObject(_ input: [String: JSONValue], _ host: AssistantHost) throws -> String {
        let p = try project(host)
        guard let index = input["object"]?.int, (1...max(p.objects.count, 1)).contains(index), !p.objects.isEmpty else {
            throw AssistantError("Ungültige Objektnummer. Das Projekt hat \(p.objects.count) Objekte.")
        }
        let value = input["value"]?.number
        let edit: ObjectEdit
        switch input["action"]?.string {
        case "rotate":
            guard let v = value else { throw AssistantError("Drehen braucht value in Grad.") }
            edit = .rotate(degrees: v)
        case "scale":
            guard let v = value, v > 0.05, v <= 10 else { throw AssistantError("Skalieren braucht value als Faktor 0,05–10.") }
            let size = p.objects[index - 1].size
            let biggest = max(size.x, size.y) * v
            if biggest > p.settings.bedSize {
                throw AssistantError("Mit Faktor \(v) wäre das Objekt \(Int(biggest)) mm groß – größer als das Bett (\(Int(p.settings.bedSize)) mm). Nutze auto_split oder einen kleineren Faktor.")
            }
            edit = .scale(factor: v)
        case "lay_flat": edit = .layFlat
        case "duplicate": edit = .duplicate
        case "remove": edit = .remove
        case "set_slot":
            guard let v = value.map({ Int($0) }), (1...p.settings.filaments.count).contains(v) else {
                throw AssistantError("set_slot braucht value 1–\(p.settings.filaments.count).")
            }
            edit = .setSlot(v)
        case "auto_split": edit = .autoSplit
        default: throw AssistantError("Unbekannte action.")
        }
        let name = p.objects[index - 1].name
        try host.assistantEdit(object: index, edit)
        let after = host.assistantProject
        let count = after?.objects.count ?? 0
        return "Erledigt (\(name)). Das Projekt hat jetzt \(count) Objekte." + (after?.warning.map { " Hinweis: \($0)" } ?? "")
    }

    private func printerCommand(_ input: [String: JSONValue], _ host: AssistantHost) async throws -> String {
        let printer = try printers(named: input["printer"]?.string, host, allIfNil: false)[0]
        let value = input["value"]?.number
        let command: PrinterCommand
        switch input["command"]?.string {
        case "pause": command = .pause
        case "resume": command = .resume
        case "cancel": command = .cancel
        case "set_bed_temperature":
            guard let v = value, (0...120).contains(v) else { throw AssistantError("Betttemperatur 0–120 °C angeben.") }
            command = .bedTemperature(Int(v))
        case "set_nozzle_temperature":
            guard let v = value, (0...300).contains(v) else { throw AssistantError("Düsentemperatur 0–300 °C angeben.") }
            let tool = (input["tool"]?.int ?? 1) - 1
            guard tool >= 0, tool < 4 else { throw AssistantError("tool muss 1–4 sein.") }
            command = .nozzleTemperature(tool: tool, Int(v))
        case "light_on": command = .light(true)
        case "light_off": command = .light(false)
        default: throw AssistantError("Unbekannter Befehl.")
        }
        guard printer.isOnline else { throw AssistantError("\(printer.name) ist nicht erreichbar.") }
        guard await host.assistantConfirm(title: "\(command.displayName)?", detail: "Drucker: \(printer.name)") else {
            return "Der Nutzer hat abgelehnt. Der Befehl wurde nicht gesendet."
        }
        try await host.assistantRun(command, on: printer.name)
        return "Gesendet an \(printer.name): \(command.displayName)."
    }
}
