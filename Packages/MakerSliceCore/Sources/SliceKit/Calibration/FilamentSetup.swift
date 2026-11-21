import Foundation

/// Setting up a new filament with as few test prints as possible: start from what is already known, print only the
/// tests this printer and filament still need, and print the optional ones only when an earlier test asks for them.
public struct FilamentSetupPlan: Sendable {
    public struct Step: Identifiable, Sendable, Equatable {
        public var kind: CalibrationKind
        public var why: String
        /// Set when the test is only needed if an earlier one shows a problem.
        public var onlyIf: String?
        public var id: String { kind.rawValue }
    }

    public struct Skip: Identifiable, Sendable, Equatable {
        public var kind: CalibrationKind
        public var reason: String
        public var id: String { kind.rawValue }
    }

    /// The filament with the best known starting values (already calibrated values, else those of a calibrated
    /// filament of the same type on this printer). The tests centre their ranges on these values.
    public var filament: Filament
    /// Values taken over as a starting point, with the filament they come from.
    public var seeds: [CalibrationResult]
    /// Tests to print, in order.
    public var steps: [Step]
    public var skipped: [Skip]

    /// Print time of the steps that are always needed, in minutes.
    public var requiredMinutes: Int { steps.filter { $0.onlyIf == nil }.reduce(0) { $0 + FilamentSetup.minutes($1.kind) } }
    public var optionalMinutes: Int { steps.filter { $0.onlyIf != nil }.reduce(0) { $0 + FilamentSetup.minutes($1.kind) } }
}

public enum FilamentSetup {
    /// Rough print time per test (see `CalibrationKind.effort`).
    static func minutes(_ kind: CalibrationKind) -> Int {
        switch kind {
        case .temperature: return 35
        case .flow: return 30
        case .pressureAdvance: return 20
        case .retraction: return 35
        case .maxFlow: return 15
        }
    }

    /// Printers that measure the flow dynamics (pressure advance) of every head before each print by themselves.
    static func measuresFlowDynamics(_ printer: PrinterModel) -> Bool { printer == .snapmakerU1 }

    public static func plan(for filament: Filament, printer: PrinterModel, book: CalibrationBook = .shared) -> FilamentSetupPlan {
        let own = book.results(printer: printer, filament: filament.name)
        let done = Set(own.map(\.kind))
        var f = book.apply(to: filament, printer: printer)

        // Starting values from another filament of the same type on this printer (most recent first).
        let group = PrimeTower.bondGroup(filament.type)
        let type = filament.type.uppercased()
        let others = book.all.filter { r in
            r.printer == printer.rawValue && r.filament != filament.name && !done.contains(r.kind)
                && (FilamentLibrary.all.first { $0.filament.name == r.filament }?.filament).map {
                    $0.type.uppercased() == type || ($0.type.uppercased().hasPrefix(type) && PrimeTower.bondGroup($0.type) == group)
                } ?? false
        }
        var seeds: [CalibrationResult] = []
        for kind in CalibrationKind.allCases where !done.contains(kind) {
            guard let r = others.first(where: { $0.kind == kind }) else { continue }
            seeds.append(r)
            switch kind {
            case .temperature:
                f.nozzleTemp = Int(r.value.rounded())
                f.firstLayerNozzleTemp = max(f.firstLayerNozzleTemp, f.nozzleTemp)
            case .flow: f.flowRatio = r.value
            case .pressureAdvance: f.pressureAdvance = r.value > 0 ? r.value : nil
            case .retraction: f.retractLength = r.value
            case .maxFlow: f.maxVolumetricSpeed = r.value
            }
        }

        var steps: [FilamentSetupPlan.Step] = []
        var skipped: [FilamentSetupPlan.Skip] = []
        func plan(_ kind: CalibrationKind, why: String, onlyIf: String? = nil) {
            if done.contains(kind) {
                skipped.append(.init(kind: kind, reason: "Schon kalibriert: \(kind.format(own.first { $0.kind == kind }!.value))."))
            } else {
                steps.append(.init(kind: kind, why: why, onlyIf: onlyIf))
            }
        }
        plan(.temperature, why: "Die wichtigste Größe. Der Turm zeigt zugleich Fäden, Brücken und Oberfläche – daran entscheidet sich, ob der Rückzug-Test überhaupt nötig ist.")
        plan(.flow, why: "Gleicht Durchmesser und Schmelzverhalten dieser Spule aus: geschlossene Oberflächen, maßhaltige Teile.")
        plan(.retraction, why: "Findet die kleinste Rückzugslänge ohne Fäden.",
             onlyIf: "Nur wenn am Temperaturturm bei der gewählten Temperatur noch Fäden zwischen den Säulen hängen.")
        if measuresFlowDynamics(printer) {
            skipped.append(.init(kind: .pressureAdvance, reason: "Der \(printer.displayName) misst vor jedem Druck die Fluss-Dynamik jedes Kopfes selbst."))
        } else {
            plan(.pressureAdvance, why: "Schärfere Ecken und gleichmäßige Linien bei wechselndem Tempo.",
                 onlyIf: "Nur wenn Ecken nach dem Fluss-Test rund oder ausgebeult wirken.")
        }
        plan(.maxFlow, why: "Wie schnell die Düse dieses Filament schmelzen kann. Ohne Test gilt der vorsichtige Wert des Profils (\(formatDecimal(f.maxVolumetricSpeed, digits: 1)) mm³/s).",
             onlyIf: "Nur wenn du schneller drucken willst oder Wände bei hohem Tempo rau und dünn werden.")
        return FilamentSetupPlan(filament: f, seeds: seeds, steps: steps, skipped: skipped)
    }
}
