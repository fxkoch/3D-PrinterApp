import SliceKit
import SwiftUI

/// Every further setting of the printer vendor's slicer (Anycubic Slicer Next / Snapmaker Orca) with explanation and
/// recommendation. Values are sent to OrcaSlicer when slicing in the cloud.
struct SlicerOptionsView: View {
    @Binding var settings: PrintSettings
    @State private var search = ""
    @State private var page = SlicerOptionCatalog.pageOrder[0]

    /// Settings the app already offers natively in the other expert sections.
    private var nativeKeys: Set<String> {
        Set(OrcaJob.processOverrides(PrintSettings(printer: settings.printer)).keys)
    }

    private var options: [SlicerOption] {
        let native = nativeKeys
        return SlicerOptionCatalog.options(for: settings.printer).filter { !native.contains($0.key) }
    }

    private var visible: [SlicerOption] {
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return options.filter { $0.page == page } }
        return options.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.summary.localizedCaseInsensitiveContains(q)
                || $0.key.localizedCaseInsensitiveContains(q) || $0.group.localizedCaseInsensitiveContains(q)
        }
    }

    private var groups: [(name: String, items: [SlicerOption])] {
        var order: [String] = []
        var byGroup: [String: [SlicerOption]] = [:]
        for o in visible {
            if byGroup[o.group] == nil { order.append(o.group) }
            byGroup[o.group, default: []].append(o)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    var body: some View {
        List {
            Section {
                if search.isEmpty {
                    Picker("Reiter", selection: $page) {
                        ForEach(SlicerOptionCatalog.pageOrder, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            } footer: {
                Text("Alle Einstellungen aus \(SlicerOptionAdvisor.slicerName(settings.printer)). Sie wirken beim Slicen in der Cloud (OrcaSlicer); der eingebaute Slicer ignoriert sie. Blau markierte Werte weichen vom Standard ab.")
            }
            ForEach(groups, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.items) { option in
                        SlicerOptionRow(option: option, settings: $settings)
                    }
                }
            }
            if !settings.extraOptions.isEmpty {
                Section {
                    Button("Alle \(settings.extraOptions.count) Änderungen zurücksetzen", role: .destructive) {
                        settings.extraOptions = [:]
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Einstellung suchen")
        .navigationTitle("Slicer-Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SlicerOptionRow: View {
    let option: SlicerOption
    @Binding var settings: PrintSettings
    @State private var showHelp = false

    private var recommendation: SlicerOptionAdvisor.Recommendation? {
        SlicerOptionAdvisor.recommendation(for: option, settings: settings)
    }

    private var current: String? { settings.extraOptions[option.key] }
    private var shown: String { current ?? recommendation?.value ?? "" }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            control
            Button { showHelp = true } label: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Erklärung: \(option.title)")
            .popover(isPresented: $showHelp) {
                SlicerOptionHelp(option: option, recommendation: recommendation, current: current) {
                    if let r = recommendation { settings.extraOptions[option.key] = r.value }
                } reset: {
                    settings.extraOptions[option.key] = nil
                }
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    @ViewBuilder private var control: some View {
        let title = Text(option.title).lineLimit(3).foregroundStyle(current == nil ? Color.primary : Color.accentColor)
        switch option.kind {
        case .bool:
            Toggle(isOn: Binding(get: { shown == "1" }, set: { settings.extraOptions[option.key] = $0 ? "1" : "0" })) { title }
        case .choice:
            Picker(selection: Binding(get: { shown }, set: { settings.extraOptions[option.key] = $0 })) {
                ForEach(option.choices, id: \.value) { Text($0.label).tag($0.value) }
            } label: { title }
        default:
            LabeledContent {
                HStack(spacing: 4) {
                    TextField("Standard", text: Binding(get: { shown }, set: { settings.extraOptions[option.key] = $0 }))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(option.kind == .text ? .default : .numbersAndPunctuation)
                        .frame(maxWidth: 70)
                    if !option.unit.isEmpty { Text(option.unit).font(.caption).foregroundStyle(.secondary) }
                }
            } label: { title }
        }
    }
}

private struct SlicerOptionHelp: View {
    let option: SlicerOption
    let recommendation: SlicerOptionAdvisor.Recommendation?
    let current: String?
    let apply: () -> Void
    let reset: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(option.title).font(.headline)
                Text(option.summary).font(.subheadline)
                if !option.unit.isEmpty || option.min != nil || option.max != nil {
                    Text(range).font(.caption).foregroundStyle(.secondary)
                }
                if let r = recommendation {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Empfehlung: \(display(r.value))").font(.subheadline.weight(.semibold))
                            Text(r.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "lightbulb").foregroundStyle(.yellow) }
                    if current != r.value {
                        Button("Empfehlung übernehmen", action: apply).buttonStyle(.borderedProminent)
                    }
                }
                if current != nil {
                    Button("Auf Standard zurücksetzen", role: .destructive, action: reset)
                }
                Text("Einstellung: \(option.key)").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding()
            .frame(maxWidth: 340, alignment: .leading)
        }
        .frame(idealWidth: 340, maxHeight: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var range: String {
        var parts: [String] = []
        if let min = option.min, let max = option.max { parts.append("Bereich \(fmt(min)) – \(fmt(max))") }
        if !option.unit.isEmpty { parts.append("Einheit: \(option.unit)") }
        return parts.joined(separator: " · ")
    }

    private func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }

    private func display(_ value: String) -> String {
        if option.kind == .bool { return value == "1" ? "an" : "aus" }
        if option.kind == .choice, let c = option.choices.first(where: { $0.value == value }) { return c.label }
        return option.unit.isEmpty ? value : "\(value) \(option.unit)"
    }
}
