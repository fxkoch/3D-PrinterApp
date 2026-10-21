import Foundation

/// A tried variant of the part with its calculated effect.
public struct FEMSuggestion: Sendable, Identifiable {
    public enum Goal: String, Sendable { case stronger, lighter }

    public var id = UUID()
    public var goal: Goal
    public var title: String
    public var detail: String
    /// Print settings of this variant (walls, infill).
    public var wallLoops: Int
    public var infillDensity: Double
    /// Turn the part by this transform before printing (nil = keep orientation).
    public var rotation: Transform3D?
    public var rotationName: String?
    /// Other material (nil = keep).
    public var material: FEMMaterial?
    public var result: FEMResult
    /// Safety factor and weight relative to the original (1 = same).
    public var safetyRatio: Double
    public var massRatio: Double
    /// Print time grows roughly with the weight; only a hint.
    public var changesSettings: Bool { true }
}

public enum FEMAdvisor {
    /// Tries variants of walls, infill, orientation and material and returns those that help:
    /// `.stronger` (higher safety) and `.lighter` (less material at about the same safety).
    /// The first element of the returned pair is the baseline.
    @_optimize(speed)
    public static func suggest(mesh: TriangleMesh, material: FEMMaterial, settings: PrintSettings, loadCase: FEMLoadCase,
                               baseline: FEMResult? = nil, options: FEMOptions = .fast,
                               progress: (String, Double) -> Void = { _, _ in },
                               isCancelled: () -> Bool = { false }) throws -> [FEMSuggestion] {
        let line = settings.lineWidth
        func setup(walls: Int, infill: Double) -> FEMPrintSetup {
            FEMPrintSetup(wallThickness: Double(walls) * line, topThickness: Double(settings.topLayers) * settings.layerHeight,
                          bottomThickness: Double(settings.bottomLayers) * settings.layerHeight, infillDensity: infill)
        }
        let base = try baseline ?? FEMAnalysis.run(mesh: mesh, material: material, setup: setup(walls: settings.wallLoops, infill: settings.infillDensity),
                                                   loadCase: loadCase, options: options, isCancelled: isCancelled)
        var steps = 0.0
        var total = 1.0
        func tick(_ text: String) { steps += 1; progress(text, min(steps / total, 1)) }

        struct Variant { var walls: Int; var infill: Double; var rotation: (Transform3D, String)?; var material: FEMMaterial? }
        func evaluate(_ v: Variant) throws -> FEMResult? {
            if isCancelled() { throw FEMError.cancelled }
            var m = mesh, lc = loadCase
            if let (t, _) = v.rotation { m = mesh.transformed(t); lc = loadCase.transformed(t) }
            return try? FEMAnalysis.run(mesh: m, material: v.material ?? material, setup: setup(walls: v.walls, infill: v.infill),
                                        loadCase: lc, options: options, isCancelled: isCancelled)
        }

        let w0 = settings.wallLoops, i0 = settings.infillDensity
        let quarter = Double.pi / 2
        let rotations: [(Transform3D, String)] = [(.rotationX(quarter), "um 90° um die X-Achse gekippt"), (.rotationY(quarter), "um 90° um die Y-Achse gekippt")]
        let stronger = FEMMaterial.catalog.filter { !$0.isFlexible && $0.id != material.id && $0.strengthXY * $0.zStrengthFactor > material.strengthXY * material.zStrengthFactor * 1.1 }
            .sorted { $0.strengthXY * $0.zStrengthFactor < $1.strengthXY * $1.zStrengthFactor }
        let materialCandidates = Array(stronger.prefix(3))

        var out: [FEMSuggestion] = []
        func make(_ goal: FEMSuggestion.Goal, _ v: Variant, _ r: FEMResult, _ title: String, _ detail: String) -> FEMSuggestion {
            FEMSuggestion(goal: goal, title: title, detail: detail, wallLoops: v.walls, infillDensity: v.infill, rotation: v.rotation?.0,
                          rotationName: v.rotation?.1, material: v.material, result: r,
                          safetyRatio: r.safetyFactor / max(base.safetyFactor, 1e-9), massRatio: r.massGrams / max(base.massGrams, 1e-9))
        }
        func percent(_ x: Double) -> String { "\(Int((x * 100).rounded())) %" }

        // — more stable —
        var strongerVariants: [(Variant, String, String)] = []
        strongerVariants.append((Variant(walls: w0 + 2, infill: i0), "Mehr Wände", "\(w0 + 2) statt \(w0) Wände: die Außenhaut trägt den größten Teil der Last."))
        let denser = max(i0 + 0.25, 0.4)
        if i0 < 0.95 { strongerVariants.append((Variant(walls: w0, infill: min(denser, 1)), "Dichtere Füllung", "Füllung \(percent(min(denser, 1))) statt \(percent(i0)).")) }
        strongerVariants.append((Variant(walls: w0 + 2, infill: min(max(i0, 0.3), 1)), "Mehr Wände und Füllung", "\(w0 + 2) Wände und mindestens 30 % Füllung."))
        for r in rotations { strongerVariants.append((Variant(walls: w0, infill: i0, rotation: r, material: nil), "Anders drucken", "Teil \(r.1): die Schichten laufen dann anders zur Kraft.")) }
        for m in materialCandidates { strongerVariants.append((Variant(walls: w0, infill: i0, rotation: nil, material: m), "Material \(m.name)", "\(m.name) statt \(material.name): fester, besonders zwischen den Schichten.")) }
        let lighterWalls = [w0, w0 + 1, w0 + 2], lighterInfill = [0.05, 0.10, 0.20].filter { $0 < i0 - 0.001 }
        total = Double(strongerVariants.count + lighterWalls.count * lighterInfill.count)

        for (v, title, detail) in strongerVariants {
            tick("Variante prüfen: \(title)")
            guard let r = try evaluate(v), r.converged else { continue }
            if r.safetyFactor > base.safetyFactor * 1.08 { out.append(make(.stronger, v, r, title, detail)) }
        }
        // Best orientation also serves as the starting point for savings if it is clearly better.
        var start = Variant(walls: w0, infill: i0)
        if let best = out.filter({ $0.rotation != nil && $0.material == nil }).max(by: { $0.safetyRatio < $1.safetyRatio }), best.safetyRatio > 1.3 {
            start.rotation = rotations.first { $0.1 == best.rotationName }
        }

        // — lighter at about the same safety —
        var lighter: [FEMSuggestion] = []
        for w in lighterWalls { for inf in lighterInfill {
            tick("Material sparen: \(w) Wände, \(percent(inf)) Füllung")
            var v = start; v.walls = w; v.infill = inf
            guard let r = try evaluate(v), r.converged else { continue }
            guard r.safetyFactor >= base.safetyFactor * 0.95, r.massGrams < base.massGrams * 0.97 else { continue }
            let turned = v.rotation.map { " Teil \($0.1)." } ?? ""
            lighter.append(make(.lighter, v, r, "Weniger Material", "\(w) Wände, Füllung \(percent(inf)): \(Int(((1 - r.massGrams / base.massGrams) * 100).rounded())) % leichter bei gleicher Sicherheit.\(turned)"))
        } }
        if let best = lighter.min(by: { $0.result.massGrams < $1.result.massGrams }) { out.append(best) }

        // Strongest first within each goal.
        return out.sorted { $0.goal == $1.goal ? $0.safetyRatio > $1.safetyRatio : $0.goal.rawValue > $1.goal.rawValue }
    }
}
