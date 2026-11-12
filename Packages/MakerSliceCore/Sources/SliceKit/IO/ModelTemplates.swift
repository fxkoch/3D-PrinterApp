import Foundation

/// A ready-made model that ships with the app (library menu "Vorlagen").
public struct ModelTemplate: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// One sentence on what the part is for and how to print it.
    public let note: String
    /// Recommended walls and infill; `needsSupport` turns on supports everywhere (overhangs above the model itself).
    public let wallLoops: Int
    public let infillDensity: Double
    public let needsSupport: Bool

    public var fileName: String { id + ".stl" }

    /// The STL file from the package resources.
    public func data() -> Data? {
        guard let url = Bundle.module.url(forResource: id, withExtension: "stl") else { return nil }
        return try? Data(contentsOf: url)
    }
}

public enum ModelTemplates {
    /// Onion dispenser set: a column with a tongue (onions are refilled on top and taken out at the bottom), a lid with a bowl,
    /// feet (air from below) and a connector that joins two modules at the back.
    public static let all: [ModelTemplate] = [
        ModelTemplate(id: "zwiebelspender_set", name: "Zwiebelspender – Set auf einer Platte",
                      note: "Modul, Deckel und Steckfüße zusammen, 234 × 182 × 240 mm. Stützen „Überall“ für den Bogen der Öffnung.",
                      wallLoops: 2, infillDensity: 0.15, needsSupport: true),
        ModelTemplate(id: "zwiebelspender_modul", name: "Zwiebelspender – Modul",
                      note: "Schacht mit Zunge, 100 × 182 × 240 mm. Stützen „Überall“ für den Bogen der Öffnung.",
                      wallLoops: 2, infillDensity: 0.15, needsSupport: true),
        ModelTemplate(id: "zwiebelspender_deckel", name: "Zwiebelspender – Deckel mit Schale",
                      note: "Geschlossene Schale, z. B. für Knoblauch. Druckt ohne Stützen.",
                      wallLoops: 2, infillDensity: 0.15, needsSupport: false),
        ModelTemplate(id: "zwiebelspender_fuesse", name: "Zwiebelspender – Füße zum Stecken (2 Kufen)",
                      note: "Von unten in die äußeren Schlitze des Rosts stecken: so kommt Luft von unten durch den Rost.",
                      wallLoops: 2, infillDensity: 0.15, needsSupport: false),
        ModelTemplate(id: "zwiebelspender_verbinder", name: "Zwiebelspender – Verbinder",
                      note: "Leiste für zwei Module: von oben über die beiden Schienen auf der Rückseite schieben.",
                      wallLoops: 3, infillDensity: 0.25, needsSupport: false),
    ]
}
