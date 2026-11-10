import PrinterKit
import SliceKit
import SwiftUI

/// Multi-colour model: which filament prints which colour of the file, and which one the support.
struct MultiColorSetupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let project: PrintProject
    @State private var pickSlot: SlotSelection?

    struct SlotSelection: Identifiable { let id: Int }

    private var toolCount: Int { project.settings.machine.toolCount }
    private var filaments: [Filament] { project.settings.filaments }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Dieses Modell hat \(project.modelColors.count) Farben. Wähle für jede Farbe den Slot am \(project.settings.printer.displayName) und das Filament. Das empfohlene Profil (Temperaturen, Fluss, Kühlung) wird je Filament übernommen – du kannst es danach anpassen.")
                        .font(.subheadline)
                    if project.modelColors.count > toolCount {
                        Label("Das Modell hat mehr Farben (\(project.modelColors.count)) als Slots (\(toolCount)). Mehrere Farben teilen sich einen Slot.",
                              systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                }
                Section("Farben im Modell") {
                    ForEach(project.modelColors) { color in colorRow(color) }
                }
                if shared {
                    Section {
                        Label("Zwei Farben nutzen denselben Slot – sie werden dann in einer Farbe gedruckt.", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                if toolCount > 1 {
                    Section {
                        slotPicker("Stützmaterial", selection: Binding(get: { project.settings.supportSlot },
                                                                         set: { project.settings.supportSlot = $0 }), none: "Wie das Objekt")
                        slotPicker("Stütz-Kontaktschicht", selection: Binding(get: { project.settings.supportInterfaceSlot },
                                                                                set: { project.settings.supportInterfaceSlot = $0 }), none: "Wie die Stütze")
                    } header: {
                        Text("Stützstruktur")
                    } footer: {
                        Text("Mit einem eigenen Slot lassen sich andere Materialien nutzen (z. B. ein lösliches oder günstigeres Filament für Stützen). Gilt nur, wenn Stützen eingeschaltet sind.")
                    }
                }
            }
            .navigationTitle("Farben & Filamente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Übernehmen") { project.finishColorSetup(); dismiss() }.accessibilityIdentifier("colorSetupDone")
                }
            }
            .sheet(item: $pickSlot) { slot in
                FilamentPickerView(settings: Binding(get: { project.settings }, set: { project.settings = $0 }), slot: slot.id,
                                   loaded: app.printers.status(of: app.printers.selected)?.filaments)
            }
        }
        .interactiveDismissDisabled()
        .presentationDetents([.large])
    }

    private var shared: Bool {
        let slots = project.modelColors.compactMap { project.colorMap[$0.tool] }
        return Set(slots).count < slots.count
    }

    private func colorRow(_ color: ModelColor) -> some View {
        let slot = project.colorMap[color.tool] ?? min(color.tool, max(toolCount - 1, 0))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Circle().fill(Color(hex: color.colorHex)).frame(width: 34, height: 34)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Farbe \(color.tool + 1)\(color.type.map { " · \($0)" } ?? "")").font(.subheadline.weight(.semibold))
                    Text(color.users.prefix(3).joined(separator: ", ") + (color.users.count > 3 ? " …" : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 10) {
                Text("Slot").font(.caption).foregroundStyle(.secondary)
                ForEach(0..<toolCount, id: \.self) { s in
                    Button { project.assign(color: color, toSlot: s) } label: {
                        Swatch(color: s < filaments.count ? filaments[s].color : "#888888", label: "\(s + 1)", selected: slot == s, size: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("map-\(color.tool)-slot-\(s)")
                }
            }
            if slot < filaments.count {
                Button { pickSlot = SlotSelection(id: slot) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(filaments[slot].name).font(.subheadline)
                            Text("\(filaments[slot].nozzleTemp) °C Düse · \(filaments[slot].bedTemp) °C Bett")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Filament wählen / anpassen").font(.caption).foregroundStyle(Color.accentColor)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pick-filament-\(color.tool)")
            }
        }
        .padding(.vertical, 4)
    }

    private func slotPicker(_ title: String, selection: Binding<Int?>, none: String) -> some View {
        Picker(title, selection: selection) {
            Text(none).tag(Int?.none)
            ForEach(0..<toolCount, id: \.self) { s in
                Text("Slot \(s + 1): \(s < filaments.count ? filaments[s].name : "")").tag(Int?.some(s))
            }
        }
    }
}
