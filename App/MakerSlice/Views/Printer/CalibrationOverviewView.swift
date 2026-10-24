import PrinterKit
import SliceKit
import SwiftUI

/// The complete calibration for one filament: all tests in the order that builds on each other, and one place to enter
/// every result and save all values at once. (Each test is a print of its own – they all change a setting by height and
/// would disturb each other on one plate.)
struct CalibrationOverviewView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let filament: Filament
    let settings: PrintSettings

    /// The test prints as they were prepared: the steps shown for the result are the ones that were printed.
    @State private var plans: [CalibrationKind: CalibrationPlan] = [:]
    @State private var chosen: [CalibrationKind: Int] = [:]
    @State private var savedCount: Int?
    @State private var refresh = 0

    private var model: PrinterModel { settings.printer }

    /// The filament with everything calibrated so far.
    private var current: Filament { CalibrationBook.shared.apply(to: filament, printer: model) }

    private func plan(_ kind: CalibrationKind) -> CalibrationPlan {
        plans[kind] ?? CalibrationFactory.plan(kind, filament: current, base: settings)
    }

    var body: some View {
        List {
            Section {
                Text("Fünf Testdrucke, einer nach dem anderen. Jeder verändert einen Wert in Stufen von unten nach oben; danach liest du ab, welche Stufe am besten aussieht, und trägst sie hier ein. Zum Schluss speicherst du alle Werte mit einem Tipp – sie gelten dann für jeden Druck mit „\(filament.name)“.")
                    .font(.subheadline)
                Label("Vorher: Filament trocknen, Düse und Platte reinigen. Feuchtes Filament verfälscht jeden Test.", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.orange)
            } header: { Text("So geht's") }

            ForEach(CalibrationAdvice.order) { kind in
                Section {
                    let saved = CalibrationBook.shared.result(kind, printer: model, filament: filament.name)
                    HStack {
                        Image(systemName: kind.symbol).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.displayName).font(.headline)
                            Text(kind.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let saved { Text(kind.format(saved.value)).font(.footnote.weight(.semibold)).foregroundStyle(.green) }
                    }
                    Text(kind.effort).font(.caption2).foregroundStyle(.tertiary)
                    Button {
                        let p = CalibrationFactory.plan(kind, filament: current, base: settings)
                        plans[kind] = p
                        chosen[kind] = nil
                        app.openCalibration(p)
                    } label: { Label("Test drucken …", systemImage: "printer") }
                        .accessibilityIdentifier("overviewPrint-\(kind.rawValue)")
                    let p = plan(kind)
                    Picker("Beste Stufe", selection: Binding(get: { chosen[kind] }, set: { chosen[kind] = $0; savedCount = nil })) {
                        Text("Noch nicht gedruckt").tag(Int?.none)
                        ForEach(p.steps) { step in Text(step.label).tag(Int?.some(step.index)) }
                    }
                    .accessibilityIdentifier("overviewStep-\(kind.rawValue)")
                    DisclosureGroup("Was ich sehen kann") {
                        ForEach(Array(kind.observations.enumerated()), id: \.offset) { _, o in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.sees).font(.footnote.weight(.semibold))
                                Text("Bedeutet: \(o.meaning). \(o.action.prefix(1).uppercased() + o.action.dropFirst()).").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.footnote)
                }
            }

            Section {
                let picks = chosen.compactMap { kind, index -> CalibrationResult? in
                    let p = plan(kind)
                    guard p.steps.indices.contains(index) else { return nil }
                    return CalibrationResult(printer: model.rawValue, filament: filament.name, kind: kind, value: p.steps[index].value)
                }
                Button {
                    picks.forEach { app.saveCalibration($0) }
                    savedCount = picks.count
                    refresh += 1
                } label: { Label("\(picks.count) gewählte Werte speichern", systemImage: "checkmark.circle.fill") }
                    .disabled(picks.isEmpty)
                    .accessibilityIdentifier("overviewSaveAll")
                if let savedCount {
                    Label("\(savedCount) Werte gespeichert – künftige Drucke mit „\(filament.name)“ nutzen sie automatisch.", systemImage: "checkmark.seal.fill")
                        .font(.footnote).foregroundStyle(.green)
                }
            } footer: {
                Text("Tests, die du noch nicht gedruckt hast, bleiben unverändert. Du kannst jederzeit später weitermachen.")
            }
        }
        .navigationTitle("Komplett-Kalibrierung")
        .navigationBarTitleDisplayMode(.inline)
    }
}
