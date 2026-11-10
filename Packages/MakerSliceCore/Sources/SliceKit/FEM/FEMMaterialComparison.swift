import Foundation

extension FEMMaterial {
    /// Carbon- or glass-filled filaments wear out a brass nozzle.
    public var needsHardenedNozzle: Bool { id.hasSuffix("-CF") }
    public var needsEnclosure: Bool { ["ABS", "ASA", "PC", "PA", "PA-CF", "PAHT-CF", "PP"].contains(id) }

    /// What changes in printing when switching to this material.
    public var printingNote: String {
        var parts: [String] = []
        switch id {
        case "PLA": parts.append("einfach zu drucken")
        case "PETG", "PETG-CF": parts.append("einfach zu drucken, nicht auf glatter PEI-Platte")
        case "ABS", "ASA": parts.append("Gehäuse geschlossen halten, verzieht leicht (Brim), Dämpfe")
        case "PC": parts.append("hohe Düsentemperatur (ca. 260–280 °C), Gehäuse, trocken lagern")
        case "PA", "PA-CF", "PAHT-CF": parts.append("vor dem Druck trocknen, Gehäuse, Klebestift auf der Platte")
        case "PP": parts.append("haftet schlecht auf dem Bett (PP-Platte oder Klebeband)")
        case "PLA-CF": parts.append("leicht zu drucken, aber spröde")
        default: break
        }
        if needsHardenedNozzle { parts.append("gehärtete Düse nötig") }
        return parts.joined(separator: "; ")
    }
}

/// One row of the material comparison: the same part, the same load, another material.
public struct MaterialComparison: Sendable, Identifiable {
    public var id: String { material.id }
    public var material: FEMMaterial
    public var result: FEMResult
    /// Safety factor relative to the current material (1 = same).
    public var safetyRatio: Double
    public var stiffnessRatio: Double
    public var massRatio: Double
    public var isCurrent: Bool
}

public enum FEMMaterialComparison {
    /// Materials worth comparing by default (flexible materials are excluded: the linear calculation does not fit them).
    public static func defaultCandidates(current: FEMMaterial) -> [FEMMaterial] {
        FEMMaterial.catalog.filter { !$0.isFlexible && $0.id != "PP" }
    }

    /// Runs the load case for every candidate. The current material is always included and used as reference.
    @_optimize(speed)
    public static func compare(mesh: TriangleMesh, current: FEMMaterial, candidates: [FEMMaterial], setup: FEMPrintSetup, loadCase: FEMLoadCase,
                               baseline: FEMResult? = nil, options: FEMOptions = .fast,
                               progress: (String, Double) -> Void = { _, _ in }, isCancelled: () -> Bool = { false }) throws -> [MaterialComparison] {
        let base = try baseline ?? FEMAnalysis.run(mesh: mesh, material: current, setup: setup, loadCase: loadCase, options: options, isCancelled: isCancelled)
        let others = candidates.filter { $0.id != current.id }
        var rows = [MaterialComparison(material: current, result: base, safetyRatio: 1, stiffnessRatio: 1, massRatio: 1, isCurrent: true)]
        for (n, m) in others.enumerated() {
            progress("Material \(m.name) rechnen", Double(n) / Double(max(others.count, 1)))
            if isCancelled() { throw FEMError.cancelled }
            guard let r = try? FEMAnalysis.run(mesh: mesh, material: m, setup: setup, loadCase: loadCase, options: options, isCancelled: isCancelled) else { continue }
            rows.append(MaterialComparison(material: m, result: r, safetyRatio: r.safetyFactor / max(base.safetyFactor, 1e-9),
                                           stiffnessRatio: r.stiffness / max(base.stiffness, 1e-9), massRatio: r.massGrams / max(base.massGrams, 1e-9), isCurrent: false))
        }
        return rows.sorted { $0.result.safetyFactor > $1.result.safetyFactor }
    }
}
