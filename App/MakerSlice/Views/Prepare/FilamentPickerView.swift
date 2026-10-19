import PrinterKit
import SliceKit
import SwiftUI

/// Choose the material for a slot. Picking a profile loads its recommended
/// settings; experts can fine-tune and reset to the recommendation.
struct FilamentPickerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Binding var settings: PrintSettings
    let slot: Int
    let loaded: [PrinterStatus.LoadedFilament]?

    @State private var query = ""
    @State private var showEditor = false

    private var current: Filament { settings.filament(for: slot) }

    private var entries: [FilamentLibrary.Entry] {
        let all = FilamentLibrary.entries(for: settings.printer)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.filament.name.localizedCaseInsensitiveContains(q) || $0.filament.type.localizedCaseInsensitiveContains(q) }
    }

    private var grouped: [(String, [FilamentLibrary.Entry])] {
        let own = entries.filter { $0.scope != "any" }
        let brands = Dictionary(grouping: entries.filter { $0.scope == "any" }, by: { $0.filament.vendor })
        var result: [(String, [FilamentLibrary.Entry])] = []
        if !own.isEmpty { result.append(("Für \(settings.printer.displayName)", own)) }
        result += brands.keys.sorted().map { ($0, brands[$0]!) }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Swatch(color: current.color, label: "\(slot + 1)", size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(current.name).font(.headline)
                            Text("\(current.nozzleTemp) °C Düse · \(current.bedTemp) °C Bett · max \(Int(current.maxVolumetricSpeed)) mm³/s")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ColorPicker("Farbe", selection: Binding(
                            get: { Color(hex: current.color) },
                            set: { settings.filaments[slot].color = $0.hexString }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }
                    if let loaded, slot < loaded.count, loaded[slot].present {
                        Button {
                            useLoaded(loaded[slot])
                        } label: {
                            Label("Eingelegtes Material übernehmen: \(loaded[slot].displayName)", systemImage: "dot.radiowaves.left.and.right")
                        }
                    }
                    if app.expertMode {
                        Button { showEditor = true } label: { Label("Werte anpassen", systemImage: "slider.horizontal.3") }
                    }
                }
                ForEach(grouped, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { entry in
                            Button {
                                select(entry.filament)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.filament.name)
                                        Text("\(entry.filament.type) · \(entry.filament.nozzleTemp) °C / \(entry.filament.bedTemp) °C")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if entry.filament.name == current.name {
                                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Material oder Marke")
            .navigationTitle("Slot \(slot + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .sheet(isPresented: $showEditor) {
                FilamentEditor(filament: $settings.filaments[slot], printer: settings.printer)
            }
        }
    }

    private func select(_ filament: Filament) {
        var f = filament
        f.color = current.color
        settings.filaments[slot] = f
    }

    private func useLoaded(_ loaded: PrinterStatus.LoadedFilament) {
        if let type = loaded.type, var f = FilamentLibrary.bestMatch(type: type, vendor: loaded.vendor, printer: settings.printer) {
            f.color = loaded.color ?? current.color
            settings.filaments[slot] = f
        } else if let color = loaded.color {
            settings.filaments[slot].color = color
        }
    }
}

/// Expert editor for one filament profile.
struct FilamentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filament: Filament
    let printer: PrinterModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Temperaturen") {
                    intStepper(.nozzleTemp, $filament.nozzleTemp, 160...320, "°C")
                    intStepper(.firstLayerNozzleTemp, $filament.firstLayerNozzleTemp, 160...320, "°C")
                    intStepper(.bedTemp, $filament.bedTemp, 0...120, "°C")
                    intStepper(.firstLayerBedTemp, $filament.firstLayerBedTemp, 0...120, "°C")
                    intStepper(.smoothPlateBedTemp, $filament.smoothPlateBedTemp, 0...120, "°C")
                }
                Section("Kühlung") {
                    percent(.fanSpeed, $filament.fanSpeed)
                    percent(.overhangFanSpeed, $filament.overhangFanSpeed)
                    intStepper(.fanOffLayers, $filament.fanOffLayers, 0...10, "", step: 1)
                    doubleStepper(.filamentMinLayerTime, $filament.minLayerTime, 0...30, 1, "s")
                }
                Section("Fluss") {
                    doubleStepper(.maxVolumetricSpeed, $filament.maxVolumetricSpeed, 1...40, 0.5, "mm³/s")
                    doubleStepper(.flowRatio, $filament.flowRatio, 0.8...1.2, 0.01, "")
                    doubleStepper(.retractLength, $filament.retractLength, 0...5, 0.1, "mm")
                    doubleStepper(.pressureAdvance, Binding(get: { filament.pressureAdvance ?? 0 },
                                                              set: { filament.pressureAdvance = $0 > 0 ? $0 : nil }),
                                  0...0.2, 0.005, "")
                }
                Section {
                    Text("Quelle: \(filament.source)").font(.caption).foregroundStyle(.secondary)
                    if let recommended = FilamentLibrary.recommended(named: filament.name, printer: printer) {
                        Button("Auf Empfehlung zurücksetzen") {
                            let color = filament.color
                            filament = recommended
                            filament.color = color
                        }
                    }
                }
            }
            .navigationTitle(filament.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }

    private func intStepper(_ key: SettingKey, _ value: Binding<Int>, _ range: ClosedRange<Int>, _ unit: String,
                            step: Int = 5) -> some View {
        HelpRow(key: key) {
            Stepper(value: value, in: range, step: step) {
                LabeledContent(key.help.title, value: "\(value.wrappedValue) \(unit)")
            }
        }
    }

    private func doubleStepper(_ key: SettingKey, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double,
                               _ unit: String) -> some View {
        HelpRow(key: key) {
            Stepper(value: value, in: range, step: step) {
                LabeledContent(key.help.title, value: Self.format(value.wrappedValue, step: step) + (unit.isEmpty ? "" : " \(unit)"))
            }
        }
    }

    private func percent(_ key: SettingKey, _ value: Binding<Double>) -> some View {
        HelpRow(key: key) {
            VStack(alignment: .leading) {
                LabeledContent(key.help.title, value: "\(Int((value.wrappedValue * 100).rounded())) %")
                Slider(value: value, in: 0...1, step: 0.05)
            }
        }
    }

    static func format(_ v: Double, step: Double) -> String {
        step < 0.01 ? String(format: "%.3f", v) : step < 0.1 ? String(format: "%.2f", v) : step < 1 ? String(format: "%.1f", v) : String(format: "%.0f", v)
    }
}
