import Foundation

/// Standard check after a filament problem ("abnormaler Filamentrückgang", runout, clog): what the printer reports right
/// now as traffic lights, plus the steps to do by hand. Read-only – the checks only look at the printer's status.
public struct FilamentCheck: Equatable, Sendable {
    public enum Level: Int, Sendable, Comparable {
        case ok, unknown, warning, problem
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var level: Level
        public var detail: String
    }

    public var items: [Item]

    /// The worst level of all checks.
    public var overall: Level { items.map(\.level).max() ?? .unknown }

    /// Hand steps in the order that works best; the app lets the user tick them off.
    public static let steps: [String] = [
        "Druck anhalten oder abbrechen, bevor du am Filament arbeitest.",
        "Düse auf Betriebstemperatur heizen (z. B. 220 °C für PLA, 240 °C für PETG), damit sich das Filament lösen lässt.",
        "Filament aus dem Druckkopf ziehen. Das Ende ansehen: abgerieben, geknickt oder dicker als sonst deutet auf Rutschen oder Verstopfen hin – dann ein Stück abschneiden.",
        "Spule prüfen: Sie muss sich frei drehen, das Filament darf nicht verheddert oder unter einer Lage eingeklemmt sein. Beim ACE/AMS: Spulendurchmesser (ca. 195 mm) und Kerben am Spulenrand beachten.",
        "Schlauch und Zuführung prüfen: kein Knick, Filament läuft leicht von Hand durch, Stecker sitzen fest.",
        "Filament von Hand vorschieben, bis es sauber und gleichmäßig aus der Düse kommt (ohne Klicken oder Zucken).",
        "Wenn es klickt oder nichts kommt: Düse reinigen (Cold Pull) oder wechseln.",
        "Hier „Erneut prüfen“ tippen und danach den Druck neu starten oder fortsetzen.",
    ]

    /// Checks from the printer's status. `expectedType` is the material of the job (e.g. "PETG"), `messages` recent printer messages.
    public static func evaluate(_ s: PrinterStatus, expectedType: String? = nil, messages: [String] = []) -> FilamentCheck {
        var items: [Item] = []

        // Printer message.
        let all = ([s.stateMessage].compactMap { $0 } + messages).joined(separator: " ").lowercased()
        let words = ["filament", "retract", "rückgang", "abnormal", "runout", "clog", "extru", "jam", "feed"]
        if let hit = words.first(where: { all.contains($0) }) {
            _ = hit
            items.append(Item(id: "message", title: "Meldung des Druckers", level: .problem,
                              detail: (s.stateMessage ?? messages.last { m in words.contains { m.lowercased().contains($0) } } ?? "Filamentproblem gemeldet.")))
        } else {
            items.append(Item(id: "message", title: "Meldung des Druckers", level: .ok, detail: "Keine Filament-Meldung aktuell."))
        }

        // State of the job.
        switch s.state {
        case .paused, .error:
            items.append(Item(id: "job", title: "Auftrag", level: .warning, detail: "Der Druck steht (\(s.state.displayName)). Erst das Filament beheben, dann fortsetzen oder neu starten."))
        case .printing:
            items.append(Item(id: "job", title: "Auftrag", level: .warning, detail: "Es wird gedruckt. Zum Prüfen besser anhalten."))
        default:
            items.append(Item(id: "job", title: "Auftrag", level: .ok, detail: "Kein Druck läuft."))
        }

        // Loaded filament.
        if s.filaments.isEmpty {
            items.append(Item(id: "slots", title: "Eingelegtes Filament", level: .unknown, detail: "Der Drucker meldet keine Slots."))
        } else if !s.filaments.contains(where: \.present) {
            items.append(Item(id: "slots", title: "Eingelegtes Filament", level: .problem, detail: "Alle Slots melden leer."))
        } else {
            let empty = s.filaments.enumerated().filter { !$0.element.present }.map { $0.offset + 1 }
            items.append(Item(id: "slots", title: "Eingelegtes Filament", level: .ok,
                              detail: empty.isEmpty ? "Alle Slots belegt." : "Leer: Slot \(empty.map(String.init).joined(separator: ", "))."))
        }

        // Active slot.
        if let active = s.filamentBox?.activeSlot ?? s.activeTool, s.filaments.indices.contains(active) {
            let f = s.filaments[active]
            if !f.present {
                items.append(Item(id: "active", title: "Aktiver Slot \(active + 1)", level: .problem, detail: "Der Drucker will aus Slot \(active + 1) arbeiten, der meldet aber leer."))
            } else if let expectedType, let type = f.type, !type.uppercased().hasPrefix(expectedType.uppercased().prefix(3)) {
                items.append(Item(id: "active", title: "Aktiver Slot \(active + 1)", level: .warning, detail: "Im Slot liegt \(type), der Auftrag erwartet \(expectedType)."))
            } else {
                items.append(Item(id: "active", title: "Aktiver Slot \(active + 1)", level: .ok, detail: f.displayName))
            }
        } else if s.state == .printing || s.state == .paused {
            items.append(Item(id: "active", title: "Aktiver Slot", level: .warning, detail: "Der Drucker meldet keinen geladenen Slot – das Filament ist vermutlich nicht bis zur Düse vorgeschoben."))
        }

        // Moisture.
        if let h = s.filamentBox?.humidity {
            if h > 50 { items.append(Item(id: "humidity", title: "Feuchte im Filamentfach", level: .warning, detail: "\(Int(h)) % – feuchtes Filament wird spröde und kann reißen. Trocknen empfohlen.")) }
            else if h > 40 { items.append(Item(id: "humidity", title: "Feuchte im Filamentfach", level: .warning, detail: "\(Int(h)) % – grenzwertig, besonders für PETG und Nylon.")) }
            else { items.append(Item(id: "humidity", title: "Feuchte im Filamentfach", level: .ok, detail: "\(Int(h)) %")) }
        }

        // Nozzle temperature (filament only moves when it is hot).
        if let nozzle = s.tools.first {
            if nozzle.target > 0, nozzle.temperature < nozzle.target - 15 {
                items.append(Item(id: "nozzle", title: "Düse", level: .warning, detail: "Heizt noch: \(Int(nozzle.temperature)) von \(Int(nozzle.target)) °C."))
            } else if nozzle.target <= 0, nozzle.temperature < 150 {
                items.append(Item(id: "nozzle", title: "Düse", level: .unknown, detail: "Kalt (\(Int(nozzle.temperature)) °C). Zum Vorschieben von Hand erst aufheizen."))
            } else {
                items.append(Item(id: "nozzle", title: "Düse", level: .ok, detail: "\(Int(nozzle.temperature)) °C – heiß genug zum Vorschieben."))
            }
        }
        return FilamentCheck(items: items)
    }

    /// True when a printer message points to a filament problem (used to offer this check automatically).
    public static func isFilamentMessage(_ message: String?) -> Bool {
        let m = (message ?? "").lowercased()
        return ["filament", "retract", "rückgang", "rueckgang", "abnormal", "runout", "clog", "jam", "feed", "extru"].contains { m.contains($0) }
    }
}
