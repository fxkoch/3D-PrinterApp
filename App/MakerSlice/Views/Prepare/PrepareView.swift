import SliceKit
import SwiftUI
import UniformTypeIdentifiers

/// Prepare & slice: preview, printer, material, objects, quality, then print.
struct PrepareView: View {
    @Environment(AppModel.self) private var app
    @Bindable var project: PrintProject

    @State private var showLayers = false
    @State private var layer = 0.0
    @State private var filamentSlot: SlotSelection?
    @State private var cutObject: ModelObject?
    @State private var showAdvice = false
    @State private var showPrePrint = false
    @State private var printAfterSlice = false

    struct SlotSelection: Identifiable {
        let id: Int
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                preview
                    .frame(maxWidth: .infinity)
                    .frame(height: 280)
                    .background(Color(.secondarySystemBackground))
                    .overlay(alignment: .topTrailing) { previewToggle }
                ScrollView {
                    VStack(spacing: Theme.spacing) {
                        if let warning = project.warning {
                            Panel {
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout).foregroundStyle(.orange)
                            }
                        }
                        if !project.openRecommendations.isEmpty { advicePanel }
                        printerPanel
                        materialPanel
                        objectsPanel
                        qualityPanel
                    }
                    .padding()
                }
                .background(Color(.systemGroupedBackground))
            }
            .navigationTitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { app.project = nil }.accessibilityIdentifier("closeProject")
                }
                if app.expertMode {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            AdvancedSettingsView(settings: $project.settings)
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .sheet(item: $filamentSlot) { slot in
                FilamentPickerView(settings: $project.settings, slot: slot.id,
                                   loaded: app.printers.status(of: app.printers.selected)?.filaments)
            }
            .sheet(item: $cutObject) { object in
                CutView(project: project, object: object)
            }
            .sheet(isPresented: $showAdvice) {
                RecommendationsView(project: project, mode: .review)
            }
            .sheet(isPresented: $showPrePrint) {
                RecommendationsView(project: project, mode: .beforePrint({ applied in
                    if applied {
                        printAfterSlice = true
                        project.slice()
                    } else {
                        Task { await app.send(project) }
                    }
                }))
            }
            .onChange(of: project.output != nil) { _, sliced in
                showLayers = sliced
                if let count = project.output?.layers.count { layer = Double(count - 1) }
                if sliced, printAfterSlice {
                    printAfterSlice = false
                    Task { await app.send(project) }
                }
            }
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        if showLayers, let output = project.output {
            let count = output.layers.count
            let index = min(Int(layer), count - 1)
            VStack(spacing: 4) {
                LayerPreview(layers: output.layers, index: index, filaments: project.settings.filaments)
                HStack {
                    Text("Schicht \(index + 1)/\(count)").font(.caption.monospacedDigit())
                    Slider(value: $layer, in: 0...Double(max(count - 1, 1)), step: 1)
                    Text(String(format: "%.2f mm", output.layers[index].z)).font(.caption.monospacedDigit())
                }
                .padding(.horizontal)
                .padding(.bottom, 6)
            }
        } else {
            ModelSceneView(objects: project.objects, filaments: project.settings.filaments, bedSize: project.settings.bedSize)
        }
    }

    @ViewBuilder
    private var previewToggle: some View {
        if project.output != nil {
            Picker("Ansicht", selection: $showLayers) {
                Image(systemName: "cube").tag(false)
                Image(systemName: "square.3.layers.3d").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 96)
            .padding(8)
        }
    }

    // MARK: - Panels

    private var advicePanel: some View {
        Panel(title: "Empfehlungen", systemImage: "wand.and.stars") {
            ForEach(project.openRecommendations.prefix(3)) { rec in
                RecommendationRow(recommendation: rec, compact: true) {
                    try? project.apply(rec.action!)
                } dismiss: {
                    project.dismissed.insert(rec.id)
                }
            }
            if project.openRecommendations.count > 3 {
                Button("Alle \(project.openRecommendations.count) Empfehlungen") { showAdvice = true }.font(.subheadline)
            }
        }
    }

    private var printerPanel: some View {
        Panel(title: "Drucker", systemImage: "printer") {
            Picker("Drucker", selection: Binding(
                get: { project.settings.printer },
                set: { model in
                    var s = project.settings
                    s.switchPrinter(to: model)
                    s.filaments = app.printers.suggestedFilaments(
                        for: app.printers.printers.first { app.printers.model(of: $0) == model },
                        current: s.filaments, model: model)
                    project.settings = s
                    if let match = app.printers.printers.first(where: { app.printers.model(of: $0) == model }) {
                        app.printers.selectedID = match.id
                    }
                }
            )) {
                ForEach(PrinterModel.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("printerPicker")
            if let printer = app.printers.selected, app.printers.model(of: printer) == project.settings.printer {
                HStack {
                    Image(systemName: "circle.fill").font(.caption2)
                        .foregroundStyle(app.printers.isOnline(printer) ? .green : .secondary)
                    Text(printer.name).font(.subheadline)
                    Spacer()
                    if let s = app.printers.status(of: printer) {
                        Text(s.state.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Kein \(project.settings.printer.displayName) eingerichtet – du kannst trotzdem slicen und den G-Code teilen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var materialPanel: some View {
        let machine = project.settings.machine
        return Panel(title: machine.multiMaterial == .filamentSwitcher ? "Material (ACE Pro)" : "Material (Druckköpfe)",
                     systemImage: "circle.hexagongrid") {
            HStack(spacing: 10) {
                ForEach(0..<machine.toolCount, id: \.self) { slot in
                    let f = project.settings.filament(for: slot)
                    Button { filamentSlot = SlotSelection(id: slot) } label: {
                        VStack(spacing: 4) {
                            Swatch(color: f.color, label: "\(slot + 1)", selected: project.usedTools.contains(slot), size: 34)
                            Text(f.type).font(.caption2.weight(.medium)).lineLimit(1)
                            Text("\(f.nozzleTemp)°").font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("slot-\(slot)")
                }
            }
            Text("Tippe auf einen Slot, um Material und empfohlene Einstellungen zu wählen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var objectsPanel: some View {
        Panel(title: "Objekte", systemImage: "cube") {
            ForEach(project.objects) { object in
                ObjectRow(object: object, filaments: project.settings.filaments, toolCount: project.settings.machine.toolCount,
                          bedSize: project.settings.bedSize, maxHeight: project.settings.maxHeight) { tool in
                    project.setTool(tool, for: object.id)
                } menu: {
                    Button { cutObject = object } label: { Label("Teilen …", systemImage: "scissors") }
                    Button { project.layFlat(object.id) } label: { Label("Flach hinlegen", systemImage: "arrow.down.to.line") }
                    Button { project.rotate(object.id, degrees: 90) } label: { Label("90° drehen", systemImage: "rotate.right") }
                    Button { project.duplicate(object.id) } label: { Label("Duplizieren", systemImage: "plus.square.on.square") }
                    Menu {
                        ForEach([0.5, 0.8, 1.25, 1.5, 2.0], id: \.self) { f in
                            Button("\(Int(f * 100)) %") { project.scale(object.id, factor: f) }
                        }
                    } label: { Label("Skalieren", systemImage: "arrow.up.left.and.arrow.down.right") }
                    Button(role: .destructive) { project.remove(object.id) } label: { Label("Entfernen", systemImage: "trash") }
                }
                if object.id != project.objects.last?.id { Divider() }
            }
            Button { project.autoArrange() } label: { Label("Automatisch anordnen", systemImage: "square.grid.3x3") }
                .font(.subheadline)
        }
    }

    private var qualityPanel: some View {
        Panel(title: "Druck", systemImage: "slider.horizontal.3") {
            Picker("Qualität", selection: Binding(
                get: { PrintSettings.Quality.allCases.first { $0.layerHeight == project.settings.layerHeight } },
                set: { if let q = $0 { project.settings.apply(q) } }
            )) {
                ForEach(PrintSettings.Quality.allCases) { q in Text(q.displayName).tag(Optional(q)) }
            }
            .pickerStyle(.segmented)
            Text(String(format: "Schichthöhe %.2f mm", project.settings.layerHeight)).font(.caption).foregroundStyle(.secondary)

            Divider()
            HStack {
                Text("Füllung")
                HelpButton(key: .infillPattern)
                Spacer()
                Menu(project.settings.infillPattern.displayName) {
                    Picker("Muster", selection: $project.settings.infillPattern) {
                        ForEach(InfillPattern.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Text("\(Int((project.settings.infillDensity * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $project.settings.infillDensity, in: 0...1, step: 0.05)

            Divider()
            HelpRow(key: .support) {
                Picker("Stützen", selection: $project.settings.support) {
                    ForEach(SupportMode.allCases) { Text($0.displayName).tag($0) }
                }
            }
            HelpRow(key: .brimWidth) {
                Toggle("Brim (Haftrand)", isOn: Binding(
                    get: { project.settings.brimWidth > 0 },
                    set: { project.settings.brimWidth = $0 ? 5 : 0 }
                ))
            }
            HelpRow(key: .ironing) {
                Toggle("Oberseite glätten (Ironing)", isOn: $project.settings.ironing)
            }
            if project.settings.machine.multiMaterial == .filamentSwitcher, project.usedTools.count > 1 {
                HelpRow(key: .primeTower) {
                    Toggle("Reinigungsturm", isOn: $project.settings.primeTower)
                }
            }
            if project.settings.machine.supportsPlateTypes.count > 1 {
                HelpRow(key: .plateType) {
                    Picker("Druckplatte", selection: $project.settings.plateType) {
                        ForEach(project.settings.machine.supportsPlateTypes) { Text($0.displayName).tag($0) }
                    }
                }
            }
            if !app.expertMode {
                Text("Weitere Einstellungen im Expertenmodus (Einstellungen).").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 10) {
            switch project.state {
            case .idle:
                if app.cloud.isComplete {
                    Picker("Slicer", selection: Binding(get: { app.useCloudSlicer }, set: { app.useCloudSlicer = $0 })) {
                        Text("iPhone").tag(false)
                        Text("OrcaSlicer (Cloud)").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("enginePicker")
                }
                Button {
                    project.slice(cloud: app.useCloudSlicer ? app.cloud : nil)
                } label: {
                    Label("Slicen", systemImage: "square.stack.3d.down.forward").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(project.objects.isEmpty)
                .accessibilityIdentifier("sliceButton")
            case .slicing(let phase, let fraction):
                HStack {
                    ProgressView(value: fraction) { Text(phase).font(.caption) }
                    Button("Abbrechen", role: .cancel) { project.cancelSlicing() }
                }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
                Button("Erneut versuchen") { project.slice(cloud: app.useCloudSlicer ? app.cloud : nil) }.buttonStyle(.bordered)
            case .done(let output):
                SummaryRow(estimate: output.estimate)
                    .accessibilityIdentifier("sliceSummary")
                Text("Gesliced mit \(output.engine)").font(.caption2).foregroundStyle(.secondary)
                printButtons
            }
        }
        .padding()
        .background(.bar)
    }

    @ViewBuilder
    private var printButtons: some View {
        switch app.sendState {
        case .uploading:
            ProgressView("Wird gesendet …")
        case .done:
            Label("An den Drucker gesendet", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Button("Zum Drucker") {
                app.project = nil
                app.tab = .printers
            }
            .buttonStyle(.borderedProminent)
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.red)
            sendButtons
        case .idle:
            sendButtons
        }
    }

    private var sendButtons: some View {
        HStack {
            Button {
                if project.openRecommendations.isEmpty {
                    Task { await app.send(project) }
                } else {
                    showPrePrint = true
                }
            } label: {
                Label("Drucken", systemImage: "printer.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("printButton")
            Menu {
                Button { Task { await app.send(project, startPrint: false) } } label: {
                    Label("Nur hochladen", systemImage: "arrow.up.doc")
                }
                if let output = project.output {
                    ShareLink(item: GCodeFile(text: output.gcode, name: project.gcodeFileName),
                              preview: SharePreview(project.gcodeFileName)) {
                        Label("G-Code teilen", systemImage: "square.and.arrow.up")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title2)
            }
        }
    }
}

struct SummaryRow: View {
    let estimate: PrintEstimate

    var body: some View {
        HStack {
            Metric(value: estimate.formattedTime, caption: "Druckzeit", systemImage: "clock")
            Metric(value: String(format: "%.0f g", estimate.totalGrams), caption: "Filament", systemImage: "scalemass")
            Metric(value: "\(estimate.layerCount)", caption: "Schichten", systemImage: "square.3.layers.3d")
            if estimate.toolChanges > 0 {
                Metric(value: "\(estimate.toolChanges)", caption: "Wechsel", systemImage: "arrow.triangle.swap")
            }
        }
    }
}

/// Lets the G-code be shared/saved via the share sheet.
struct GCodeFile: Transferable {
    let text: String
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
            try file.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

private struct ObjectRow<MenuContent: View>: View {
    let object: ModelObject
    let filaments: [Filament]
    let toolCount: Int
    let bedSize: Double
    let maxHeight: Double
    let onTool: (Int) -> Void
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        let size = object.boundingBox.size
        let tooBig = size.x > bedSize || size.y > bedSize || size.z > maxHeight
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(object.name).lineLimit(1)
                Text(String(format: "%.0f × %.0f × %.0f mm", size.x, size.y, size.z))
                    .font(.caption).foregroundStyle(tooBig ? .orange : .secondary)
            }
            Spacer(minLength: 4)
            ForEach(0..<toolCount, id: \.self) { tool in
                Button { onTool(tool) } label: {
                    Swatch(color: tool < filaments.count ? filaments[tool].color : "#888888", label: "\(tool + 1)",
                           selected: object.tool == tool, size: 24)
                }
                .buttonStyle(.plain)
            }
            Menu { menu() } label: {
                Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("objectMenu")
        }
    }
}
