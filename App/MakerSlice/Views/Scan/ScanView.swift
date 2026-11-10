import PhotosUI
import RealityKit
import SliceKit
import SwiftUI
import UniformTypeIdentifiers

/// A video file picked from the photo library.
private struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return MovieFile(url: copy)
        }
    }
}

/// 3D scan: photograph an object from all sides (or pick photos/a video) and get a printable model.
struct ScanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var model = ScanModel()
    @State private var picked: [PhotosPickerItem] = []
    @State private var longestSide = ""
    @State private var name = "Scan"

    var body: some View {
        NavigationStack {
            Group {
                switch model.stage {
                case .start: startView
                case .capturing: captureView
                case .processing(let text, let fraction): processingView(text, fraction)
                case .review: reviewView
                case .failed(let message): failedView(message)
                }
            }
            .navigationTitle("3D-Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { model.cancel(); dismiss() } } }
        }
        .interactiveDismissDisabled(model.stage == .capturing)
    }

    // MARK: Start

    private var startView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                Panel(title: "So geht's", systemImage: "camera.viewfinder") {
                    Text("Du fotografierst das Objekt von allen Seiten, das iPhone rechnet daraus ein 3D-Modell – in echter Größe, weil der LiDAR-Sensor die Maße misst. Danach wird es aufgeräumt (Löcher geschlossen) und liegt in der Bibliothek.")
                        .font(.subheadline)
                    Text("Am besten: Objekt auf einen Tisch mit gleichmäßigem Licht und unauffälligem Hintergrund stellen, matte Oberflächen. Glänzende, durchsichtige oder sehr dunkle Dinge gelingen schlecht.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Panel(title: "Geführte Aufnahme", systemImage: "viewfinder") {
                    if ScanModel.guidedCaptureSupported {
                        Button { model.startGuidedCapture() } label: { Label("Objekt scannen", systemImage: "camera").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("scanGuided")
                    } else {
                        Label("Dafür braucht es ein iPhone oder iPad mit LiDAR-Sensor (iPhone 12 Pro oder neuer, ab A14-Chip).", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                Panel(title: "Fotos oder Video aus der Mediathek", systemImage: "photo.on.rectangle") {
                    Text("Mindestens 20, besser 40–100 Fotos rund um das Objekt (mit Überlappung) oder ein langsames Video, das einmal um das Objekt herumgeht.")
                        .font(.footnote).foregroundStyle(.secondary)
                    PhotosPicker(selection: $picked, maxSelectionCount: 150, matching: .any(of: [.images, .videos])) {
                        Label("Auswählen …", systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!ScanModel.reconstructionSupported)
                    .accessibilityIdentifier("scanPick")
                    if !ScanModel.reconstructionSupported {
                        Label("Das Berechnen läuft auf dem Gerät und braucht LiDAR-Hardware. Auf diesem Gerät nicht möglich.", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task { await load(items) }
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        var images: [Data] = [], videos: [URL] = []
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                if let movie = try? await item.loadTransferable(type: MovieFile.self) { videos.append(movie.url) }
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                images.append(data)
            }
        }
        picked = []
        model.importMedia(images: images, videos: videos)
    }

    // MARK: Guided capture

    @ViewBuilder
    private var captureView: some View {
        if let session = model.session {
            ZStack(alignment: .bottom) {
                ObjectCaptureView(session: session)
                    .ignoresSafeArea(edges: .bottom)
                VStack(spacing: 10) {
                    Text(hint(for: session.state)).font(.callout.weight(.medium)).multilineTextAlignment(.center)
                        .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    HStack {
                        switch session.state {
                        case .ready:
                            Button("Objekt erkennen") { _ = session.startDetecting() }.buttonStyle(.borderedProminent)
                        case .detecting:
                            Button("Aufnahme starten") { session.startCapturing() }.buttonStyle(.borderedProminent)
                        case .capturing:
                            Button("Fertig") { model.finishGuidedCapture() }.buttonStyle(.borderedProminent)
                        default:
                            EmptyView()
                        }
                        Button("Abbrechen", role: .cancel) { model.cancel() }.buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .onChange(of: session.state) { _, state in
                switch state {
                case .completed: model.guidedSessionEnded()
                case .failed(let error): model.stage = .failed(error.localizedDescription)
                default: break
                }
            }
        }
    }

    private func hint(for state: ObjectCaptureSession.CaptureState) -> String {
        switch state {
        case .initializing, .ready: return "Richte die Kamera auf das Objekt, so dass es in der Mitte steht."
        case .detecting: return "Passe den Rahmen an das Objekt an und starte die Aufnahme."
        case .capturing: return "Gehe langsam um das Objekt herum. Danach das Objekt umdrehen und noch einmal, damit auch die Unterseite erfasst wird."
        case .finishing: return "Aufnahme wird abgeschlossen …"
        default: return ""
        }
    }

    // MARK: Processing, review, failure

    private func processingView(_ text: String, _ fraction: Double) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: fraction)
            Text(text).font(.subheadline).multilineTextAlignment(.center)
            Text("Lass die App geöffnet. Das Berechnen dauert je nach Bildzahl 2–10 Minuten.").font(.footnote).foregroundStyle(.secondary)
            Button("Abbrechen", role: .cancel) { model.cancel() }
        }
        .padding()
    }

    private var scannedObject: ModelObject? {
        guard let mesh = model.mesh else { return nil }
        return ModelObject(name: name, mesh: mesh)
    }

    private var reviewView: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let object = scannedObject {
                    ModelSceneView(objects: [object], filaments: [], bedSize: 250)
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    let size = object.boundingBox.size
                    Panel(title: "Ergebnis", systemImage: "cube") {
                        Text(String(format: "Größe: %.0f × %.0f × %.0f mm", size.x, size.y, size.z)).font(.headline)
                        if let report = model.report {
                            if report.closedHoles > 0 { Text("\(report.closedHoles) Loch/Löcher geschlossen (meist die Unterseite).").font(.footnote) }
                            if report.removedFragments > 0 { Text("\(report.removedFragments) lose Teile aus dem Hintergrund entfernt.").font(.footnote) }
                            if !report.watertight {
                                Text("Die Oberfläche ist nicht ganz geschlossen – der Slicer kann an diesen Stellen Fehler machen.").font(.footnote).foregroundStyle(.orange)
                            }
                        }
                        Text("Prüfe die Maße. Weichen sie ab, gib unten die echte längste Seite ein.").font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            TextField("Längste Seite in mm", text: $longestSide).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                            Button("Anpassen") { if let v = Double(longestSide.replacingOccurrences(of: ",", with: ".")) { model.scaleLongestSide(to: v) } }
                                .buttonStyle(.bordered)
                        }
                    }
                    Panel(title: "Sichern", systemImage: "square.and.arrow.down") {
                        TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                        Button { save(object, open: true) } label: { Label("In Bibliothek sichern und öffnen", systemImage: "printer").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("scanSave")
                        Button { save(object, open: false) } label: { Label("Nur in der Bibliothek sichern", systemImage: "books.vertical").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private func save(_ object: ModelObject, open: Bool) {
        var o = object
        o.name = name.isEmpty ? "Scan" : name
        do {
            let item = try app.library.add(data: ThreeMFWriter.write([o.placedOnBed(center: (0, 0))]), fileName: o.name + ".3mf", name: o.name)
            dismiss()
            if open { app.open(item) }
        } catch {
            app.alert = "Sichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func failedView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Scan nicht möglich", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Zurück") { model.stage = .start }.buttonStyle(.borderedProminent)
        }
    }
}
