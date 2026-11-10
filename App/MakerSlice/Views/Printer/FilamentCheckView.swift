import PrinterKit
import SliceKit
import SwiftUI

/// Standard check after a filament problem ("abnormaler Filamentrückgang", leer, verstopft): live status as traffic lights,
/// the steps to do by hand, and a re-check. Heating only after an explicit confirmation.
struct FilamentCheckView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    let printer: PrinterConnection

    @State private var done: Set<Int> = []
    @State private var checking = false
    @State private var lastChecked: Date?
    @State private var confirmHeat = false
    @State private var confirmCancel = false

    private var status: PrinterStatus? { app.printers.status(of: printer) }

    private var messages: [String] {
        app.log.entries.prefix(60).filter { $0.source.contains(printer.name) }.map(\.message)
    }

    private var check: FilamentCheck? {
        status.map { FilamentCheck.evaluate($0, messages: Array(messages.prefix(15))) }
    }

    /// Typical nozzle temperature for the material in the active (or first loaded) slot.
    private var heatTemperature: Int {
        guard let s = status else { return 220 }
        let slot = s.filamentBox?.activeSlot ?? s.activeTool
        let type = (slot.flatMap { s.filaments.indices.contains($0) ? s.filaments[$0].type : nil } ?? s.filaments.first { $0.present }?.type ?? "PLA").uppercased()
        switch true {
        case type.hasPrefix("PETG"): return 240
        case type.hasPrefix("ABS"), type.hasPrefix("ASA"): return 250
        case type.hasPrefix("PA"), type.hasPrefix("PC"): return 265
        case type.hasPrefix("TPU"): return 225
        default: return 215
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    if let check { resultPanel(check) } else { Panel { ProgressView("Drucker wird gelesen …") } }
                    stepsPanel
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Filament prüfen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label("Zurück", systemImage: "chevron.left") }.accessibilityIdentifier("backButton") }
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            .task { await recheck() }
            .confirmationDialog("Düse auf \(heatTemperature) °C heizen?", isPresented: $confirmHeat, titleVisibility: .visible) {
                Button("Heizen auf \(heatTemperature) °C") {
                    Task { await app.printers.perform(on: printer, "Düse auf \(heatTemperature) °C geheizt") { try await $0.setToolTemperature(tool: 0, heatTemperature) } }
                }
            } message: { Text("Die Düse wird heiß. Nichts anfassen, bis sie wieder abgekühlt ist.") }
            .confirmationDialog("Druck wirklich abbrechen?", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Druck abbrechen", role: .destructive) {
                    Task { await app.printers.perform(on: printer, "Druck abgebrochen") { try await $0.cancel() } }
                }
            }
        }
    }

    private func color(_ level: FilamentCheck.Level) -> Color {
        switch level { case .ok: return .green; case .unknown: return .gray; case .warning: return .orange; case .problem: return .red }
    }

    private func resultPanel(_ check: FilamentCheck) -> some View {
        Panel(title: "Jetzt gerade", systemImage: "checkmark.shield") {
            Text({
                switch check.overall {
                case .ok: return "Alles in Ordnung."
                case .unknown: return "Einiges lässt sich nicht erkennen – prüfe die Schritte unten von Hand."
                case .warning: return "Auffälligkeiten – die Schritte unten helfen."
                case .problem: return "Problem gefunden – bitte die Schritte unten durchgehen."
                }
            }()).font(.headline).foregroundStyle(color(check.overall))
            ForEach(check.items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(color(item.level)).frame(width: 12, height: 12).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline.weight(.semibold))
                        Text(item.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button { Task { await recheck() } } label: {
                    if checking { ProgressView() } else { Label("Erneut prüfen", systemImage: "arrow.clockwise") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(checking)
                .accessibilityIdentifier("filamentRecheck")
                if let lastChecked { Text("Stand \(lastChecked.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
            }
            if let s = status, s.state == .paused || s.state == .printing || s.state == .error {
                HStack {
                    if s.state == .paused {
                        Button("Druck fortsetzen") { Task { await app.printers.perform(on: printer, "Druck fortgesetzt") { try await $0.resume() } } }
                            .buttonStyle(.bordered)
                    }
                    Button("Druck abbrechen", role: .destructive) { confirmCancel = true }.buttonStyle(.bordered)
                }
                .font(.footnote)
            }
        }
    }

    private var stepsPanel: some View {
        Panel(title: "Schritt für Schritt", systemImage: "list.number") {
            ForEach(Array(FilamentCheck.steps.enumerated()), id: \.offset) { i, step in
                Button {
                    if done.contains(i) { done.remove(i) } else { done.insert(i) }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: done.contains(i) ? "checkmark.circle.fill" : "circle").foregroundStyle(done.contains(i) ? .green : .secondary)
                        Text(step).font(.subheadline).multilineTextAlignment(.leading).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                if i == 1, printer.kind == .anycubicLAN {
                    Text("Am Kobra S1 kann die App die Düse im Leerlauf nicht aufheizen (Anycubic erlaubt das im LAN-Modus nicht). Bitte am Drucker-Display aufheizen (Einstellungen → Temperatur).")
                        .font(.footnote).foregroundStyle(.orange)
                } else if i == 1 {
                    Button { confirmHeat = true } label: { Label("Düse auf \(heatTemperature) °C heizen …", systemImage: "flame") }
                        .buttonStyle(.bordered).font(.footnote)
                        .accessibilityIdentifier("filamentHeat")
                }
            }
        }
    }

    private func recheck() async {
        checking = true
        await app.printers.refresh(printer)
        lastChecked = Date()
        checking = false
    }
}
