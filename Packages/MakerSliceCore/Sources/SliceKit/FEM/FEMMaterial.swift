import Foundation

/// Mechanical properties of a printed material, for the strength estimate.
///
/// The numbers are typical values for FDM prints from manufacturer data sheets and test reports, measured dry with
/// standard settings (sources: Bambu Lab heat deflection table (0.45 MPa), ABS data sheet XY/Z, Xometry FDM data for
/// PETG/ASA/nylon-CF, university study on XY/Z anisotropy of PLA/ABS/PETG). Individual filaments and printers vary
/// by ±20 % or more – the estimate is meant to compare variants and to find weak spots, not to certify a part.
public struct FEMMaterial: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// g/cm³
    public var density: Double
    /// Young's modulus in the layer plane (along the printed lines), MPa.
    public var modulusXY: Double
    /// Young's modulus across the layers (Z), MPa.
    public var modulusZ: Double
    public var poisson: Double
    /// Tensile strength along the lines (XY), MPa.
    public var strengthXY: Double
    /// Tensile strength across the layers as a fraction of `strengthXY` (layer adhesion).
    public var zStrengthFactor: Double
    /// Temperature at which the material starts to soften under load (heat deflection, °C).
    public var heatDeflection: Double
    /// Share of the short-term strength that may be applied permanently (creep).
    public var longTermFactor: Double
    /// Flexible materials stretch far beyond the linear range – the estimate is only rough.
    public var isFlexible = false
    /// Hint shown with the result (moisture, creep, …).
    public var note: String?

    public init(id: String, name: String, density: Double, modulusXY: Double, modulusZ: Double, poisson: Double, strengthXY: Double,
                zStrengthFactor: Double, heatDeflection: Double, longTermFactor: Double, isFlexible: Bool = false, note: String? = nil) {
        self.id = id; self.name = name; self.density = density; self.modulusXY = modulusXY; self.modulusZ = modulusZ
        self.poisson = poisson; self.strengthXY = strengthXY; self.zStrengthFactor = zStrengthFactor
        self.heatDeflection = heatDeflection; self.longTermFactor = longTermFactor; self.isFlexible = isFlexible; self.note = note
    }

    public var strengthZ: Double { strengthXY * zStrengthFactor }

    /// The common printing materials.
    public static let catalog: [FEMMaterial] = [
        FEMMaterial(id: "PLA", name: "PLA", density: 1.24, modulusXY: 3300, modulusZ: 3000, poisson: 0.36, strengthXY: 50, zStrengthFactor: 0.65,
                    heatDeflection: 57, longTermFactor: 0.30, note: "PLA kriecht unter Dauerlast und wird ab ca. 55 °C weich (Auto im Sommer!)."),
        FEMMaterial(id: "PETG", name: "PETG", density: 1.27, modulusXY: 1900, modulusZ: 1700, poisson: 0.38, strengthXY: 45, zStrengthFactor: 0.60,
                    heatDeflection: 69, longTermFactor: 0.40, note: "PETG ist zäh und dehnt sich vor dem Bruch; Schichthaftung ist die Schwachstelle."),
        FEMMaterial(id: "ABS", name: "ABS", density: 1.04, modulusXY: 1960, modulusZ: 1700, poisson: 0.35, strengthXY: 34, zStrengthFactor: 0.56,
                    heatDeflection: 87, longTermFactor: 0.40),
        FEMMaterial(id: "ASA", name: "ASA", density: 1.07, modulusXY: 1900, modulusZ: 1700, poisson: 0.35, strengthXY: 37, zStrengthFactor: 0.80,
                    heatDeflection: 100, longTermFactor: 0.40, note: "ASA ist wetter- und UV-fest – gut für Außenteile."),
        FEMMaterial(id: "PC", name: "PC (Polycarbonat)", density: 1.20, modulusXY: 2100, modulusZ: 1900, poisson: 0.37, strengthXY: 55, zStrengthFactor: 0.60,
                    heatDeflection: 117, longTermFactor: 0.50),
        FEMMaterial(id: "PA", name: "Nylon (PA6/PA12)", density: 1.10, modulusXY: 1500, modulusZ: 1300, poisson: 0.39, strengthXY: 45, zStrengthFactor: 0.60,
                    heatDeflection: 70, longTermFactor: 0.40, note: "Nylon nimmt Wasser auf: feucht verliert es deutlich Steifigkeit und Festigkeit (Werte gelten trocken)."),
        FEMMaterial(id: "TPU", name: "TPU (95A)", density: 1.21, modulusXY: 30, modulusZ: 26, poisson: 0.45, strengthXY: 30, zStrengthFactor: 0.80,
                    heatDeflection: 60, longTermFactor: 0.50, isFlexible: true,
                    note: "TPU ist gummiartig und verformt sich weit über den linearen Bereich – das Ergebnis ist nur eine grobe Näherung."),
        FEMMaterial(id: "PLA-CF", name: "PLA-CF (Carbon)", density: 1.30, modulusXY: 5000, modulusZ: 3000, poisson: 0.33, strengthXY: 55, zStrengthFactor: 0.35,
                    heatDeflection: 58, longTermFactor: 0.30, note: "Carbon macht steif, aber spröde; quer zu den Schichten ist es besonders schwach."),
        FEMMaterial(id: "PETG-CF", name: "PETG-CF (Carbon)", density: 1.30, modulusXY: 4000, modulusZ: 2200, poisson: 0.35, strengthXY: 50, zStrengthFactor: 0.45,
                    heatDeflection: 75, longTermFactor: 0.40),
        FEMMaterial(id: "PA-CF", name: "Nylon-CF (PA6-CF)", density: 1.20, modulusXY: 5460, modulusZ: 2600, poisson: 0.35, strengthXY: 102, zStrengthFactor: 0.47,
                    heatDeflection: 186, longTermFactor: 0.40, note: "Werte trocken (Datenblatt: 102 MPa XY, ca. 48 MPa Z). Feucht deutlich schwächer – Filament trocken lagern."),
        FEMMaterial(id: "PAHT-CF", name: "PAHT-CF (hitzefest)", density: 1.20, modulusXY: 5000, modulusZ: 2500, poisson: 0.35, strengthXY: 85, zStrengthFactor: 0.45,
                    heatDeflection: 194, longTermFactor: 0.40, note: "Werte aus Näherung – PAHT-CF-Datenblatt des Herstellers prüfen."),
        FEMMaterial(id: "PP", name: "PP (Polypropylen)", density: 0.90, modulusXY: 900, modulusZ: 800, poisson: 0.42, strengthXY: 25, zStrengthFactor: 0.70,
                    heatDeflection: 90, longTermFactor: 0.30),
    ]

    public static func material(id: String) -> FEMMaterial? { catalog.first { $0.id == id } }

    /// Best material for a filament profile (by its type, e.g. "PETG", "PLA-CF", "ABS").
    public static func matching(filamentType: String) -> FEMMaterial {
        let t = filamentType.uppercased().replacingOccurrences(of: " ", with: "-")
        if let exact = catalog.first(where: { $0.id == t }) { return exact }
        if t.contains("PAHT") { return material(id: "PAHT-CF")! }
        if t.hasPrefix("PA") && (t.contains("CF") || t.contains("GF")) { return material(id: "PA-CF")! }
        if t.hasPrefix("PA") { return material(id: "PA")! }
        if t.contains("PETG") && t.contains("CF") { return material(id: "PETG-CF")! }
        if t.contains("PLA") && t.contains("CF") { return material(id: "PLA-CF")! }
        for id in ["TPU", "TPE", "PETG", "PLA", "ABS", "ASA", "PC", "PP"] where t.contains(id) { return material(id: id == "TPE" ? "TPU" : id)! }
        return material(id: "PLA")!
    }
}
