import Foundation

/// The settings tuned to the models on the plate: every recommendation that is safe to take over without asking.
public struct AutoTuneResult: Sendable {
    /// Settings before tuning (for "undo").
    public var original: PrintSettings
    public var settings: PrintSettings
    /// The models with the slots they now print with (an empty head is replaced by one that holds the material).
    public var objects: [ModelObject]
    /// What was taken over, in order.
    public var applied: [Recommendation]

    public var changed: Bool { !applied.isEmpty }

    public init(original: PrintSettings, settings: PrintSettings, objects: [ModelObject] = [], applied: [Recommendation]) {
        self.original = original
        self.settings = settings
        self.objects = objects
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

    /// - Parameter excluding: tips the user dismissed; they are never taken over.
    public static func run(objects: [ModelObject], settings: PrintSettings, loadedTypes: [String?] = [],
                           dryerHumidity: Double? = nil, excluding: Set<String> = []) -> AutoTuneResult {
        var s = settings
        var scratch = objects
        var applied: [Recommendation] = []
        // Each tip is taken over once. A tip that came back with another value would only push a setting to and fro.
        var taken = excluding
        let analyses = objects.map { PrintAdvisor.analyze($0, supportAngle: settings.supportAngle) }
        // One tip at a time, then ask again: a tip can make the next one unnecessary (brim → no elephant-foot tip).
        for _ in 0..<25 {
            let todo = PrintAdvisor.recommendations(objects: scratch, settings: s, loadedTypes: loadedTypes,
                                                    dryerHumidity: dryerHumidity, analyses: analyses)
                .filter { r in
                    guard let action = r.action, r.severity >= .suggestion, isAutomatic(action) else { return false }
                    return !taken.contains(r.id)
                }
            guard let next = todo.first else { break }
            for r in [next] {
                taken.insert(r.id)
                let before = s, toolsBefore = scratch.map(\.allTools)
                try? PrintAdvisor.apply(r.action!, settings: &s, objects: &scratch)
                if s != before || scratch.map(\.allTools) != toolsBefore { applied.append(r) }
            }
        }
        return AutoTuneResult(original: settings, settings: s, objects: scratch, applied: applied)
    }
}
