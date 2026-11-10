import Foundation

/// One process setting of the printer vendor's slicer (Anycubic Slicer Next for the Kobra S1,
/// Snapmaker Orca for the U1). The list is generated from the slicers themselves – see tools/settings.
public struct SlicerOption: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable { case bool, int, float, percent, floatOrPercent, choice, text }

    public struct Choice: Sendable, Equatable, Hashable {
        public var value: String
        public var label: String
    }

    /// OrcaSlicer config key, e.g. `seam_gap`.
    public var key: String
    /// Tab in the vendor slicer (Qualität, Festigkeit, …) and the group within it.
    public var page: String
    public var group: String
    public var kind: Kind
    public var title: String
    /// Explanation from the slicer (German).
    public var summary: String
    public var unit: String
    public var min: Double?
    public var max: Double?
    public var choices: [Choice]
    public var availableFor: Set<PrinterModel>
    /// The value the printer vendor's own 0.20 mm standard profile uses.
    public var vendor: [PrinterModel: String]

    public var id: String { key }

    init(key: String, page: String, group: String, kind: Kind, title: String, summary: String, unit: String,
         min: Double?, max: Double?, choices: [(String, String)], availableFor: Set<PrinterModel>, vendor: [PrinterModel: String]) {
        self.key = key
        self.page = page
        self.group = group
        self.kind = kind
        self.title = title
        self.summary = summary
        self.unit = unit
        self.min = min
        self.max = max
        self.choices = choices.map { Choice(value: $0.0, label: $0.1) }
        self.availableFor = availableFor
        self.vendor = vendor
    }
}

public enum SlicerOptionCatalog {
    /// Tab order as in the vendor slicers.
    public static let pageOrder = ["Qualität", "Festigkeit", "Geschwindigkeit", "Stützen", "Mehrfarben", "Sonstiges"]

    public static func options(for model: PrinterModel) -> [SlicerOption] {
        all.filter { $0.availableFor.contains(model) }
    }

    public static func option(_ key: String) -> SlicerOption? { byKey[key] }

    /// The generated catalog (Anycubic Slicer Next / Snapmaker Orca) for all printers: the P1S uses the same Orca options, with
    /// Bambu's own "0.20mm Standard" values as its vendor defaults (`Resources/p1s_process_defaults.json`).
    static let all: [SlicerOption] = generated.map { option in
        guard option.availableFor.contains(.kobraS1) else { return option }
        var o = option
        o.availableFor.insert(.bambuP1S)
        if let value = bambuDefaults[o.key] { o.vendor[.bambuP1S] = value }
        return o
    }

    private static let bambuDefaults: [String: String] = {
        guard let url = Bundle.module.url(forResource: "p1s_process_defaults", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }()

    private static let byKey: [String: SlicerOption] = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
}
