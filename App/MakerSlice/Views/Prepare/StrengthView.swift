import SliceKit
import SwiftUI

/// Strength check of one object: pick the fixed surface and the loaded surface, set the force, see where it breaks
/// and what would help (more walls, other infill, turning the part, other material).
struct StrengthView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @Bindable var ctx: StrengthContext
    /// Called after "Zum Druck vorbereiten" (workshop only).
    var onHandOver: (() -> Void)?

    private enum Pick: String, CaseIterable, Identifiable {
        case fixed = "Halterung", load = "Last"
        var id: String { rawValue }
    }

    /// Where a force points. "Auf die Fläche" and "von der Fläche weg" only make sense on flat areas.
    private enum Direction: String, CaseIterable, Identifiable {
        case into = "Drückt auf die Fläche", away = "Zieht von der Fläche weg", down = "Nach unten (Gewicht)", up = "Nach oben",
             xPlus = "Nach rechts (+X)", xMinus = "Nach links (−X)", yPlus = "Nach hinten (+Y)", yMinus = "Nach vorn (−Y)"
        var id: String { rawValue }
        var needsFlatSurface: Bool { self == .into || self == .away }
    }

    private enum Shape: String, CaseIterable, Identifiable {
        case auto = "Fläche oder Loch", spot = "Eine Stelle"
        var id: String { rawValue }
    }

    private struct Support: Identifiable {
        let id = UUID()
        var region: SurfaceRegion
        var title: String
    }

    private struct LoadItem: Identifiable {
        let id = UUID()
        var region: SurfaceRegion
        var title: String
        var kilograms = 1.0
        var direction: Direction
        var newtons: Double { kilograms * 9.81 }
    }

    @State private var shape: Shape = .auto
    @State private var spotRadius = 4.0
    @State private var supports: [Support] = []
    @State private var loads: [LoadItem] = []
    @State private var scanReport: WeakSpotReport?
    @State private var reinforcement: FEMReinforcement?
    @State private var reinforceNote: String?
    @State private var pick: Pick = .fixed
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
    @State private var scanning = false
    @State private var applied: String?
    @State private var task: Task<Void, Never>?
    @State private var savedMessage: String?
    @State private var comparison: [MaterialComparison] = []
    @State private var comparing = false
    @State private var orientations: [OrientationOption] = []
    @State private var orienting = false
    /// A tap on the model waiting for the answer "Halterung or Last?".
    @State private var tapped: (triangle: Int, point: Vec3)?
    @State private var autoNote: String?
    @State private var showMore = false

    private var filament: Filament? { ctx.filament }
    private var material: FEMMaterial { ctx.material }
    private var object: ModelObject? { ctx.object.mesh.isEmpty ? nil : ctx.object }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    if let object {
                        VStack(spacing: Theme.spacing) {
                            if running || searching || scanning || comparing || orienting { progressPanel }
                            if let error { Panel(title: "Hinweis", systemImage: "exclamationmark.triangle") { Text(error).foregroundStyle(.red) } }
                            if let result { resultPanel(result).id("result") }
                            if !suggestions.isEmpty || searching { suggestionsPanel(object) }
                            scene(object)
                            pointsPanel(object)
                            DisclosureGroup(isExpanded: $showMore) {
                                VStack(spacing: Theme.spacing) {
                                    setupPanel(object)
                                    weakSpotPanel(object)
                                    if let result { orientationPanel(object, base: result) }
                                    if let result { comparePanel(object, base: result) }
                                    if result != nil || scanReport != nil { reinforcePanel(object) }
                                    if ctx.standalone { handOverPanel(object) }
                                }
                                .padding(.top, 8)
                            } label: {
                                Label("Mehr: Material, Lage, Schwachstellen, Verstärken", systemImage: "ellipsis.circle").font(.subheadline.weight(.semibold))
                            }
                            .padding(14)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                            if let applied { Text(applied).font(.footnote).foregroundStyle(.green).padding(.horizontal) }
                        }
                        .padding()
                    } else {
                        Text("Das Objekt gibt es nicht mehr.").padding()
                    }
                }
                .onChange(of: result == nil) { _, _ in if result != nil { withAnimation { proxy.scrollTo("result", anchor: .top) } } }
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) { if let object { bottomBar(object) } }
            .navigationTitle("Festigkeit prüfen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { task?.cancel(); dismiss() } label: { Label("Zurück", systemImage: "chevron.left") }.accessibilityIdentifier("backButton") }
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { task?.cancel(); dismiss() } }
            }
            .confirmationDialog("Was ist diese Stelle?", isPresented: Binding(get: { tapped != nil }, set: { if !$0 { tapped = nil } }), titleVisibility: .visible) {
                Button("Hier wird es festgehalten (Halterung)") { addTapped(as: .fixed) }
                Button("Hier wirkt eine Kraft (Last)") { addTapped(as: .load) }
                Button("Abbrechen", role: .cancel) {}
            } message: { Text("Tippe auf eine Fläche, ein Schraubenloch oder – mit „Eine Stelle“ – auf einen Punkt.") }
            .onAppear { if supports.isEmpty && loads.isEmpty { autoSetup() } }
        }
    }

    /// Fixed bar at the bottom: the one thing to do next.
    private func bottomBar(_ object: ModelObject) -> some View {
        VStack(spacing: 6) {
            if supports.isEmpty || loads.isEmpty {
                Text(supports.isEmpty ? "Tippe aufs Modell: wo wird es festgehalten?" : "Tippe aufs Modell: wo wirkt die Kraft?")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button { run(object) } label: {
                Label(running ? "Rechnet …" : (result == nil ? "Festigkeit berechnen" : "Neu berechnen"), systemImage: "function").frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(supports.isEmpty || loads.isEmpty || running || searching || scanning)
            .accessibilityIdentifier("strengthRun")
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    private func addTapped(as kind: Pick) {
        guard let tap = tapped, let object else { return }
        tapped = nil
        let normal = object.mesh.faceNormal(tap.triangle)
        let region = shape == .spot
            ? SurfaceRegion.disc(center: tap.point, normal: normal, radius: spotRadius, name: kind.rawValue)
            : SurfaceRegion.pick(from: tap.triangle, in: object.mesh, name: kind.rawValue)
        let label = shape == .spot ? "Stelle" : (region.isCurved ? "Loch/Rundung" : "Fläche")
        if kind == .fixed {
            supports.append(Support(region: region, title: "Halterung \(supports.count + 1) · \(label)"))
        } else {
            loads.append(LoadItem(region: region, title: "Last \(loads.count + 1) · \(label)", direction: region.isCurved ? .down : .into))
        }
        result = nil; suggestions = []; error = nil; reinforcement = nil; comparison = []; orientations = []; autoNote = nil
    }

    /// Screw holes or the bottom face as supports, the farthest top face as load – the user only corrects.
    private func autoSetup() {
        guard let object, let setup = FEMAutoSetup.suggest(mesh: object.mesh) else { return }
        supports = setup.supports.enumerated().map { Support(region: $1.region, title: "Halterung \($0 + 1) · \($1.label)") }
        loads = setup.loads.enumerated().map { LoadItem(region: $1.region, title: "Last \($0 + 1) · \($1.label)", kilograms: 2, direction: $1.region.normal.z > 0.5 ? .down : .into) }
        autoNote = setup.note
        resetResults()
    }

    // MARK: Parts

    private func scene(_ object: ModelObject) -> some View {
        Panel(title: "Modell", systemImage: "cube") {
            StrengthSceneView(mesh: object.mesh, fixed: supports.map(\.region), loads: loads.map(\.region),
                              arrows: loads.map { ($0.region, force(of: $0)) },
                              result: showHeat ? (result ?? scanReport?.result) : nil) { triangle, point in
                tapped = (triangle, point)
            }
            .frame(height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("strengthScene")
            Text((result != nil || scanReport != nil) && showHeat ? "Farbe = Beanspruchung: grün entspannt, rot an der Grenze." : guidance)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var guidance: String {
        if supports.isEmpty { return "Blau = hier wird das Teil festgehalten, rot = hier wirkt die Kraft (der Pfeil zeigt die Richtung). Tippe aufs Modell, um etwas hinzuzufügen." }
        if loads.isEmpty { return "Tippe die Fläche an, auf die die Kraft wirkt (rot)." }
        return "Blau = Halterung, rot = Last. Tippe aufs Modell für weitere Halterungen (mehrere Schrauben) oder Lasten (mehrere Flächen)."
    }

    private func force(of item: LoadItem) -> Vec3 {
        let n = item.region.normal
        switch item.direction {
        case .into: return n * (-item.newtons)
        case .away: return n * item.newtons
        case .down: return Vec3(0, 0, -item.newtons)
        case .up: return Vec3(0, 0, item.newtons)
        case .xPlus: return Vec3(item.newtons, 0, 0)
        case .xMinus: return Vec3(-item.newtons, 0, 0)
        case .yPlus: return Vec3(0, item.newtons, 0)
        case .yMinus: return Vec3(0, -item.newtons, 0)
        }
    }

    /// Supports and loads as lists: tap the model to add, change the force per load, remove with the minus.
    private func pointsPanel(_ object: ModelObject) -> some View {
        Panel(title: "Halterungen und Lasten", systemImage: "arrow.down.to.line") {
            Button { autoSetup() } label: { Label("Automatisch vorschlagen", systemImage: "wand.and.stars").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("autoSetup")
            if let autoNote { Text(autoNote).font(.footnote).foregroundStyle(.secondary) }
            Picker("Form", selection: $shape) {
                ForEach(Shape.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if shape == .spot {
                VStack(alignment: .leading) {
                    Text("Größe der Stelle: \(Int(spotRadius * 2)) mm Durchmesser")
                    Slider(value: $spotRadius, in: 1...15, step: 0.5)
                }
            } else {
                Text("Ein Tipp auf eine Fläche wählt die ganze Fläche, ein Tipp in ein Loch das ganze Loch (z. B. für eine Schraube).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(supports) { item in
                HStack {
                    Image(systemName: "pin.fill").foregroundStyle(.blue)
                    Text(item.title).font(.subheadline)
                    Spacer()
                    Button { supports.removeAll { $0.id == item.id }; resetResults() } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                        .accessibilityLabel("Halterung entfernen")
                }
            }
            ForEach($loads) { $item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(.red)
                        Text(item.title).font(.subheadline.weight(.semibold))
                        Spacer()
                        Button { loads.removeAll { $0.id == item.id }; resetResults() } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                            .accessibilityLabel("Last entfernen")
                    }
                    Text("\(item.kilograms.formatted(.number.precision(.fractionLength(1)))) kg (\(Int(item.newtons.rounded())) N)").font(.subheadline.weight(.semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach([0.5, 1, 2, 5, 10, 20], id: \.self) { kg in
                                Button("\(kg.formatted()) kg") { item.kilograms = kg; resetResults() }
                                    .buttonStyle(.bordered).font(.footnote)
                                    .tint(item.kilograms == kg ? .accentColor : .gray)
                            }
                        }
                    }
                    Slider(value: $item.kilograms, in: 0.1...50, step: 0.1) { _ in resetResults() }
                    Picker("Richtung", selection: $item.direction) {
                        ForEach(Direction.allCases.filter { !($0.needsFlatSurface && item.region.isCurved) }) { Text($0.rawValue).tag($0) }
                    }
                    .onChange(of: item.direction) { _, _ in resetResults() }
                }
                Divider()
            }
            if supports.isEmpty && loads.isEmpty {
                Text("Noch nichts gesetzt.").font(.footnote).foregroundStyle(.secondary)
            }
            if !supports.isEmpty || !loads.isEmpty {
                Button("Alles zurücksetzen", role: .destructive) { supports = []; loads = []; pick = .fixed; resetResults() }.font(.footnote)
            }
        }
    }

    private func setupPanel(_ object: ModelObject) -> some View {
        Panel(title: "Material und Berechnung", systemImage: "function") {
            if ctx.standalone {
                Picker("Material", selection: $ctx.materialChoice) {
                    ForEach(FEMMaterial.catalog) { Text($0.name).tag($0) }
                }
                .onChange(of: ctx.materialChoice) { _, _ in resetResults() }
                Stepper("Wände: \(ctx.settings.wallLoops)", value: Binding(get: { ctx.settings.wallLoops }, set: { ctx.setPrint(walls: $0, infill: ctx.settings.infillDensity); resetResults() }), in: 1...8)
                VStack(alignment: .leading) {
                    Text("Füllung: \(Int((ctx.settings.infillDensity * 100).rounded())) %")
                    Slider(value: Binding(get: { ctx.settings.infillDensity }, set: { ctx.setPrint(walls: ctx.settings.wallLoops, infill: $0); resetResults() }), in: 0.05...1, step: 0.05)
                }
            } else {
                Label("Filament: \(filament?.name ?? "–") → gerechnet als \(material.name)", systemImage: "circle.hexagongrid")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if app.expertMode {
                Toggle("Genau rechnen (dauert länger)", isOn: $accurate)
            }
            Button {
                run(object)
            } label: {
                Label("Berechnen", systemImage: "function").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(supports.isEmpty || loads.isEmpty || running || searching || scanning)
            .accessibilityIdentifier("strengthRun")
        }
    }

    private func resetResults() { orientations = []; result = nil; suggestions = []; comparison = []; reinforcement = nil; scanReport = nil }

    private func orientationPanel(_ object: ModelObject, base: FEMResult) -> some View {
        Panel(title: "Beste Lage auf dem Druckbett", systemImage: "rotate.3d") {
            Text("Wie das Teil liegt, bestimmt, in welche Richtung die schwachen Schichtgrenzen laufen. Hier werden alle sechs Lagen mit deiner Last durchgerechnet, samt Stützmaterial und Höhe.")
                .font(.footnote).foregroundStyle(.secondary)
            Button { rankOrientations(object, base: base) } label: { Label("Lagen vergleichen", systemImage: "rotate.3d").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
                .disabled(running || searching || scanning || comparing || orienting)
                .accessibilityIdentifier("rankOrientations")
            ForEach(orientations) { o in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(o.name).font(.headline)
                        if o.isRecommended { Text("empfohlen").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.green.opacity(0.25), in: Capsule()) }
                        Spacer()
                        Text(o.isCurrent ? String(format: "Faktor %.1f", o.result.safetyFactor) : String(format: "%.1f× so fest", o.safetyRatio))
                            .font(.subheadline.weight(.semibold)).foregroundStyle(o.safetyRatio >= 1.1 ? .green : (o.safetyRatio < 0.9 ? .red : .primary))
                    }
                    Text(String(format: "Höhe %.0f mm · %@", o.height, o.needsSupport ? "braucht Stützen" : "kaum Stützen nötig"))
                        .font(.footnote).foregroundStyle(.secondary)
                    if !o.isCurrent, o.rotation != nil {
                        Button("So drehen") { turn(o, object: object) }.buttonStyle(.bordered).font(.footnote)
                    }
                }
                Divider()
            }
        }
    }

    private func comparePanel(_ object: ModelObject, base: FEMResult) -> some View {
        Panel(title: "Anderes Material?", systemImage: "arrow.left.arrow.right") {
            Text("Rechnet dasselbe Teil mit derselben Last in anderen Materialien – so siehst du vorab, was PETG, ABS, Nylon oder Carbon bringen würden, bevor du etwas kaufst.")
                .font(.footnote).foregroundStyle(.secondary)
            Button { compareMaterials(object, base: base) } label: { Label("Materialien vergleichen", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
                .disabled(running || searching || scanning || comparing)
                .accessibilityIdentifier("compareMaterials")
            ForEach(comparison) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(row.material.name).font(.headline)
                        if row.isCurrent { Text("aktuell").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.accentColor.opacity(0.2), in: Capsule()) }
                        Spacer()
                        Text(row.isCurrent ? String(format: "Faktor %.1f", row.result.safetyFactor) : String(format: "%.1f× so fest", row.safetyRatio))
                            .font(.subheadline.weight(.semibold)).foregroundStyle(row.safetyRatio >= 1.1 ? .green : (row.safetyRatio < 0.9 ? .red : .primary))
                    }
                    Text(String(format: "Steifigkeit %.1f× · Gewicht %.0f g · hitzefest bis ca. %.0f °C", row.stiffnessRatio, row.result.massGrams, row.material.heatDeflection))
                        .font(.footnote).foregroundStyle(.secondary)
                    if !row.isCurrent {
                        let note = row.material.printingNote
                        if !note.isEmpty { Text("Beim Drucken: " + note).font(.footnote) }
                    }
                }
                Divider()
            }
            if !comparison.isEmpty {
                Text("Die Werte sind Richtwerte aus Datenblättern; einzelne Filamente weichen um 20 % und mehr ab.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func handOverPanel(_ object: ModelObject) -> some View {
        Panel(title: "Weiter zum Druck", systemImage: "printer") {
            Text("Speichert das Teil mit den gewählten Wänden und der Füllung in der Bibliothek und öffnet es zum Slicen. Bis dahin ist nichts am Slicer verändert.")
                .font(.footnote).foregroundStyle(.secondary)
            Button { handOver(object) } label: { Label("Zum Druck vorbereiten", systemImage: "arrow.right.circle").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("handOver")
        }
    }

    private func weakSpotPanel(_ object: ModelObject) -> some View {
        Panel(title: "Schwachstellen ohne Last", systemImage: "scope") {
            Text("Zeigt ohne Vorgaben, wo das Teil zuerst nachgibt: Es steht auf seiner Unterseite und wird oben von der Seite und von oben gedrückt.")
                .font(.footnote).foregroundStyle(.secondary)
            Button { scan(object) } label: { Label("Schwachstellen suchen", systemImage: "scope").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
                .disabled(running || searching || scanning)
                .accessibilityIdentifier("weakSpotScan")
            if let report = scanReport {
                if report.spots.isEmpty { Text("Keine auffällige Stelle gefunden.").font(.footnote) }
                ForEach(report.spots) { spot in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stelle in \(Int(spot.location.z.rounded())) mm Höhe – Beanspruchung \(Int((spot.relativeStress * 100).rounded())) %").font(.subheadline.weight(.semibold))
                        Text(spot.reason).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func reinforcePanel(_ object: ModelObject) -> some View {
        Panel(title: "Struktur verbessern", systemImage: "square.stack.3d.up") {
            Text("Verdickt die höchstbelasteten Stellen sanft um höchstens 1,5 mm. Die Form bleibt sonst unverändert und wird nachgerechnet.")
                .font(.footnote).foregroundStyle(.secondary)
            Button { reinforce(object) } label: { Label("Verstärkung berechnen", systemImage: "hammer").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
                .disabled(running || searching || scanning)
                .accessibilityIdentifier("reinforceRun")
            if let note = reinforceNote { Text(note).font(.footnote) }
            if let r = reinforcement {
                Text(String(format: "%.1f× so fest · %.0f %% mehr Material · Oberfläche höchstens %.1f mm verschoben", r.safetyRatio, (r.massRatio - 1) * 100, r.maxShift))
                    .font(.footnote.weight(.semibold))
                if object.isMultiColor {
                    Text("Bei mehrfarbigen Objekten nur als neue Datei sichern.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if !object.isMultiColor { Button("Übernehmen") { applyReinforcement(r, object: object) }.buttonStyle(.borderedProminent) }
                    Button("Als 3MF sichern") { saveReinforcement(r, object: object) }.buttonStyle(.bordered)
                }
                .font(.footnote)
            }
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
            HStack(spacing: 14) {
                Image(systemName: sf >= 2 ? "checkmark.circle.fill" : (sf >= 1 ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"))
                    .font(.system(size: 44)).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verdict).font(.title3.weight(.bold))
                    Text("Sicherheitsfaktor \(sf >= 50 ? "über 50" : sf.formatted(.number.precision(.fractionLength(1)))): die Last dürfte etwa so oft größer sein, bevor es bricht.")
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
                        Button("Übernehmen") { apply(s, object: object) }.buttonStyle(.borderedProminent)
                        if s.rotation != nil {
                            Button("Gedreht in Bibliothek sichern") { save(s, object: object) }.buttonStyle(.bordered)
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
        guard !supports.isEmpty, !loads.isEmpty else { return nil }
        return FEMLoadCase(fixed: supports.map(\.region), loads: loads.map { .init(region: $0.region, force: force(of: $0)) })
    }

    private func run(_ object: ModelObject) {
        guard let lc = loadCase() else { return }
        running = true; error = nil; result = nil; scanReport = nil; reinforcement = nil; suggestions = []; applied = nil; fraction = 0; phase = "Starte …"
        let mesh = object.mesh, material = material, setup = FEMPrintSetup(ctx.settings)
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
        let mesh = object.mesh, material = material, settings = ctx.settings
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

    private func rankOrientations(_ object: ModelObject, base: FEMResult) {
        guard let lc = loadCase() else { return }
        orienting = true; error = nil; fraction = 0; phase = "Lagen vergleichen …"
        let mesh = object.mesh, material = material, setup = FEMPrintSetup(ctx.settings)
        task = Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[OrientationOption], Error> in
                Result { try FEMOrientation.rank(mesh: mesh, material: material, setup: setup, loadCase: lc, baseline: base,
                                                 progress: { text, f in Task { @MainActor in phase = text; fraction = f } },
                                                 isCancelled: { Task.isCancelled }) }
            }.value
            orienting = false
            switch outcome {
            case .success(let rows): orientations = rows
            case .failure(let e): if (e as? FEMError) != .cancelled { error = Self.message(e) }
            }
        }
    }

    private func turn(_ o: OrientationOption, object: ModelObject) {
        guard let rotation = o.rotation else { return }
        ctx.rotate(rotation)
        supports = []; loads = []; pick = .fixed; resetResults()
        applied = "Das Teil liegt jetzt \(o.name.lowercased()). Bitte die Flächen neu antippen und noch einmal berechnen."
    }

    private func compareMaterials(_ object: ModelObject, base: FEMResult) {
        guard let lc = loadCase() else { return }
        comparing = true; error = nil; fraction = 0; phase = "Materialien vergleichen …"
        let mesh = object.mesh, current = material, setup = FEMPrintSetup(ctx.settings)
        let candidates = FEMMaterialComparison.defaultCandidates(current: current)
        task = Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[MaterialComparison], Error> in
                Result { try FEMMaterialComparison.compare(mesh: mesh, current: current, candidates: candidates, setup: setup, loadCase: lc, baseline: base,
                                                           progress: { text, f in Task { @MainActor in phase = text; fraction = f } },
                                                           isCancelled: { Task.isCancelled }) }
            }.value
            comparing = false
            switch outcome {
            case .success(let rows): comparison = rows
            case .failure(let e): if (e as? FEMError) != .cancelled { error = Self.message(e) }
            }
        }
    }

    /// Standalone: store the part with its print hints and open it in the slicer.
    private func handOver(_ object: ModelObject) {
        var copy = object
        copy.name = object.name
        let hints = PrintHints(wallLoops: ctx.settings.wallLoops, infillDensity: ctx.settings.infillDensity, material: material.id)
        do {
            _ = try app.library.add(data: ThreeMFWriter.write([copy.placedOnBed(center: (0, 0))]), fileName: copy.name + ".3mf",
                                    name: copy.name + " (geprüft)", hints: hints)
            if let item = app.library.items.first { onHandOver?(); app.open(item) }
        } catch { savedMessage = "Sichern nicht möglich: \(error.localizedDescription)" }
    }

    private func scan(_ object: ModelObject) {
        scanning = true; error = nil; result = nil; suggestions = []; reinforcement = nil; reinforceNote = nil; fraction = 0; phase = "Schwachstellen suchen …"
        let mesh = object.mesh, material = material, setup = FEMPrintSetup(ctx.settings)
        task = Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<WeakSpotReport, Error> in
                Result { try FEMWeakSpots.scan(mesh: mesh, material: material, setup: setup, options: .fast,
                                               progress: { text, f in Task { @MainActor in phase = text; fraction = f } },
                                               isCancelled: { Task.isCancelled }) }
            }.value
            scanning = false
            switch outcome {
            case .success(let report): scanReport = report
            case .failure(let e): if (e as? FEMError) != .cancelled { error = Self.message(e) }
            }
        }
    }

    private func reinforce(_ object: ModelObject) {
        scanning = true; error = nil; reinforcement = nil; reinforceNote = nil; fraction = 0; phase = "Verstärkung berechnen …"
        let mesh = object.mesh, material = material, setup = FEMPrintSetup(ctx.settings), lc = loadCase()
        task = Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<FEMReinforcement?, Error> in
                Result { try FEMWeakSpots.reinforce(mesh: mesh, material: material, setup: setup, loadCase: lc, options: .fast,
                                                    progress: { text, f in Task { @MainActor in phase = text; fraction = f } },
                                                    isCancelled: { Task.isCancelled }) }
            }.value
            scanning = false
            switch outcome {
            case .success(let r):
                reinforcement = r
                if r == nil { reinforceNote = "Eine kleine Verdickung bringt hier nicht genug (mindestens 5 %). Mehr Wände oder dichtere Füllung helfen eher." }
            case .failure(let e): if (e as? FEMError) != .cancelled { error = Self.message(e) }
            }
        }
    }

    private func applyReinforcement(_ r: FEMReinforcement, object: ModelObject) {
        ctx.replaceMesh(r.mesh)
        supports = []; loads = []; result = nil; scanReport = nil; reinforcement = nil; suggestions = []; pick = .fixed
        applied = "Die verstärkte Form ist übernommen. Für eine neue Rechnung die Flächen erneut antippen."
    }

    private func saveReinforcement(_ r: FEMReinforcement, object: ModelObject) {
        var copy = object
        copy.mesh = r.mesh; copy.volumes = []
        copy.name = object.name + " (verstärkt)"
        do {
            try app.library.add(data: ThreeMFWriter.write([copy.placedOnBed(center: (0, 0))]), fileName: copy.name + ".3mf", name: copy.name)
            savedMessage = "In der Bibliothek gesichert: „\(copy.name)“."
        } catch { savedMessage = "Sichern nicht möglich: \(error.localizedDescription)" }
    }

    private func apply(_ s: FEMSuggestion, object: ModelObject) {
        ctx.setPrint(walls: s.wallLoops, infill: s.infillDensity)
        var text = "Übernommen: \(s.wallLoops) Wände, Füllung \(Int((s.infillDensity * 100).rounded())) %."
        if let rotation = s.rotation {
            ctx.rotate(rotation)
            supports = []; loads = []; pick = .fixed; result = nil; suggestions = []
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
