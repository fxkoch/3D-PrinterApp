import Foundation

/// Drying temperature and time for the filaments in a dryer box (ACE Pro): the gentlest setting any of them needs,
/// so that no spool is overheated, and the longest time any of them needs.
public struct DryingPlan: Equatable, Sendable {
    public var temperature: Int
    public var minutes: Int
    /// Which material limits the temperature ("PLA verträgt nicht mehr").
    public var limitedBy: String?
    public var types: [String]

    public var hours: Double { Double(minutes) / 60 }

    public var summary: String {
        let h = minutes % 60 == 0 ? "\(minutes / 60) h" : String(format: "%.1f h", hours)
        return "\(temperature) °C, \(h)"
    }

    /// Short explanation for the user.
    public var explanation: String {
        var text = "Passt für \(types.joined(separator: ", "))."
        if let limitedBy { text += " \(limitedBy) bestimmt die Temperatur: wärmer würden die Spulen weich." }
        return text
    }
}

public enum DryingAdvice {
    /// Per material: highest drying temperature the spool and filament take, and the time that dries it at that
    /// temperature (or at the dryer's maximum if that is lower – slower, so longer).
    struct Material { var maxTemperature: Int; var hours: Double }

    static let table: [(prefix: String, material: Material, name: String)] = [
        ("PLA", Material(maxTemperature: 50, hours: 6), "PLA"),
        ("PVA", Material(maxTemperature: 45, hours: 6), "PVA"),
        ("TPU", Material(maxTemperature: 45, hours: 8), "TPU"),
        ("TPE", Material(maxTemperature: 45, hours: 8), "TPE"),
        ("PETG", Material(maxTemperature: 65, hours: 6), "PETG"),
        ("PET", Material(maxTemperature: 65, hours: 6), "PET"),
        ("ABS", Material(maxTemperature: 80, hours: 4), "ABS"),
        ("ASA", Material(maxTemperature: 80, hours: 4), "ASA"),
        ("PA", Material(maxTemperature: 80, hours: 8), "Nylon"),
        ("PC", Material(maxTemperature: 80, hours: 8), "PC"),
    ]

    /// `types` are the filament types in the box ("PLA", "PETG-CF" …, empty ones ignored). `dryerMaximum` is what the box can do.
    public static func plan(types: [String], dryerMaximum: Int = 55) -> DryingPlan? {
        var seen: [String] = []
        var limit = dryerMaximum
        var limitedBy: String?
        for raw in types {
            let t = raw.uppercased().trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t != "NONE" else { continue }
            let entry = table.first { t.hasPrefix($0.prefix) } ?? ("", Material(maxTemperature: 50, hours: 6), t)
            let name = entry.name
            if !seen.contains(name) { seen.append(name) }
            if entry.material.maxTemperature < limit { limit = entry.material.maxTemperature; limitedBy = name }
        }
        guard !seen.isEmpty else { return nil }
        // Below a material's own maximum it dries more slowly: 25 % longer per 10 °C missing (at most double).
        var minutes = 0
        for raw in types {
            let t = raw.uppercased().trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t != "NONE" else { continue }
            let m = (table.first { t.hasPrefix($0.prefix) }?.material) ?? Material(maxTemperature: 50, hours: 6)
            let missing = max(0, m.maxTemperature - limit)
            let factor = min(2.0, 1 + 0.25 * Double(missing) / 10)
            minutes = max(minutes, Int((m.hours * factor * 60 / 30).rounded()) * 30)
        }
        // Not marked as limiting when the dryer itself is the limit and every material would take more.
        if limit == dryerMaximum { limitedBy = nil }
        return DryingPlan(temperature: limit, minutes: min(minutes, 12 * 60), limitedBy: limitedBy, types: seen)
    }
}
