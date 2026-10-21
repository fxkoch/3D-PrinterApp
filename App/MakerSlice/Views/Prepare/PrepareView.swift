import PrinterKit
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
    @State private var strengthObject: ModelObject?
    @State private var cutObject: ModelObject?
    @State private var colorObject: ModelObject?
    @State private var showAdvice = false
    @State private var showPrePrint = false
    @State private var printAfterSlice = false
    @State private var showFileImporter = false
    @State private var showCalibrationResult = false

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
                if app.expertMode || project.plateCount > 1 { plateStrip }
                ScrollView {
                    VStack(spacing: Theme.spacing) {
                        if let warning = project.warning {
                            Panel {
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout).foregroundStyle(.orange)
                            }
                        }
                        if let plan = project.calibration {
                            calibrationPanel(plan)
                        } else {
                            if !project.openRecommendations.isEmpty { advicePanel }
                            printerPanel
                            materialPanel
                            objectsPanel
                            if project.isMultiColor { multiColorPanel }
                            qualityPanel
                        }
                    }
                    .padding()
                }
                .background(Color(.systemGroupedBackground))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("prepareScroll")
            }
            .navigationTitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { app.project = nil }.accessibilityIdentifier("closeProject")
                }
                if app.expertMode {
                    ToolbarItem(placement: .topBarTrailing) { ProfileImportButton(project: project) }
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
            .sheet(isPresented: $showCalibrationResult) {
                if let plan = project.calibration { CalibrationResultSheet(plan: plan) }
            }
            .sheet(item: $colorObject) { object in
                ColorChangeView(project: project, objectID: object.id)
            }
            .sheet(item: $cutObject) { object in
                CutView(project: project, object: object)
            }
            .sheet(item: $strengthObject) { object in
                StrengthView(ctx: StrengthContext(project: project, objectID: object.id))
            }
            .sheet(isPresented: Binding(get: { project.needsColorSetup }, set: { if !$0 { project.finishColorSetup() } })) {
                MultiColorSetupView(project: project)
            }
            .sheet(isPresented: Binding(get: { project.profileReport != nil && !project.needsColorSetup },
                                        set: { if !$0 { project.dismissProfile() } })) {
                if let report = project.profileReport { ProjectProfileView(project: project, report: report) }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: Self.modelTypes, allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    let data = try? Data(contentsOf: url)
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    if let data { addModel(data: data, fileName: url.lastPathComponent) }
                }
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

    // MARK: - Calibration

    private func calibrationPanel(_ plan: CalibrationPlan) -> some View {
        Panel(title: "Kalibrierdruck: \(plan.kind.displayName)", systemImage: plan.kind.symbol) {
            Text(plan.note).font(.subheadline)
            Text("Filament: \(plan.settings.filament(for: 0).name) · \(plan.settings.printer.displayName)").font(.caption).foregroundStyle(.secondary)
            Text("Die Einstellungen dieses Tests sind fest, damit das Ergebnis aussagekräftig ist. Tippe auf „Slicen“, dann auf „Drucken“. Nach dem Druck trägst du hier ein, welche Stufe am besten aussieht.")
                .font(.caption).foregroundStyle(.secondary)
            Button { showCalibrationResult = true } label: { Label("Ergebnis eintragen", systemImage: "checkmark.circle") }
                .font(.subheadline)
                .accessibilityIdentifier("enterCalibrationResult")
        }
    }

    // MARK: - Plates

    private static let modelTypes: [UTType] = [
        UTType(filenameExtension: "3mf") ?? .data,
        UTType(filenameExtension: "stl") ?? .data,
        UTType(filenameExtension: "obj") ?? .data,
    ]

    private func addModel(data: Data, fileName: String) {
        Task {
            let model = await Task.detached { try? ModelImporter.load(data: data, fileName: fileName) }.value
            if let model { project.addImported(model) } else { app.alert = "„\(fileName)“ konnte nicht gelesen werden." }
        }
    }

    private func addFromLibrary(_ item: LibraryItem) {
        let url = app.library.url(for: item)
        addModel(data: (try? Data(contentsOf: url)) ?? Data(), fileName: item.fileName)
    }

    /// One chip per plate; tap to switch, "+" adds an empty plate.
    private var plateStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(1...project.plateCount, id: \.self) { plate in
                    plateChip(plate)
                }
                Button { project.addPlate() } label: {
                    Image(systemName: "plus").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .accessibilityLabel("Platte hinzufügen")
                .accessibilityIdentifier("addPlate")
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(Color(.secondarySystemBackground))
    }

    private func plateChip(_ plate: Int) -> some View {
        let selected = plate == project.currentPlate
        let count = project.plates[plate - 1].count
        var sliced = false
        if case .done = project.state(ofPlate: plate) { sliced = true }
        return Button { project.currentPlate = plate } label: {
            HStack(spacing: 4) {
                Text("Platte \(plate)")
                Text("\(count)").foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
                if sliced { Image(systemName: "checkmark.circle.fill").imageScale(.small) }
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
        }
        .contextMenu {
            if count == 0, project.plateCount > 1 {
                Button(role: .destructive) { project.removePlate(plate) } label: { Label("Platte entfernen", systemImage: "trash") }
            }
        }
        .accessibilityIdentifier("plate-\(plate)")
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
            if let printer = loadedPrinter, let suggestion = loadedSuggestion(printer) {
                Button {
                    project.settings.filaments = suggestion
                    project.loadedTypes = app.printers.loadedTypes(printer)
                    project.dryerHumidity = app.printers.status(of: printer)?.filamentBox?.humidity
                    project.refreshRecommendations()
                } label: {
                    Label("Eingelegtes Material übernehmen: " + loadedSummary(printer), systemImage: "arrow.down.circle")
                        .font(.caption)
                }
                .accessibilityIdentifier("useLoadedFilaments")
            }
            Text("Tippe auf einen Slot, um Material und empfohlene Einstellungen zu wählen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The selected printer, if it is the model being prepared and reports its spools.
    private var loadedPrinter: PrinterConnection? {
        guard let printer = app.printers.selected, app.printers.model(of: printer) == project.settings.printer,
              let status = app.printers.status(of: printer), !status.filaments.isEmpty else { return nil }
        return printer
    }

    /// Profiles for what is loaded, when they differ from the current choice.
    private func loadedSuggestion(_ printer: PrinterConnection) -> [Filament]? {
        let suggested = app.printers.suggestedFilaments(for: printer, current: project.settings.filaments,
                                                        model: project.settings.printer)
        let differs = zip(suggested, project.settings.filaments).contains { $0.name != $1.name || $0.color != $1.color }
        return differs ? suggested : nil
    }

    private func loadedSummary(_ printer: PrinterConnection) -> String {
        (app.printers.status(of: printer)?.filaments ?? []).map { $0.present ? ($0.type ?? "?") : "leer" }
            .joined(separator: " · ")
    }

    private var objectsPanel: some View {
        Panel(title: project.plateCount > 1 ? "Objekte auf Platte \(project.currentPlate)" : "Objekte", systemImage: "cube") {
            ForEach(project.objects) { object in
                ObjectRow(object: object, filaments: project.settings.filaments, toolCount: project.settings.machine.toolCount,
                          bedSize: project.settings.bedSize, maxHeight: project.settings.maxHeight,
                          onTool: { tool in project.setTool(tool, for: object.id) },
                          onPartTool: { part, tool in project.setPartTool(tool, part: part, for: object.id) }) {
                    Button { cutObject = object } label: { Label("Teilen …", systemImage: "scissors") }
                        .disabled(object.isMultiColor)
                    Button { colorObject = object } label: { Label("Farbwechsel bei Höhe …", systemImage: "paintpalette") }
                        .accessibilityIdentifier("colorChangeMenu")
                    Button { strengthObject = object } label: { Label("Festigkeit prüfen …", systemImage: "checkmark.shield") }
                        .accessibilityIdentifier("strengthMenu")
                    Button { project.layFlat(object.id) } label: { Label("Flach hinlegen", systemImage: "arrow.down.to.line") }
                    Button { project.rotate(object.id, degrees: 90) } label: { Label("90° drehen", systemImage: "rotate.right") }
                    Button { project.duplicate(object.id) } label: { Label("Duplizieren", systemImage: "plus.square.on.square") }
                    if project.plateCount > 1 {
                        Menu {
                            ForEach(1...project.plateCount, id: \.self) { plate in
                                Button("Platte \(plate)") { project.move(object.id, toPlate: plate) }
                                    .disabled(plate == project.currentPlate)
                            }
                        } label: { Label("Auf Platte verschieben", systemImage: "rectangle.on.rectangle") }
                    }
                    Menu {
                        ForEach([0.5, 0.8, 1.25, 1.5, 2.0], id: \.self) { f in
                            Button("\(Int(f * 100)) %") { project.scale(object.id, factor: f) }
                        }
                    } label: { Label("Skalieren", systemImage: "arrow.up.left.and.arrow.down.right") }
                    Button(role: .destructive) { project.remove(object.id) } label: { Label("Entfernen", systemImage: "trash") }
                }
                if object.id != project.objects.last?.id { Divider() }
            }
            if app.expertMode {
                Button { project.autoArrange() } label: { Label("Automatisch anordnen", systemImage: "square.grid.3x3") }
                    .font(.subheadline)
            }
            if app.expertMode, project.plateCount > 1 {
                Button { project.redistributeAll() } label: { Label("Alle Platten neu verteilen", systemImage: "rectangle.grid.2x2") }
                    .font(.subheadline)
                    .accessibilityIdentifier("redistributeAll")
            }
            Menu {
                Button { showFileImporter = true } label: { Label("Aus Dateien …", systemImage: "folder") }
                if !app.library.items.isEmpty {
                    Menu {
                        ForEach(app.library.items) { item in
                            Button(item.name) { addFromLibrary(item) }
                        }
                    } label: { Label("Aus der Bibliothek", systemImage: "books.vertical") }
                }
            } label: { Label("Modell hinzufügen", systemImage: "plus.circle") }
                .font(.subheadline)
                .accessibilityIdentifier("addModel")
        }
    }

    /// Purge tower and colour-change settings, shown when the plate uses more than one slot.
    private var multiColorPanel: some View {
        Panel(title: "Mehrfarbig", systemImage: "paintpalette") {
            let machine = project.settings.machine
            HStack {
                Text("Genutzte Slots")
                Spacer()
                ForEach(project.usedTools, id: \.self) { tool in
                    Swatch(color: tool < project.settings.filaments.count ? project.settings.filaments[tool].color : "#888888",
                           label: "\(tool + 1)", size: 22)
                }
            }
            if project.imported.isMultiColor {
                Button { project.reopenColorSetup() } label: { Label("Farben & Filamente zuordnen …", systemImage: "paintpalette") }
                    .font(.subheadline)
                    .accessibilityIdentifier("openColorSetup")
            }
            if machine.multiMaterial == .filamentSwitcher, app.expertMode {
                HelpRow(key: .primeTower) {
                    Toggle("Reinigungsturm", isOn: $project.settings.primeTower)
                }
                if project.settings.primeTower {
                    HStack {
                        Text("Spülmenge je Wechsel")
                        Spacer()
                        Stepper(value: $project.settings.purgeVolume, in: 0...300, step: 10) {
                            Text(project.settings.purgeVolume == 0 ? "Standard" : String(format: "%.0f mm³", project.settings.purgeVolume))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        .fixedSize()
                    }
                    Text("Weniger Spülmenge spart Filament, kann aber zu Mischfarben nach dem Wechsel führen. Nach dem Slicen siehst du den Abfall in Gramm.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if machine.multiMaterial == .filamentSwitcher {
                Text("Beim Farbwechsel spült der Drucker an einem Reinigungsturm – die App richtet ihn automatisch ein.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Der \(project.settings.printer.displayName) hat vier Druckköpfe – Farbwechsel gehen ohne Reinigungsturm.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
            if app.expertMode {
                Text(String(format: "Schichthöhe %.2f mm", project.settings.layerHeight)).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(qualityHint).font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            if app.expertMode { expertInfill } else { simpleStrength }

            Divider()
            if app.expertMode {
                expertSupport
            } else {
                Toggle("Stützen für Überhänge", isOn: Binding(
                    get: { project.settings.support != .off },
                    set: { project.settings.support = $0 ? .everywhere : .off }
                ))
                .accessibilityIdentifier("supportToggle")
            }
            if project.settings.machine.supportsPlateTypes.count > 1 {
                HelpRow(key: .plateType) {
                    Picker("Druckplatte", selection: $project.settings.plateType) {
                        ForEach(project.settings.machine.supportsPlateTypes) { Text($0.displayName).tag($0) }
                    }
                }
            }
            if app.expertMode {
                HelpRow(key: .brimWidth) {
                    Toggle("Brim (Haftrand)", isOn: Binding(
                        get: { project.settings.brimWidth > 0 },
                        set: { project.settings.brimWidth = $0 ? 5 : 0 }
                    ))
                }
                HelpRow(key: .ironing) {
                    Toggle("Oberseite glätten (Ironing)", isOn: $project.settings.ironing)
                }
            } else {
                Text("Haftrand, Glätten und Reinigungsturm stellt die App bei Bedarf selbst vor (siehe Empfehlungen). Alle Einstellungen gibt es im Expertenmodus.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var qualityHint: String {
        switch PrintSettings.Quality.allCases.first(where: { $0.layerHeight == project.settings.layerHeight }) {
        case .draft: return "Schnell: kürzere Druckzeit, sichtbare Schichten."
        case .standard: return "Standard: gute Balance aus Zeit und Aussehen."
        case .fine: return "Fein: glatte Oberfläche, dauert deutlich länger."
        case .none: return "Eigene Schichthöhe aus dem Modellprofil."
        }
    }

    /// Simple mode: three levels instead of pattern and percentage.
    private var simpleStrength: some View {
        let levels: [(String, Double)] = [("Leicht", 0.10), ("Normal", 0.15), ("Stabil", 0.30)]
        let current = levels.min { abs($0.1 - project.settings.infillDensity) < abs($1.1 - project.settings.infillDensity) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Stabilität")
                HelpButton(key: .infillDensity)
            }
            Picker("Stabilität", selection: Binding(get: { current?.0 ?? "Normal" }, set: { name in
                if let level = levels.first(where: { $0.0 == name }) { project.settings.infillDensity = level.1 }
            })) {
                ForEach(levels, id: \.0) { Text($0.0).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("strengthPicker")
            Text("Leicht spart Material und Zeit, Stabil für Teile, die Kraft aushalten müssen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var expertInfill: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        }
    }

    @ViewBuilder private var expertSupport: some View {
        HelpRow(key: .support) {
            Picker("Stützen", selection: $project.settings.support) {
                ForEach(SupportMode.allCases) { Text($0.displayName).tag($0) }
            }
        }
        if project.settings.support != .off, project.settings.machine.toolCount > 1 {
            Picker("Stütz-Material", selection: $project.settings.supportSlot) {
                Text("Wie das Objekt").tag(Int?.none)
                ForEach(0..<project.settings.machine.toolCount, id: \.self) { s in
                    Text("Slot \(s + 1): \(project.settings.filament(for: s).name)").tag(Int?.some(s))
                }
            }
            .accessibilityIdentifier("supportSlot")
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 10) {
            switch project.state {
            case .idle:
                if app.cloud.isComplete, project.settings.printer != .bambuP1S {
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
                if project.filledPlates.count > 1 {
                    Button {
                        project.sliceAll(cloud: app.useCloudSlicer ? app.cloud : nil)
                    } label: {
                        Label("Alle \(project.filledPlates.count) Platten slicen", systemImage: "square.stack.3d.down.right").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("sliceAllButton")
                }
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
                Text("Gesliced mit \(output.engine)\(project.plateCount > 1 ? " · Platte \(project.currentPlate) von \(project.plateCount)" : "")")
                    .font(.caption2).foregroundStyle(.secondary)
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
            if estimate.purgeGrams > 0.05 {
                Metric(value: String(format: "%.1f g", estimate.purgeGrams), caption: "Abfall", systemImage: "trash")
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
    let onPartTool: (Int, Int) -> Void
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        let size = object.boundingBox.size
        let tooBig = size.x > bedSize || size.y > bedSize || size.z > maxHeight
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(object.name).lineLimit(1)
                    Text(String(format: "%.0f × %.0f × %.0f mm", size.x, size.y, size.z))
                        .font(.caption).foregroundStyle(tooBig ? .orange : .secondary)
                    if !object.colorChanges.isEmpty {
                        Label(object.colorChanges.sorted { $0.z < $1.z }
                            .map { String(format: "%.1f mm → Slot %d", $0.z, $0.tool + 1) }.joined(separator: " · "),
                              systemImage: "paintpalette")
                            .font(.caption2).foregroundStyle(Color.accentColor).lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                swatches(selected: object.tool, action: onTool)
                Menu { menu() } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("objectMenu")
            }
            ForEach(object.parts.indices, id: \.self) { i in
                HStack(spacing: 10) {
                    Image(systemName: "square.on.square").font(.caption).foregroundStyle(.secondary)
                    Text(object.parts[i].name).font(.subheadline).lineLimit(1)
                    Spacer(minLength: 4)
                    swatches(selected: object.parts[i].tool) { onPartTool(i, $0) }
                }
                .padding(.leading, 14)
            }
        }
    }

    private func swatches(selected: Int, action: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            ForEach(0..<toolCount, id: \.self) { tool in
                Button { action(tool) } label: {
                    Swatch(color: tool < filaments.count ? filaments[tool].color : "#888888", label: "\(tool + 1)",
                           selected: selected == tool, size: 24)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
