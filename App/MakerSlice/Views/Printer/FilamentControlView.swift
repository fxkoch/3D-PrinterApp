import PrinterKit
import SwiftUI

/// Load, unload and push/pull filament – as far as the printer allows it. Every action asks first (the nozzle gets hot).
struct FilamentControlView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    let printer: PrinterConnection

    private enum Action: Identifiable {
        case load(Int), retract(Int), unload, push(Double), pull(Double)
        var id: String {
            switch self {
            case .load(let s): return "load\(s)"
            case .retract(let s): return "retract\(s)"
            case .unload: return "unload"
            case .push(let mm): return "push\(mm)"
            case .pull(let mm): return "pull\(mm)"
            }
        }
    }

    @State private var slot = 0
    @State private var pendingAction: Action?
    @State private var heatConfirm = false

    private var driver: PrinterDriver { app.printers.driver(for: printer) }
    private var support: FilamentControlSupport { driver.filamentControl }
    private var status: PrinterStatus? { app.printers.status(of: printer) }
    private var busy: Bool { status.map { $0.state == .printing || $0.state == .paused } ?? false }
    private var nozzle: Double { status?.tools.map(\.temperature).max() ?? 0 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    if let note = support.note {
                        Panel(title: "Hinweis", systemImage: "info.circle") { Text(note).font(.footnote) }
                    }
                    if busy {
                        Panel { Label("Während eines Drucks ist das Filament gesperrt.", systemImage: "lock").foregroundStyle(.orange) }
                    }
                    if support.loadSlot || support.unload { slotPanel }
                    if support.extrude { extrudePanel }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Filament bedienen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label("Zurück", systemImage: "chevron.left") } }
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            .confirmationDialog(title(for: pendingAction), isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
                                titleVisibility: .visible) {
                if let action = pendingAction {
                    Button(buttonTitle(action), role: isRemoval(action) ? .destructive : nil) { run(action) }
                }
            } message: { Text(message(for: pendingAction)) }
        }
    }

    private var slotPanel: some View {
        Panel(title: "Spule (AMS)", systemImage: "circle.hexagongrid") {
            if let filaments = status?.filaments, !filaments.isEmpty {
                Picker("Slot", selection: $slot) {
                    ForEach(Array(filaments.prefix(4).enumerated()), id: \.offset) { i, f in
                        Text("\(i + 1) \(f.present ? (f.type ?? "") : "leer")").tag(i)
                    }
                }
                .pickerStyle(.segmented)
            }
            if support.loadSlot {
                Button { pendingAction = .load(slot) } label: { Label("Slot \(slot + 1) laden", systemImage: "arrow.down.to.line").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(busy)
                    .accessibilityIdentifier("loadSlot")
            }
            if support.retract {
                Button { pendingAction = .retract(slot) } label: { Label("Slot \(slot + 1) zurück in die Box ziehen", systemImage: "arrow.uturn.up").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).disabled(busy)
                    .accessibilityIdentifier("retractSlot")
            }
            if support.unload {
                Button { pendingAction = .unload } label: { Label("Filament komplett entladen", systemImage: "arrow.up.to.line").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).disabled(busy)
                    .accessibilityIdentifier("unloadFilament")
            }
            Text("Laden, Zurückziehen und Entladen steuert der Drucker selbst – die Düse heizt er bei Bedarf auf.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var extrudePanel: some View {
        Panel(title: "Von Hand vorschieben / zurückziehen", systemImage: "arrow.up.and.down") {
            Text("Düse: \(Int(nozzle)) °C" + (nozzle < FilamentMove.minimumNozzleTemperature ? " – zu kalt, erst aufheizen." : " – heiß genug."))
                .font(.subheadline)
                .foregroundStyle(nozzle < FilamentMove.minimumNozzleTemperature ? .orange : .green)
            if nozzle < FilamentMove.minimumNozzleTemperature, printer.kind != .anycubicLAN {
                Button { heatConfirm = true } label: { Label("Düse aufheizen …", systemImage: "flame") }
                    .buttonStyle(.bordered).font(.footnote)
                    .confirmationDialog("Düse auf \(heatTemperature) °C heizen?", isPresented: $heatConfirm, titleVisibility: .visible) {
                        Button("Heizen auf \(heatTemperature) °C") {
                            Task { await app.printers.perform(on: printer, "Düse auf \(heatTemperature) °C geheizt") { try await $0.setToolTemperature(tool: 0, heatTemperature) } }
                        }
                    } message: { Text("Die Düse wird heiß. Nichts anfassen.") }
            }
            HStack {
                Button { pendingAction = .push(10) } label: { Label("10 mm vor", systemImage: "arrow.down").frame(maxWidth: .infinity) }
                    .accessibilityIdentifier("pushFilament")
                Button { pendingAction = .pull(10) } label: { Label("10 mm zurück", systemImage: "arrow.up").frame(maxWidth: .infinity) }
                    .accessibilityIdentifier("pullFilament")
            }
            .buttonStyle(.bordered)
            .disabled(busy)
            HStack {
                Button { pendingAction = .push(50) } label: { Text("50 mm vor").frame(maxWidth: .infinity) }
                Button { pendingAction = .pull(50) } label: { Text("50 mm zurück").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.bordered).font(.footnote).disabled(busy)
        }
    }

    private var heatTemperature: Int {
        let type = (status?.filaments.first { $0.present }?.type ?? "PLA").uppercased()
        switch true {
        case type.hasPrefix("PETG"): return 240
        case type.hasPrefix("ABS"), type.hasPrefix("ASA"): return 250
        case type.hasPrefix("PA"), type.hasPrefix("PC"): return 265
        case type.hasPrefix("TPU"): return 225
        default: return 215
        }
    }

    private func isRemoval(_ a: Action) -> Bool { if case .unload = a { return true } else { return false } }

    private func title(for a: Action?) -> String {
        switch a {
        case .load(let s): return "Slot \(s + 1) laden?"
        case .retract(let s): return "Slot \(s + 1) zurückziehen?"
        case .unload: return "Filament entladen?"
        case .push(let mm): return "\(Int(mm)) mm vorschieben?"
        case .pull(let mm): return "\(Int(mm)) mm zurückziehen?"
        case nil: return ""
        }
    }

    private func message(for a: Action?) -> String {
        switch a {
        case .load, .unload, .retract: return "Der Drucker heizt die Düse auf, zieht das alte Filament zurück und bewegt das Filament. Das dauert einige Minuten. Düse und Bett nicht anfassen."
        case .push, .pull: return "Der Extruder bewegt das Filament bei heißer Düse. Nicht in die Düse fassen."
        case nil: return ""
        }
    }

    private func buttonTitle(_ a: Action) -> String {
        switch a {
        case .load(let s): return "Slot \(s + 1) laden"
        case .retract(let s): return "Slot \(s + 1) zurückziehen"
        case .unload: return "Entladen"
        case .push(let mm): return "\(Int(mm)) mm vorschieben"
        case .pull(let mm): return "\(Int(mm)) mm zurückziehen"
        }
    }

    private func run(_ a: Action) {
        Task {
            await app.printers.perform(on: printer, buttonTitle(a)) { d in
                switch a {
                case .load(let s): try await d.loadSlot(s)
                case .retract(let s): try await d.retractSlot(s)
                case .unload: try await d.unloadFilament()
                case .push(let mm): try await d.extrude(millimetres: mm)
                case .pull(let mm): try await d.extrude(millimetres: -mm)
                }
            }
        }
    }
}
