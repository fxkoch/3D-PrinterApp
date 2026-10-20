import Foundation

/// Suggests a value for a slicer setting: the printer vendor's own profile, adjusted for the loaded material.
public enum SlicerOptionAdvisor {
    public struct Recommendation: Sendable, Equatable {
        public var value: String
        public var reason: String
    }

    /// Material-specific advice on top of the vendor profile. Only keys that exist in the vendor slicer are used.
    private static let materialRules: [(types: Set<String>, key: String, value: String, reason: String)] = [
        (["TPU", "TPE"], "reduce_infill_retraction", "1", "Weiche Filamente vertragen wenige Rückzüge – so wird der Filamentschub nicht gestaucht."),
        (["TPU", "TPE"], "reduce_crossing_wall", "0", "Bei TPU sind kurze Wege wichtiger als Umwege; Fäden fallen kaum auf."),
        (["PETG", "PETG-CF"], "reduce_crossing_wall", "1", "PETG zieht gern Fäden – Umwege um Wände vermeiden Klumpen auf der Oberfläche."),
        (["PETG", "PETG-CF"], "wipe_on_loops", "1", "PETG sondert an der Naht gern ein Tröpfchen ab; das Abwischen an der Schleife verdeckt es."),
        (["ABS", "ASA", "PC", "PA", "PA-CF", "PAHT-CF"], "draft_shield", "enabled", "Zugluftschutz hält die Wärme um das Teil und verringert Verzug bei diesem Material."),
    ]

    public static func recommendation(for option: SlicerOption, settings: PrintSettings) -> Recommendation? {
        let type = settings.filament(for: 0).type.uppercased()
        if let rule = materialRules.first(where: { $0.key == option.key && $0.types.contains(type) }) {
            return Recommendation(value: rule.value, reason: rule.reason)
        }
        guard let vendor = option.vendor[settings.printer] else { return nil }
        return Recommendation(value: vendor, reason: "Werksprofil von \(vendorName(settings.printer)) (0,20 mm Standard).")
    }

    public static func vendorName(_ model: PrinterModel) -> String {
        model == .snapmakerU1 ? "Snapmaker" : "Anycubic"
    }

    /// The slicer whose settings list the app mirrors for this printer.
    public static func slicerName(_ model: PrinterModel) -> String {
        model == .snapmakerU1 ? "Snapmaker Orca" : "Anycubic Slicer Next"
    }
}
