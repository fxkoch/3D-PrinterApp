import SliceKit
import SwiftUI

/// Position, rotation, lying face and size of the objects on the plate. A bed map from above lets you pick an object
/// and drag it; buttons move, turn and tip it precisely. Nothing else on the plate moves.
struct ObjectPlacementView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var project: PrintProject
    @State var selectedID: ModelObject.ID
    @State private var faces: [LyingFace] = []
    @State private var loadingFaces = false
    @State private var drag: CGSize = .zero
    @State private var step = 10.0

    private var object: ModelObject? { project.objects.first { $0.id == selectedID } }
    private var bed: Double { project.settings.bedSize }
    /// Changes whenever the selected object's shape or orientation changes (not when it only moves).
    private var faceKey: String {
        guard let o = object else { return "" }
        let s = o.boundingBox.size
        return "\(o.id)-\(Int(s.x * 10))-\(Int(s.y * 10))-\(Int(s.z * 10))-\(o.mesh.vertices.first.map { "\(Int($0.z * 100))" } ?? "")"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    bedMap
                        .frame(height: 280)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                } footer: {
                    Text("Objekt antippen zum Auswählen, mit dem Finger verschieben. Rot umrandet: überlappt ein anderes Objekt.")
                }
                if let o = object {
                    positionSection(o)
                    rotationSection
                    faceSection
                    sizeSection(o)
                }
                Section {
                    Button { project.autoArrange() } label: { Label("Alle automatisch anordnen", systemImage: "square.grid.3x3") }
                        .accessibilityIdentifier("placementAutoArrange")
                } footer: {
                    Text("Packt alle Objekte dieser Platte dicht und mittig, mit Platz für Brim und Skirt.")
                }
            }
            .navigationTitle(object?.name ?? "Position")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .task(id: faceKey) { await loadFaces() }
        }
    }

    // MARK: Bed map

    private var bedMap: some View {
        GeometryReader { geo in mapContent(size: geo.size) }
    }

    private func mapContent(size: CGSize) -> some View {
        let side = min(size.width, size.height)
        let scale = side / CGFloat(bed)
        let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
        let hulls = project.objects.map { ($0.id, $0.footprintHull()) }
        let selected = selectedID, offset = drag, overlapping = project.overlapping
        let colors = Dictionary(uniqueKeysWithValues: project.objects.map { ($0.id, project.settings.filament(for: $0.tool).color) })
        let bedSize = bed
        let canvas = Canvas { context, _ in
            func screen(_ p: (x: Double, y: Double), _ id: ModelObject.ID) -> CGPoint {
                let o = id == selected ? offset : .zero
                return CGPoint(x: origin.x + CGFloat(p.x) * scale + o.width, y: origin.y + side - CGFloat(p.y) * scale + o.height)
            }
            let bedRect = CGRect(x: origin.x, y: origin.y, width: side, height: side)
            context.fill(SwiftUI.Path(roundedRect: bedRect, cornerRadius: 6), with: .color(Color(.tertiarySystemFill)))
            var grid = SwiftUI.Path()
            for v in stride(from: 0.0, through: bedSize, by: 25.0) {
                let o = CGFloat(v) * scale
                grid.move(to: CGPoint(x: origin.x + o, y: origin.y)); grid.addLine(to: CGPoint(x: origin.x + o, y: origin.y + side))
                grid.move(to: CGPoint(x: origin.x, y: origin.y + o)); grid.addLine(to: CGPoint(x: origin.x + side, y: origin.y + o))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
            for (id, hull) in hulls where hull.count >= 3 {
                var path = SwiftUI.Path()
                path.addLines(hull.map { screen($0, id) })
                path.closeSubpath()
                let isSelected = id == selected
                context.fill(path, with: .color(Color(hex: colors[id] ?? "#888888").opacity(isSelected ? 0.9 : 0.45)))
                if overlapping.contains(id) { context.stroke(path, with: .color(.red), lineWidth: 2) }
                else if isSelected { context.stroke(path, with: .color(.accentColor), lineWidth: 2.5) }
            }
        }
        return canvas
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Touch down: pick the object under the finger, then drag it.
                        if abs(value.translation.width) < 2, abs(value.translation.height) < 2,
                           let hit = hitObject(at: value.startLocation, hulls: hulls, origin: origin, side: side, scale: scale) {
                            selectedID = hit
                        }
                        drag = value.translation
                    }
                    .onEnded { value in
                        let dx = Double(value.translation.width / scale), dy = Double(-value.translation.height / scale)
                        drag = .zero
                        if abs(dx) > 0.2 || abs(dy) > 0.2 { project.move(selectedID, dx: dx, dy: dy) }
                    }
            )
            .accessibilityIdentifier("bedMap")
    }

    /// The object whose outline contains `point` (screen coordinates of the map without any drag offset).
    private func hitObject(at point: CGPoint, hulls: [(ModelObject.ID, [(x: Double, y: Double)])],
                           origin: CGPoint, side: CGFloat, scale: CGFloat) -> ModelObject.ID? {
        for (id, hull) in hulls.reversed() where hull.count >= 3 {
            let pts = hull.map { CGPoint(x: origin.x + CGFloat($0.x) * scale, y: origin.y + side - CGFloat($0.y) * scale) }
            var inside = false
            var j = pts.count - 1
            for i in pts.indices {
                let a = pts[i], b = pts[j]
                if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
                j = i
            }
            if inside { return id }
        }
        return nil
    }

    // MARK: Sections

    private func positionSection(_ o: ModelObject) -> some View {
        let c = o.boundingBox.center
        return Section("Position") {
            HStack {
                Text(String(format: "X %.1f  ·  Y %.1f mm", c.x, c.y)).monospacedDigit()
                Spacer()
                Picker("Schritt", selection: $step) {
                    Text("1 mm").tag(1.0); Text("10 mm").tag(10.0)
                }
                .pickerStyle(.segmented).frame(width: 130)
            }
            HStack(spacing: 14) {
                Spacer()
                nudge("arrow.left", dx: -step, dy: 0)
                VStack(spacing: 6) {
                    nudge("arrow.up", dx: 0, dy: step)
                    nudge("arrow.down", dx: 0, dy: -step)
                }
                nudge("arrow.right", dx: step, dy: 0)
                Spacer()
            }
            Button { project.place(selectedID, centerX: bed / 2, centerY: bed / 2) } label: {
                Label("In die Bettmitte", systemImage: "scope")
            }
        }
    }

    private func nudge(_ symbol: String, dx: Double, dy: Double) -> some View {
        Button { project.move(selectedID, dx: dx, dy: dy) } label: {
            Image(systemName: symbol).font(.title3).frame(width: 44, height: 36)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Verschieben \(symbol)")
    }

    private var rotationSection: some View {
        Section {
            HStack {
                ForEach([-90.0, -15, -5, 5, 15, 90], id: \.self) { d in
                    Button(d > 0 ? "+\(Int(d))°" : "\(Int(d))°") { project.rotate(selectedID, degrees: d) }
                        .buttonStyle(.bordered).font(.caption.monospacedDigit())
                        .frame(maxWidth: .infinity)
                }
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    tiltButton("Nach vorn kippen", "arrow.down.forward", aroundX: true, degrees: 90)
                    tiltButton("Nach hinten kippen", "arrow.up.backward", aroundX: true, degrees: -90)
                }
                GridRow {
                    tiltButton("Nach links kippen", "arrow.uturn.left", aroundX: false, degrees: -90)
                    tiltButton("Nach rechts kippen", "arrow.uturn.right", aroundX: false, degrees: 90)
                }
                GridRow {
                    tiltButton("Umdrehen", "arrow.up.arrow.down", aroundX: true, degrees: 180)
                        .gridCellColumns(2)
                }
            }
        } header: {
            Text("Drehen und kippen")
        } footer: {
            Text("Oben: Drehen auf dem Bett. Kippen legt das Teil auf eine andere Seite; es bleibt an seinem Platz.")
        }
    }

    private func tiltButton(_ title: String, _ symbol: String, aroundX: Bool, degrees: Double) -> some View {
        Button { project.tilt(selectedID, aroundX: aroundX, degrees: degrees) } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).font(.caption)
    }

    private var faceSection: some View {
        Section {
            if loadingFaces {
                HStack { ProgressView(); Text("Flächen werden gesucht …").font(.caption) }
            } else if faces.isEmpty {
                Text("Keine ebene Fläche gefunden – das Teil ist rund oder organisch geformt.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(faces) { face in
                Button { project.lay(selectedID, on: face) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Fläche \(face.id + 1)" + (face.id == 0 ? " – empfohlen" : "")).font(.subheadline.weight(face.id == 0 ? .semibold : .regular))
                            Text(String(format: "%.0f mm² auf dem Bett · %.0f mm hoch · %@", face.contactArea, face.height,
                                        face.overhangArea < 50 ? "kaum Stützen" : String(format: "%.0f cm² Überhang", face.overhangArea / 100)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.down.to.line")
                    }
                }
                .accessibilityIdentifier("lyingFace-\(face.id)")
            }
        } header: {
            Text("Hinlegen auf")
        } footer: {
            Text("Empfohlen: viel Kontakt zum Bett und wenig Überhang. Für Festigkeit: so legen, dass die Last entlang der Schichten läuft.")
        }
    }

    private func sizeSection(_ o: ModelObject) -> some View {
        let s = o.boundingBox.size
        return Section("Größe") {
            Text(String(format: "%.1f × %.1f × %.1f mm", s.x, s.y, s.z)).monospacedDigit()
            HStack {
                ForEach([0.5, 0.9, 1.1, 2.0], id: \.self) { f in
                    Button("\(Int(f * 100)) %") { project.scale(selectedID, factor: f) }
                        .buttonStyle(.bordered).frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func loadFaces() async {
        guard let o = object else { faces = []; return }
        loadingFaces = true
        let mesh = o.mesh, angle = project.settings.supportAngle
        faces = await Task.detached(priority: .userInitiated) { mesh.lyingFaces(limit: 5, supportAngle: angle) }.value
        loadingFaces = false
    }
}
