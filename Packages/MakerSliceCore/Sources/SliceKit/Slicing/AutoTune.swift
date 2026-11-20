import Foundation

/// The settings tuned to the models on the plate: every recommendation that is safe to take over without asking.
public struct AutoTuneResult: Sendable {
    /// Settings before tuning (for "undo").
    public var original: PrintSettings
    public var settings: PrintSettings
    /// What was taken over, in order.
    public var applied: [Recommendation]

    public var changed: Bool { !applied.isEmpty }

    public init(original: PrintSettings, settings: PrintSettings, applied: [Recommendation]) {
        self.original = original
        self.settings = settings
        self.applied = applied
    }
}

/// Picks good settings for a model automatically: runs the advisor, takes over its warnings and suggestions that only
/// change slicing values, and repeats until nothing new comes up.
public enum AutoTune {
    /// Never automatic: what describes the physical setup (the plate that lies in the printer), the printer's own
    /// routines (bed levelling) and changes to the model itself (splitting).
    public static func isAutomatic(_ action: Recommendation.Action) -> Bool {
        switch action {
        case .plate, .leveling, .autoSplit: return false
        default: return true
        }
    }

    public static func run(objects: [ModelObject], settings: PrintSettings, loadedTypes: [String?] = [],
                           dryerHumidity: Double? = nil) -> AutoTuneResult {
        var s = settings
        var scratch = objects
        var applied: [Recommendation] = []
        // Each tip is taken over once. A tip that came back with another value would only push a setting to and fro.
        var taken = Set<String>()
        let analyses = objects.map { PrintAdvisor.analyze($0, supportAngle: settings.supportAngle) }
        for _ in 0..<6 {
            let todo = PrintAdvisor.recommendations(objects: objects, settings: s, loadedTypes: loadedTypes,
                                                    dryerHumidity: dryerHumidity, analyses: analyses)
                .filter { r in
                    guard let action = r.action, r.severity >= .suggestion, isAutomatic(action) else { return false }
                    return !taken.contains(r.id)
                }
            guard !todo.isEmpty else { break }
            for r in todo {
                taken.insert(r.id)
                let before = s
                try? PrintAdvisor.apply(r.action!, settings: &s, objects: &scratch)
                if s != before { applied.append(r) }
            }
        }
        return AutoTuneResult(original: settings, settings: s, applied: applied)
    }
}
