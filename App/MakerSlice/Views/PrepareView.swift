import SliceKit
import SwiftUI
import UniformTypeIdentifiers

/// Prepare & slice screen: preview, objects, material, quality, then print.
struct PrepareView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var project: PrintProject

    @State private var showLayers = false
    @State private var layer = 0.0
    @State private var quality: PrintSettings.Quality? = .standard

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                preview
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                    .background(Color(.secondarySystemBackground))
                Form {
                    if let warning = project.warning {
                        Section {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.callout)
                        }
                    }
                    if project.imported.plates.count > 1 { plateSection }
                    objectsSection
                    filamentSection
                    settingsSection
                }
            }
            .navigationTitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Schließen") { app.project = nil }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if project.output != nil {
                        Picker("Ansicht", selection: $showLayers) {
                            Image(systemName: "cube").tag(false)
                            Image(systemName: "square.3.layers.3d").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 100)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .onAppear {
                quality = PrintSettings.Quality.allCases.first { $0.layerHeight == project.settings.layerHeight }
                app.sendState = .idle
            }
            .onChange(of: project.output != nil) { _, sliced in
                showLayers = sliced
                if let count = project.output?.layers.count { layer = Double(count - 1) }
            }
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        if showLayers, let output = project.output {
            VStack(spacing: 4) {
                LayerPreview(layers: output.layers, upTo: Int(layer), filaments: project.settings.filaments)
                HStack {
                    Text("Schicht \(Int(layer) + 1)/\(output.layers.count)")
                        .font(.caption.monospacedDigit())
                    Slider(value: $layer, in: 0...Double(max(output.layers.count - 1, 1)), step: 1)
                    Text(String(format: "%.2f mm", output.layers[min(Int(layer), output.layers.count - 1)].z))
                        .font(.caption.monospacedDigit())
                }
                .padding(.horizontal)
                .padding(.bottom, 6)
            }
        } else {
            ModelSceneView(objects: project.objects, filaments: project.settings.filaments,
                           bedSize: project.settings.bedSize)
        }
    }

    // MARK: - Sections

    private var plateSection: some View {
        Section("Platte") {
            Picker("Platte", selection: $project.plate) {
                ForEach(project.imported.plates, id: \.self) { plate in
                    Text("Platte \(plate)").tag(Optional(plate))
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var objectsSection: some View {
        Section {
            ForEach(project.objects) { object in
                ObjectRow(object: object, filaments: project.settings.filaments) { tool in
                    project.setTool(tool, for: object.id)
                }
                .contextMenu { objectMenu(object) }
                .swipeActions {
                    Button(role: .destructive) { project.remove(object.id) } label: { Label("Entfernen", systemImage: "trash") }
                }
            }
        } header: {
            HStack {
                Text("Objekte")
                Spacer()
                Button("Anordnen") { project.autoArrange() }.font(.caption)
            }
        } footer: {
            Text("Tippe auf einen Farbpunkt, um den Druckkopf (T1–T4) zu wählen. Langes Drücken für Drehen, Flachlegen & Co.")
        }
    }

    @ViewBuilder
    private func objectMenu(_ object: ModelObject) -> some View {
        Button { project.layFlat(object.id) } label: { Label("Flach hinlegen", systemImage: "arrow.down.to.line") }
        Button { project.rotate(object.id, degrees: 90) } label: { Label("90° drehen", systemImage: "rotate.right") }
        Button { project.duplicate(object.id) } label: { Label("Duplizieren", systemImage: "plus.square.on.square") }
        Menu {
            ForEach([0.5, 0.8, 1.25, 1.5, 2.0], id: \.self) { f in
                Button("\(Int(f * 100)) %") { project.scale(object.id, factor: f) }
            }
        } label: {
            Label("Skalieren", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        Button(role: .destructive) { project.remove(object.id) } label: { Label("Entfernen", systemImage: "trash") }
    }

    private var filamentSection: some View {
        Section {
            ForEach(0..<4, id: \.self) { tool in
                let loaded = app.printers.status?.filaments
                FilamentRow(tool: tool, filament: $project.settings.filaments[tool],
                            loadedName: loaded.flatMap { tool < $0.count ? $0[tool].displayName : nil },
                            used: project.usedTools.contains(tool))
            }
        } header: {
            Text("Material (Druckköpfe)")
        } footer: {
            if app.printers.status?.filaments.isEmpty == false {
                Text("Erkannt per RFID am \(app.printers.selected?.name ?? "Drucker").")
            }
        }
    }

    private var settingsSection: some View {
        Section("Einstellungen") {
            Picker("Qualität", selection: $quality) {
                ForEach(PrintSettings.Quality.allCases) { q in Text(q.displayName).tag(Optional(q)) }
                if quality == nil { Text(String(format: "Eigene (%.2f mm)", project.settings.layerHeight)).tag(PrintSettings.Quality?.none) }
            }
            .onChange(of: quality) { _, q in
                if let q, q.layerHeight != project.settings.layerHeight { project.settings.apply(q) }
            }
            VStack(alignment: .leading) {
                HStack {
                    Text("Füllung")
                    Spacer()
                    Text("\(Int((project.settings.infillDensity * 100).rounded())) %").foregroundStyle(.secondary)
                }
                Slider(value: $project.settings.infillDensity, in: 0...1, step: 0.05)
            }
            Picker("Stützen", selection: $project.settings.support) {
                ForEach(SupportMode.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Brim (bessere Haftung)", isOn: Binding(
                get: { project.settings.brimWidth > 0 },
                set: { project.settings.brimWidth = $0 ? 5 : 0 }
            ))
            Picker("Druckplatte", selection: $project.settings.plateType) {
                ForEach(PlateType.allCases) { Text($0.displayName).tag($0) }
            }
            NavigationLink("Erweiterte Einstellungen") {
                AdvancedSettingsView(settings: $project.settings)
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 10) {
            switch project.state {
            case .idle:
                Button {
                    project.slice()
                } label: {
                    Label("Slicen", systemImage: "square.stack.3d.down.forward").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(project.objects.isEmpty)
            case .slicing(let phase, let fraction):
                HStack {
                    ProgressView(value: fraction) { Text(phase).font(.caption) }
                    Button("Abbrechen", role: .cancel) { project.cancelSlicing() }
                }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
                Button("Erneut versuchen") { project.slice() }.buttonStyle(.bordered)
            case .done(let output):
                summary(output.estimate)
                printButtons
            }
        }
        .padding()
        .background(.bar)
    }

    private func summary(_ e: PrintEstimate) -> some View {
        HStack {
            stat(e.formattedTime, "Druckzeit", "clock")
            stat(String(format: "%.0f g", e.totalGrams), "Filament", "scalemass")
            stat("\(e.layerCount)", "Schichten", "square.3.layers.3d")
            if e.toolChanges > 0 { stat("\(e.toolChanges)", "Wechsel", "arrow.triangle.swap") }
        }
    }

    private func stat(_ value: String, _ title: String, _ icon: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var printButtons: some View {
        switch app.sendState {
        case .uploading:
            ProgressView("Wird an den Drucker gesendet …")
        case .done:
            Label("Druck gestartet!", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Button("Zum Drucker") {
                app.project = nil
                app.tab = .printer
            }
            .buttonStyle(.borderedProminent)
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.red)
            sendButton
        case .idle:
            sendButton
        }
    }

    private var sendButton: some View {
        HStack {
            Button {
                Task { await app.send(project) }
            } label: {
                Label("Drucken auf \(app.printers.selected?.name ?? "U1")", systemImage: "printer.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
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

private struct ObjectRow: View {
    let object: ModelObject
    let filaments: [Filament]
    let onTool: (Int) -> Void

    var body: some View {
        let size = object.mesh.boundingBox.size
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(object.name).lineLimit(1)
                Text(String(format: "%.0f × %.0f × %.0f mm", size.x, size.y, size.z))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { tool in
                    Button { onTool(tool) } label: {
                        ZStack {
                            Circle().fill(Color(hex: filaments[tool].color))
                            Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                            if object.tool == tool {
                                Circle().strokeBorder(Color.accentColor, lineWidth: 3)
                            }
                            Text("\(tool + 1)").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(hex: filaments[tool].color).contrastingText)
                        }
                        .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct FilamentRow: View {
    let tool: Int
    @Binding var filament: Filament
    let loadedName: String?
    let used: Bool

    var body: some View {
        HStack {
            ZStack {
                Circle().fill(Color(hex: filament.color))
                Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                Text("T\(tool + 1)").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: filament.color).contrastingText)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Menu {
                    ForEach(Filament.presets) { preset in
                        Button(preset.name) {
                            let color = filament.color
                            filament = preset
                            filament.color = color
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(filament.name)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }
                Text("\(filament.nozzleTemp) °C · Bett \(filament.bedTemp) °C" + (loadedName.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ColorPicker("", selection: Binding(
                get: { Color(hex: filament.color) },
                set: { filament.color = $0.hexString }
            ), supportsOpacity: false)
            .labelsHidden()
            if used {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }
}
