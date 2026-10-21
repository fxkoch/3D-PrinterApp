import PrinterKit
import SliceKit
import SwiftUI

/// Calibration prints for one printer: choose the filament, print a test, enter what you see, and the values are kept
/// for every later print of that filament.
struct CalibrationHomeView: View {
    @Environment(AppModel.self) private var app
    let printer: PrinterConnection
    @State private var settings: PrintSettings
    @State private var showPicker = false
    @State private var refresh = 0

    init(printer: PrinterConnection, model: PrinterModel) {
        self.printer = printer
        var s = PrintSettings(printer: model)
        s.filaments = [FilamentLibrary.defaultFilament(for: model)]
        _settings = State(initialValue: s)
    }

    private var model: PrinterModel { settings.printer }
    private var filament: Filament { settings.filament(for: 0) }
    private var loaded: [PrinterStatus.LoadedFilament] { app.printers.status(of: printer)?.filaments ?? [] }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Swatch(color: filament.color, label: "", size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(filament.name).font(.headline)
                        Text(summary(of: filament)).font(.caption).foregroundStyle(.secondary)
                        if let kinds = filament.calibratedKinds, !kinds.isEmpty {
                            Label("Kalibriert: " + kinds.compactMap { CalibrationKind(rawValue: $0)?.displayName }.joined(separator: ", "),
                                  systemImage: "checkmark.seal").font(.caption2).foregroundStyle(.green)
                        }
                    }
                    Spacer()
                }
                ForEach(Array(loaded.enumerated()), id: \.offset) { i, spool in
                    if spool.present, let type = spool.type, let match = FilamentLibrary.bestMatch(type: type, vendor: spool.vendor, printer: model) {
                        Button {
                            var f = match
                            f.color = spool.color ?? f.color
                            settings.filaments[0] = f
                        } label: { Label("Eingelegtes Filament nehmen – Slot \(i + 1): \(spool.displayName)", systemImage: "dot.radiowaves.left.and.right") }
                    }
                }
                Button { showPicker = true } label: { Label("Anderes Filament wählen", systemImage: "list.bullet") }
                    .accessibilityIdentifier("calibrationFilament")
            } header: {
                Text("Filament")
            } footer: {
                Text("Kalibriert wird immer ein bestimmtes Filament an diesem Drucker. Die Werte gelten danach für jeden Druck mit diesem Filamentprofil.")
            }

            Section("Kalibrierdrucke") {
                ForEach(CalibrationKind.allCases) { kind in
                    NavigationLink {
                        CalibrationTestView(kind: kind, filament: filament, settings: settings)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: kind.symbol).frame(width: 28).foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.displayName).font(.subheadline.weight(.semibold))
                                Text(kind.summary).font(.caption).foregroundStyle(.secondary)
                                if let r = CalibrationBook.shared.result(kind, printer: model, filament: filament.name) {
                                    Text("Gespeichert: \(kind.format(r.value)) · \(r.date.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2).foregroundStyle(.green)
                                } else {
                                    Text(kind.effort).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("calibration-\(kind.rawValue)")
                }
            }

            let saved = CalibrationBook.shared.all.filter { $0.printer == model.rawValue }
            if !saved.isEmpty {
                Section {
                    ForEach(saved) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(r.kind.displayName): \(r.kind.format(r.value))").font(.subheadline)
                            Text("\(r.filament) · \(r.date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions { Button("Löschen", role: .destructive) { CalibrationBook.shared.remove(r); refresh += 1 } }
                    }
                } header: {
                    Text("Gespeicherte Werte")
                } footer: {
                    Text(printer.kind == .moonraker
                         ? "Gespeichert in der App und im Drucker (Moonraker-Datenbank „makerslice“). Wischen zum Löschen."
                         : "Gespeichert in der App. Der Kobra S1 bietet im LAN-Modus keinen Speicher für eigene Werte. Wischen zum Löschen.")
                }
            }
        }
        .id(refresh)
        .navigationTitle("Kalibrieren")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            FilamentPickerView(settings: $settings, slot: 0, loaded: nil)
        }
        .task {
            // Start with what the printer reports, if anything.
            if let spool = loaded.first(where: { $0.present && $0.type != nil }), let type = spool.type,
               let match = FilamentLibrary.bestMatch(type: type, vendor: spool.vendor, printer: model) {
                var f = match
                f.color = spool.color ?? f.color
                settings.filaments[0] = f
            }
            await app.syncCalibrations()
        }
    }

    private func summary(of f: Filament) -> String {
        "\(f.nozzleTemp) °C Düse · Fluss \(String(format: "%.2f", f.flowRatio)) · Rückzug \(String(format: "%.1f", f.retractLength)) mm"
    }
}

/// One calibration: why, how, the test print, and entering the result.
struct CalibrationTestView: View {
    @Environment(AppModel.self) private var app
    let kind: CalibrationKind
    let filament: Filament
    let settings: PrintSettings

    private var plan: CalibrationPlan { CalibrationFactory.plan(kind, filament: filament, base: settings) }

    var body: some View {
        let plan = plan
        List {
            Section("Wozu das gut ist") {
                Text(kind.why).font(.subheadline)
                SettingDiagramView(kind: diagram).padding(.vertical, 4)
            }
            Section("So geht's") {
                ForEach(Array(kind.instructions.enumerated()), id: \.offset) { i, text in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(i + 1)").font(.caption.bold()).frame(width: 22, height: 22).background(Color.accentColor.opacity(0.15), in: Circle())
                        Text(text).font(.subheadline)
                    }
                }
            }
            Section {
                Text(plan.note).font(.subheadline)
                ForEach(plan.steps) { step in
                    HStack {
                        Text(step.label).monospacedDigit()
                        Spacer()
                        Text(kind == .maxFlow ? "Höhe \(Int(step.zFrom - 1))–\(Int(step.zTo - 1)) mm" : "Höhe \(Int(step.zFrom))–\(Int(step.zTo)) mm")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button {
                    app.openCalibration(plan)
                } label: { Label("Testdruck vorbereiten", systemImage: "printer") }
                    .accessibilityIdentifier("prepareCalibration")
            } header: {
                Text("Der Testdruck")
            } footer: {
                Text("Die App slict den Test mit \(filament.name) für den \(settings.printer.displayName). Gedruckt wird erst, wenn du im nächsten Schritt auf „Drucken“ tippst.")
            }
            CalibrationResultSection(plan: plan, filamentName: filament.name)
        }
        .navigationTitle(kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var diagram: SettingDiagram {
        switch kind {
        case .temperature, .retraction: return .stringing
        case .flow: return .flow
        case .pressureAdvance: return .jerk
        case .maxFlow: return .speed
        }
    }
}

/// "Which step looks best?" with the explanation of what you might see, and saving the value.
struct CalibrationResultSection: View {
    @Environment(AppModel.self) private var app
    let plan: CalibrationPlan
    let filamentName: String
    @State private var chosen: Int?
    @State private var saved = false
    @State private var noneGood = false

    var body: some View {
        Section {
            ForEach(Array(plan.kind.observations.enumerated()), id: \.offset) { _, o in
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.sees).font(.subheadline.weight(.semibold))
                    Text("Bedeutet: \(o.meaning). \(o.action.prefix(1).uppercased() + o.action.dropFirst()).").font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Beste Stufe", selection: $chosen) {
                Text("Bitte wählen").tag(Int?.none)
                ForEach(plan.steps) { step in Text(step.label).tag(Int?.some(step.index)) }
            }
            .accessibilityIdentifier("bestStep")
            if let chosen, plan.steps.indices.contains(chosen) {
                let value = plan.steps[chosen].value
                Button {
                    app.saveCalibration(CalibrationResult(printer: plan.settings.printer.rawValue, filament: filamentName, kind: plan.kind, value: value))
                    saved = true
                } label: { Label("\(plan.kind.format(value)) für \(filamentName) speichern", systemImage: "checkmark.circle") }
                    .accessibilityIdentifier("saveCalibration")
            }
            if saved {
                Label("Gespeichert – künftige Drucke mit diesem Filament nutzen den Wert automatisch.", systemImage: "checkmark.seal.fill")
                    .font(.footnote).foregroundStyle(.green)
            }
            Button { noneGood.toggle() } label: { Label("Keine Stufe war gut", systemImage: "questionmark.circle") }
                .accessibilityIdentifier("noStepGood")
        } header: {
            Text("Ergebnis auswerten")
        } footer: {
            Text("Wähle die Stufe, die am besten aussieht. Die App rechnet den Wert aus und merkt ihn sich je Drucker und Filament.")
        }
        if noneGood {
            Section("Was jetzt?") {
                ForEach(CalibrationAdvice.whenNoStepIsGood(plan.kind, filamentType: plan.settings.filament(for: 0).type)) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.subheadline.weight(.semibold))
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        if let run = item.run {
                            Button("\(run.displayName)-Test starten") { app.startCalibration(run, like: plan) }
                                .buttonStyle(.bordered).font(.footnote)
                        }
                    }
                }
            }
        }
        let next = CalibrationAdvice.open(printer: plan.settings.printer, filament: filamentName).filter { $0 != plan.kind }
        if !next.isEmpty {
            Section {
                ForEach(next) { kind in
                    Button { app.startCalibration(kind, like: plan) } label: {
                        Label("\(kind.displayName) – \(kind.summary)", systemImage: kind.symbol)
                    }
                }
            } header: {
                Text("Noch offen für \(filamentName)")
            }
        }
    }
}

/// Entering a result from the prepare screen (while or after the test print).
struct CalibrationResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    let plan: CalibrationPlan

    var body: some View {
        NavigationStack {
            List { CalibrationResultSection(plan: plan, filamentName: plan.settings.filament(for: 0).name) }
                .navigationTitle("Ergebnis")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label("Zurück", systemImage: "chevron.left") } }
                    ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
                }
        }
        .presentationDetents([.large])
    }
}
