import PrinterKit
import SliceKit
import SwiftUI

/// Problem helper: pick what went wrong, get the steps that help – for the filament in one slot of this printer.
struct TroubleshootView: View {
    @Environment(AppModel.self) private var app
    let printer: PrinterConnection?
    let model: PrinterModel
    @State private var slot = 0

    /// The open print's settings when it is for this printer, otherwise the printer's defaults with the loaded spools.
    private var settings: PrintSettings {
        if let project = app.project, project.calibration == nil, project.settings.printer == model { return project.settings }
        var s = app.settings(for: model)
        s.filaments = app.printers.suggestedFilaments(for: printer, current: s.filaments, model: model)
        return s
    }

    var body: some View {
        let s = settings
        let f = s.filament(for: slot)
        List {
            Section {
                if s.machine.toolCount > 1 {
                    Picker("Gedruckt mit", selection: $slot) {
                        ForEach(0..<s.machine.toolCount, id: \.self) { i in
                            Text("\(s.machine.slotLabel)\(i + 1): \(s.filament(for: i).name)").tag(i)
                        }
                    }
                    .accessibilityIdentifier("troubleshootSlot")
                }
                HStack(spacing: 10) {
                    Swatch(color: f.color, label: "\(slot + 1)", size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name).font(.subheadline.weight(.semibold))
                        Text(String(format: "%d °C · Rückzug %.1f mm · max. %.1f mm³/s", f.nozzleTemp, f.retractLength, f.maxVolumetricSpeed))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Die Vorschläge beziehen sich auf dieses Filament und deine aktuellen Einstellungen.")
            }
            Section("Was ist passiert?") {
                ForEach(PrintProblem.allCases) { problem in
                    NavigationLink {
                        ProblemFixesView(problem: problem, printer: printer, model: model, slot: slot)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: problem.symbol).frame(width: 26).foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(problem.title).font(.subheadline.weight(.semibold))
                                Text(problem.symptom).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("problem-\(problem.rawValue)")
                }
            }
        }
        .navigationTitle("Druckproblem lösen")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Start with the head that printed last, if the printer says so.
            if let active = app.printers.status(of: printer)?.activeTool, active < settings.machine.toolCount { slot = active }
        }
    }
}

/// The steps against one problem, each with its change or test print.
private struct ProblemFixesView: View {
    @Environment(AppModel.self) private var app
    let problem: PrintProblem
    let printer: PrinterConnection?
    let model: PrinterModel
    let slot: Int
    @State private var applied: Set<String> = []
    @State private var pendingTest: CalibrationKind?

    private var openProject: PrintProject? {
        guard let p = app.project, p.calibration == nil, p.settings.printer == model else { return nil }
        return p
    }

    private var settings: PrintSettings {
        if let p = openProject { return p.settings }
        var s = app.settings(for: model)
        s.filaments = app.printers.suggestedFilaments(for: printer, current: s.filaments, model: model)
        return s
    }

    var body: some View {
        let fixes = PrintTroubleshooter.fixes(for: problem, settings: settings, slot: slot)
        List {
            Section {
                Label(problem.symptom, systemImage: problem.symbol).font(.subheadline)
            } footer: {
                Text("Der Reihe nach vorgehen und nach jeder Änderung einen Probedruck machen. Mehrere Änderungen auf einmal verraten nicht, was geholfen hat.")
            }
            Section("Was hilft") {
                ForEach(Array(fixes.enumerated()), id: \.element.id) { i, fix in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(i + 1). \(fix.title)").font(.subheadline.weight(.semibold))
                        Text(fix.detail).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if let change = fix.change { changeButton(change, fix) }
                            if let kind = fix.calibration {
                                Button { pendingTest = kind } label: { Label("Test drucken", systemImage: kind.symbol) }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("fix-\(fix.id)")
                }
            }
        }
        .navigationTitle(problem.title)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(openProject != nil ? "Testdruck öffnen? Das offene Projekt wird geschlossen." : "Testdruck vorbereiten?",
                            isPresented: Binding(get: { pendingTest != nil }, set: { if !$0 { pendingTest = nil } }), titleVisibility: .visible) {
            if let kind = pendingTest {
                Button("\(kind.displayName)-Test öffnen") { startTest(kind) }
            }
        } message: {
            if let kind = pendingTest { Text("\(kind.summary) \(kind.effort). Gedruckt wird erst, wenn du im nächsten Schritt auf „Drucken“ tippst.") }
        }
    }

    @ViewBuilder
    private func changeButton(_ change: ProblemFix.Change, _ fix: ProblemFix) -> some View {
        if applied.contains(fix.id) {
            Label("Übernommen", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if case .setting(let action) = change, Self.isFilamentSetting(action), openProject == nil {
            // Fan and bed belong to the spool's profile: the printer's spools replace them in the next project.
            Text("Gilt nur für einen offenen Druck: im Vorbereiten-Bildschirm den Slot antippen und dort ändern.")
                .foregroundStyle(.secondary)
        } else {
            Button { apply(change, fix) } label: { Label("Übernehmen", systemImage: "checkmark") }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("apply-\(fix.id)")
        }
    }

    private static func isFilamentSetting(_ action: Recommendation.Action) -> Bool {
        switch action {
        case .filamentFan, .filamentBedDelta, .filamentNozzle, .retraction: return true
        default: return false
        }
    }

    private func apply(_ change: ProblemFix.Change, _ fix: ProblemFix) {
        switch change {
        case .filament(let kind, let value):
            // Kept like a calibration result: every later print of this filament on this printer uses it.
            let f = settings.filament(for: slot)
            app.saveCalibration(CalibrationResult(printer: model.rawValue, filament: f.name, kind: kind, value: value))
            if let p = openProject, p.settings.filaments.indices.contains(slot) {
                p.settings.filaments[slot] = CalibrationBook.shared.apply(to: p.settings.filaments[slot], printer: model)
            }
        case .setting(let action):
            if let p = openProject { try? p.apply(action) }
            if !Self.isFilamentSetting(action) {
                var defaults = app.settings(for: model)
                var none: [ModelObject] = []
                try? PrintAdvisor.apply(action, settings: &defaults, objects: &none)
                app.remember(defaults)
            }
        }
        applied.insert(fix.id)
        app.log.add(.info, "Problem-Helfer (\(problem.title)): \(fix.title)", source: "App")
    }

    private func startTest(_ kind: CalibrationKind) {
        let base = app.settings(for: model)
        let f = settings.filament(for: slot)
        app.openCalibration(CalibrationFactory.plan(kind, filament: f, base: base, tool: slot))
    }
}
