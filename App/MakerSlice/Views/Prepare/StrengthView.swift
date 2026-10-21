import SliceKit
import SwiftUI

/// Strength check of one object: pick the fixed surface and the loaded surface, set the force, see where it breaks
/// and what would help (more walls, other infill, turning the part, other material).
struct StrengthView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    let project: PrintProject
    let objectID: ModelObject.ID

    private enum Pick: String, CaseIterable, Identifiable {
        case fixed = "Befestigung", load = "Last"
        var id: String { rawValue }
    }
    private enum Direction: String, CaseIterable, Identifiable {
        case into = "Drückt auf die Fläche", away = "Zieht von der Fläche weg", down = "Gewicht (nach unten)"
        var id: String { rawValue }
    }

    @State private var material = FEMMaterial.catalog[0]
    @State private var pick: Pick = .fixed
    @State private var fixed: SurfaceRegion?
    @State private var load: SurfaceRegion?
    @State private var kilograms = 1.0
    @State private var direction: Direction = .into
    @State private var accurate = false
    @State private var longTerm = false
    @State private var running = false
    @State private var phase = ""
    @State private var fraction = 0.0
    @State private var result: FEMResult?
    @State private var showHeat = true
    @State private var error: String?
    @State private var suggestions: [FEMSuggestion] = []
    @State private var searching = false
    @State private var applied: String?
    @State private var task: Task<Void, Never>?
    @State private var savedMessage: String?

    private var object: ModelObject? { project.allObjects.first { $0.id == objectID } }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let object {
                    VStack(spacing: Theme.spacing) {
                        scene(object)
                        setupPanel(object)
                        if running || searching { progressPanel }
                        if let error { Panel(title: "Hinweis", systemImage: "exclamationmark.triangle") { Text(error).foregroundStyle(.red) } }
                        if let result { resultPanel(result) }
                        if !suggestions.isEmpty || searching { suggestionsPanel(object) }
                        if let applied { Text(applied).font(.footnote).foregroundStyle(.green).padding(.horizontal) }
                    }
                    .padding()
                } else {
                    Text("Das Objekt gibt es nicht mehr.").padding()
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Festigkeit prüfen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { task?.cancel(); dismiss() } } }
            .onAppear {
                let type = project.settings.filaments.indices.contains(object?.tool ?? 0) ? project.settings.filaments[object?.tool ?? 0].type : "PLA"
                material = FEMMaterial.matching(filamentType: type)
            }
        }
    }

    // MARK: Parts

    private func scene(_ object: ModelObject) -> some View {
        Panel(title: "Modell", systemImage: "cube") {
            StrengthSceneView(mesh: object.mesh, fixed: fixed, load: load, result: showHeat ? result : nil) { triangle in
                let region = SurfaceRegion.grow(from: triangle, in: object.mesh, name: pick.rawValue, maxAngleDegrees: 20)
                if pick == .fixed { fixed = region } else { load = region }
                result = nil; suggestions = []; error = nil
                if pick == .fixed, load == nil { pick = .load }
            }
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("strengthScene")
            Text(result != nil && showHeat ? "Farbe = Beanspruchung: grün entspannt, rot an der Grenze." : "Tippe eine Fläche an: erst die Befestigung (blau), dann die Fläche, auf die die Kraft wirkt (rot).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func setupPanel(_ object: ModelObject) -> some View {
        Panel(title: "Belastung", systemImage: "arrow.down.to.line") {
            Picker("Fläche wählen für", selection: $pick) {
                ForEach(Pick.allCases) { Text($0.rawValue + ((($0 == .fixed ? fixed : load) != nil) ? " ✓" : "")).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Material", selection: $material) {
                ForEach(FEMMaterial.catalog) { Text($0.name).tag($0) }
            }
            .onChange(of: material) { _, _ in result = nil; suggestions = [] }
            VStack(alignment: .leading) {
                Text("Last: \(kilograms.formatted(.number.precision(.fractionLength(1)))) kg (\(Int((kilograms * 9.81).rounded())) N)")
                Slider(value: $kilograms, in: 0.1...50, step: 0.1) { _ in result = nil; suggestions = [] }
            }
            Picker("Richtung", selection: $direction) {
                ForEach(Direction.allCases) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: direction) { _, _ in result = nil; suggestions = [] }
            if app.expertMode {
                Toggle("Genau rechnen (dauert länger)", isOn: $accurate)
            }
            Button {
                run(object)
            } label: {
                Label("Berechnen", systemImage: "function").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(fixed == nil || load == nil || running || searching)
            .accessibilityIdentifier("strengthRun")
        }
    }

    private var progressPanel: some View {
        Panel {
            ProgressView(value: fraction) { Text(phase).font(.footnote) }
            Button("Abbrechen", role: .cancel) { task?.cancel() }
        }
    }

    private func resultPanel(_ r: FEMResult) -> some View {
        let sf = longTerm ? r.safetyFactorLongTerm : r.safetyFactor
        let (color, verdict) = Self.verdict(sf)
        return Panel(title: "Ergebnis", systemImage: "checkmark.shield") {
            HStack(spacing: 12) {
                Circle().fill(color).frame(width: 18, height: 18)
                VStack(alignment: .leading) {
                    Text(verdict).font(.headline)
                    Text("Sicherheitsfaktor \(sf >= 50 ? "über 50" : sf.formatted(.number.precision(.fractionLength(1)))) – die Last könnte etwa so oft größer sein, bevor es bricht.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Picker("Belastungsdauer", selection: $longTerm) {
                Text("Kurz").tag(false)
                Text("Dauerlast").tag(true)
            }
            .pickerStyle(.segmented)
            Toggle("Beanspruchung im Modell zeigen", isOn: $showHeat)
            HStack {
                Metric(value: String(format: r.maxDisplacement < 0.1 ? "%.3f mm" : "%.2f mm", r.maxDisplacement), caption: "Verformung", systemImage: "arrow.up.and.down")
                Metric(value: String(format: "%.0f g", r.massGrams), caption: "Gewicht", systemImage: "scalemass")
            }
            if r.layerShare > 0.6, sf < 5 {
                Label("Die Schichthaftung ist die Schwachstelle – das Teil liegt ungünstig zur Kraft.", systemImage: "square.3.layers.3d.down.left")
                    .font(.footnote)
            }
            ForEach(r.warnings, id: \.self) { Text("• " + $0).font(.footnote).foregroundStyle(.secondary) }
            if app.expertMode {
                Text("Rasterweite \(String(format: "%.2f", r.elementSize)) mm · \(r.elementCount) Würfel · \(r.iterations) Schritte")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                findImprovements(object: object!, r)
            } label: {
                Label("Verbesserungen vorschlagen", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(running || searching)
            .accessibilityIdentifier("strengthSuggest")
        }
    }

    private func suggestionsPanel(_ object: ModelObject) -> some View {
        Panel(title: "Vorschläge", systemImage: "lightbulb") {
            if suggestions.isEmpty {
                Text("Es wird nichts Besseres gefunden, als du schon eingestellt hast.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(suggestions) { s in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: s.goal == .stronger ? "bolt.shield" : "leaf").foregroundStyle(s.goal == .stronger ? .orange : .green)
                        Text(s.title).font(.headline)
                    }
                    Text(s.detail).font(.footnote)
                    Text(effect(s)).font(.footnote.weight(.semibold))
                    HStack {
                        if s.material == nil {
                            Button("Übernehmen") { apply(s, object: object) }.buttonStyle(.borderedProminent)
                            if s.rotation != nil {
                                Button("Gedreht in Bibliothek sichern") { save(s, object: object) }.buttonStyle(.bordered)
                            }
                        } else {
                            Text("Filament im Slot wechseln, dann erneut berechnen.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.footnote)
                }
                Divider()
            }
            if let savedMessage { Text(savedMessage).font(.footnote).foregroundStyle(.green) }
        }
    }

    // MARK: Logic

    private static func verdict(_ sf: Double) -> (Color, String) {
        if sf >= 2 { return (.green, "Hält mit Reserve") }
        if sf >= 1.3 { return (.orange, "Hält, aber knapp") }
        if sf >= 1 { return (.red, "An der Grenze – wird sich verformen oder reißen") }
        return (.red, "Bricht bei dieser Last")
    }

    private func effect(_ s: FEMSuggestion) -> String {
        let strength = s.safetyRatio >= 1 ? String(format: "%.1f× so fest", s.safetyRatio) : String(format: "%.0f %% der Festigkeit", s.safetyRatio * 100)
        let weight = s.massRatio >= 1 ? String(format: "%.0f %% schwerer", (s.massRatio - 1) * 100) : String(format: "%.0f %% leichter", (1 - s.massRatio) * 100)
        return "\(strength) · \(weight) (\(Int(s.result.massGrams.rounded())) g)"
    }

    private func loadCase() -> FEMLoadCase? {
        guard let fixed, let load else { return nil }
        let newtons = kilograms * 9.81
        let n = load.normal
        let force: Vec3
        switch direction {
        case .into: force = n * (-newtons)
        case .away: force = n * newtons
        case .down: force = Vec3(0, 0, -newtons)
        }
        return FEMLoadCase(fixed: [fixed], loads: [.init(region: load, force: force)])
    }

    private func run(_ object: ModelObject) {
        guard let lc = loadCase() else { return }
        running = true; error = nil; result = nil; suggestions = []; applied = nil; fraction = 0; phase = "Starte …"
        let mesh = object.mesh, material = material, setup = FEMPrintSetup(project.settings)
        let options: FEMOptions = accurate ? .accurate : .fast
        task = Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<FEMResult, Error> in
                Result { try FEMAnalysis.run(mesh: mesh, material: material, setup: setup, loadCase: lc, options: options,
                                             progress: { text, f in Task { @MainActor in phase = text; fraction = f } },
                                             isCancelled: { Task.isCancelled }) }
            }.value
            running = false
            switch outcome {
            case .success(let r): result = r
            case .failure(let e): if (e as? FEMError) != .cancelled { error = Self.message(e) }
            }
        }
    }

    private func findImprovements(object: ModelObject, _ base: FEMResult) {
        guard let lc = loadCase() else { return }
        searching = true; error = nil; suggestions = []; applied = nil; fraction = 0; phase = "Varianten prüfen …"
        let mesh = object.mesh, material = material, settings = project.settings
        task = Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[FEMSuggestion], Error> in
                Result { try FEMAdvisor.suggest(mesh: mesh, material: material, settings: settings, loadCase: lc, baseline: base,
                                                progress: { text, f in Task { @MainActor in phase = text; fraction = f } },
                                                isCancelled: { Task.isCancelled }) }
            }.value
            searching = false
            switch outcome {
            case .success(let list): suggestions = list; if list.isEmpty { error = nil }
            case .failure(let e): if (e as? FEMError) != .cancelled { error = Self.message(e) }
            }
        }
    }

    private func apply(_ s: FEMSuggestion, object: ModelObject) {
        project.settings.wallLoops = s.wallLoops
        project.settings.infillDensity = s.infillDensity
        var text = "Übernommen: \(s.wallLoops) Wände, Füllung \(Int((s.infillDensity * 100).rounded())) %."
        if let rotation = s.rotation {
            project.transform(object.id, rotation)
            fixed = nil; load = nil; pick = .fixed; result = nil; suggestions = []
            text += " Das Teil wurde gedreht – bitte die Flächen neu antippen und noch einmal berechnen."
        }
        applied = text
    }

    /// Stores the turned part as its own 3MF in the library (the original stays).
    private func save(_ s: FEMSuggestion, object: ModelObject) {
        guard let rotation = s.rotation else { return }
        var turned = object.transformed(rotation)
        turned.name = object.name + " (stabiler gedreht)"
        let data = ThreeMFWriter.write([turned.placedOnBed(center: (0, 0))])
        do {
            try app.library.add(data: data, fileName: turned.name + ".3mf", name: turned.name)
            savedMessage = "In der Bibliothek gesichert: „\(turned.name)“."
        } catch {
            savedMessage = "Sichern nicht möglich: \(error.localizedDescription)"
        }
    }

    private static func message(_ e: Error) -> String {
        switch e as? FEMError {
        case .noFixedSupport: return "Bitte erst die Befestigungsfläche antippen."
        case .noLoad: return "Bitte erst die Fläche antippen, auf die die Kraft wirkt."
        case .notConnected: return "Die Lastfläche hängt nicht mit der Befestigung zusammen."
        case .regionNotFound: return "Die gewählte Fläche liegt zu dünn im Modell. Wähle eine größere Fläche."
        case .emptyModel: return "Das Modell ist leer."
        default: return e.localizedDescription
        }
    }
}
