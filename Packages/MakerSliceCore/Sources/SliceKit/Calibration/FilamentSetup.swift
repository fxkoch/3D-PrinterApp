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

    /// Printers that measure the flow dynamics (pressure advance) before every print the app starts. None does: the U1's
    /// "dynamic flow calibration" only runs when it is switched on for a job at the printer, and the Kobra S1's only
    /// with its start option.
    static func measuresFlowDynamics(_ printer: PrinterModel) -> Bool { false }

    public static func plan(for filament: Filament, printer: PrinterModel, book: CalibrationBook = .shared) -> FilamentSetupPlan {
        // Values from the problem helper or typed in by hand are no calibration: those tests still run.
        let own = book.results(printer: printer, filament: filament.name).filter(\.isTest)
        let done = Set(own.map(\.kind))
        var f = book.apply(to: filament, printer: printer)

        // Starting values from another filament of the same type on this printer (most recent first).
        let group = PrimeTower.bondGroup(filament.type)
        let type = filament.type.uppercased()
        // Only the exact same type (PLA-CF, PLA Silk or PETG-CF behave differently); same vendor first.
        _ = group
        let others = book.all.filter { r in
            r.isTest && r.printer == printer.rawValue && r.filament != filament.name && !done.contains(r.kind)
                && (FilamentLibrary.all.first { $0.filament.name == r.filament }?.filament).map { $0.type.uppercased() == type } ?? false
        }.sorted { a, b in
            let va = FilamentLibrary.all.first { $0.filament.name == a.filament }?.filament.vendor == filament.vendor
            let vb = FilamentLibrary.all.first { $0.filament.name == b.filament }?.filament.vendor == filament.vendor
            return va != vb ? va : a.date > b.date
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
        // A pressure advance the printer measured itself is a good start; for PETG/TPU U1 users found it clearly lower
        // than a printed test (0.033 vs 0.051), so it is checked once more on demand.
        let autoPA = own.first { $0.kind == .pressureAdvance && $0.source == "auto" }
        let checkAutoPA = autoPA != nil && (type.hasPrefix("PETG") || type.hasPrefix("PCTG") || filament.isFlexible)
        var skipped: [FilamentSetupPlan.Skip] = []
        func plan(_ kind: CalibrationKind, why: String, onlyIf: String? = nil) {
            if done.contains(kind) {
                skipped.append(.init(kind: kind, reason: "Schon kalibriert: \(kind.format(own.first { $0.kind == kind }!.value))."))
            } else {
                steps.append(.init(kind: kind, why: why, onlyIf: onlyIf))
            }
        }
        // Order of the OrcaSlicer calibration guide: temperature, (max flow), pressure advance, flow, (retraction).
        plan(.temperature, why: "Die wichtigste Größe. Der Turm zeigt zugleich Fäden, Brücken und Oberfläche – daran entscheidet sich, ob der Rückzug-Test überhaupt nötig ist.")
        plan(.maxFlow, why: "Wie schnell die Düse dieses Filament schmelzen kann. Ohne Test gilt der vorsichtige Wert des Profils (\(formatDecimal(f.maxVolumetricSpeed, digits: 1)) mm³/s).",
             onlyIf: "Nur wenn du schneller drucken willst oder Wände bei hohem Tempo rau und dünn werden.")
        if measuresFlowDynamics(printer) {
            skipped.append(.init(kind: .pressureAdvance, reason: "Der \(printer.displayName) misst die Fluss-Dynamik vor jedem Druck selbst."))
        } else if checkAutoPA {
            steps.append(.init(kind: .pressureAdvance, why: "Der U1 hat \(formatDecimal(autoPA!.value, digits: 3)) gemessen. Bei PETG und TPU liegt der automatische Wert oft zu niedrig.",
                               onlyIf: "Nur wenn Ecken rund wirken oder nach Ecken Material fehlt."))
        } else {
            plan(.pressureAdvance, why: printer == .snapmakerU1
                 ? "Schärfere Ecken und gleichmäßige Linien. Der U1 misst diesen Wert nur, wenn am Drucker die dynamische Flusskalibrierung für einen Druck eingeschaltet ist – für Drucke aus der App gilt der hier gemessene Wert."
                 : "Schärfere Ecken und gleichmäßige Linien bei wechselndem Tempo. Am besten vor dem Fluss-Test, er wird dann leichter abzulesen.")
        }
        plan(.flow, why: "Gleicht Durchmesser und Schmelzverhalten dieser Spule aus: geschlossene Oberflächen, maßhaltige Teile.")
        plan(.retraction, why: "Findet die kleinste Rückzugslänge ohne Fäden.",
             onlyIf: "Nur wenn am Temperaturturm bei der gewählten Temperatur noch Fäden zwischen den Säulen hängen. Vorher Filament trocknen.")
        return FilamentSetupPlan(filament: f, seeds: seeds, steps: steps, skipped: skipped)
    }
}
