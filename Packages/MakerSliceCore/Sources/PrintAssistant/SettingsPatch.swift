import ClaudeKit
import Foundation
import SliceKit

/// Applies changes like `{"layerHeight": 0.12, "support": "buildPlateOnly"}` to print settings,
/// using the settings' own Codable keys so every slicer parameter is reachable.
public enum SettingsPatch {
    /// Changed through dedicated tools (filament profiles, printer selection).
    static let blocked: Set<String> = ["printer", "filaments"]

    static let ranges: [String: ClosedRange<Double>] = [
        "layerHeight": 0.04...0.4, "firstLayerHeight": 0.08...0.4, "wallLoops": 1...20, "topLayers": 0...40,
        "bottomLayers": 0...40, "infillDensity": 0...1, "brimWidth": 0...30, "skirtLoops": 0...10,
        "supportAngle": 0...90, "elephantFootCompensation": 0...1, "zHop": 0...2, "ironingFlow": 0...0.5,
        "fuzzySkinThickness": 0...2, "primeTowerWidth": 10...80,
    ]

    static let allowedValues: [String: [String]] = [
        "infillPattern": InfillPattern.allCases.map(\.rawValue),
        "support": SupportMode.allCases.map(\.rawValue),
        "plateType": PlateType.allCases.map(\.rawValue),
        "seamPosition": SeamPosition.allCases.map(\.rawValue),
        "wallOrder": WallOrder.allCases.map(\.rawValue),
        "topSurfacePattern": SurfacePattern.allCases.map(\.rawValue),
        "bottomSurfacePattern": SurfacePattern.allCases.map(\.rawValue),
    ]

    /// All settings as JSON (without filaments), for the assistant to read.
    public static func json(_ settings: PrintSettings) -> [String: JSONValue] {
        var o = encode(settings)
        o.removeValue(forKey: "filaments")
        return o
    }

    public static func apply(_ changes: [String: JSONValue], to settings: PrintSettings) throws -> (PrintSettings, [String]) {
        guard !changes.isEmpty else { throw AssistantError("Keine Änderungen angegeben.") }
        var object = encode(settings)
        let known = Set(object.keys).subtracting(blocked)
        for (key, raw) in changes {
            if blocked.contains(key) {
                throw AssistantError(key == "printer" ? "Den Drucker wechselst du mit select_printer." : "Material änderst du mit set_filament.")
            }
            guard let current = object[key] else {
                throw AssistantError("Unbekannter Parameter „\(key)“. Bekannt: \(known.sorted().joined(separator: ", "))")
            }
            var value = raw
            switch current {
            case .number:
                guard var n = raw.number else { throw AssistantError("„\(key)“ braucht eine Zahl.") }
                if key == "infillDensity", n > 1 { n /= 100 } // "20" means 20 %
                if let r = ranges[key], !r.contains(n) {
                    throw AssistantError("„\(key)“ = \(n) liegt außerhalb von \(r.lowerBound)…\(r.upperBound).")
                }
                value = .number(n)
            case .bool:
                guard let b = raw.bool else { throw AssistantError("„\(key)“ braucht true oder false.") }
                value = .bool(b)
            case .string:
                guard let s = raw.string else { throw AssistantError("„\(key)“ braucht einen Text.") }
                if let allowed = allowedValues[key], !allowed.contains(s) {
                    throw AssistantError("„\(key)“ = „\(s)“ ist ungültig. Erlaubt: \(allowed.joined(separator: ", "))")
                }
                value = .string(s)
            default:
                throw AssistantError("„\(key)“ lässt sich hier nicht ändern.")
            }
            object[key] = value
        }
        let data = try JSONEncoder().encode(JSONValue.object(object))
        let updated = try JSONDecoder().decode(PrintSettings.self, from: data)
        if updated.layerHeight > updated.nozzleDiameter * 0.8 + 1e-9 {
            throw AssistantError("Schichthöhe \(updated.layerHeight) mm ist zu groß für die \(updated.nozzleDiameter)-mm-Düse (max. \(updated.nozzleDiameter * 0.8) mm).")
        }
        // Report what actually changed (and catch values the decoder ignored).
        let after = encode(updated)
        var summary: [String] = []
        for key in changes.keys.sorted() {
            let old = encode(settings)[key], new = after[key]
            if new != object[key] { throw AssistantError("„\(key)“ wurde nicht übernommen.") }
            if old != new { summary.append("\(key): \(describe(old)) → \(describe(new))") }
        }
        return (updated, summary)
    }

    private static func encode(_ settings: PrintSettings) -> [String: JSONValue] {
        guard let data = try? JSONEncoder().encode(settings),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [:] }
        return value.object ?? [:]
    }

    private static func describe(_ v: JSONValue?) -> String {
        switch v {
        case .number(let n)?: return n.rounded() == n ? String(Int(n)) : String(format: "%g", n)
        case .string(let s)?: return s
        case .bool(let b)?: return b ? "an" : "aus"
        default: return "–"
        }
    }
}
