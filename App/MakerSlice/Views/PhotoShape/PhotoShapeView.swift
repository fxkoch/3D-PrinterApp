import PhotosUI
import SliceKit
import SwiftUI
import UIKit

/// Photo → printable shape in seconds: outline of an object as key ring / template / stamp, or the brightness as relief.
/// A fast, practical alternative to the 3D scan (which needs minutes and a LiDAR iPhone).
struct PhotoShapeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    private enum Kind: String, CaseIterable, Identifiable {
        case silhouette = "Umriss", relief = "Relief (Hell/Dunkel)"
        var id: String { rawValue }
    }
    private enum Polarity: String, CaseIterable, Identifiable {
        case auto = "Automatisch", dark = "Objekt dunkel", bright = "Objekt hell"
        var id: String { rawValue }
    }

    @State private var picked: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var gray: GrayImage?
    @State private var kind: Kind = .silhouette
    @State private var polarity: Polarity = .auto
    @State private var size = 60.0
    @State private var thickness = 3.0
    @State private var depth = 2.0
    @State private var darkIsHigh = false
    @State private var smoothing = 2.0
    @State private var keyRing = false
    @State private var hole = 4.0
    @State private var name = "Foto-Form"
    @State private var mesh: TriangleMesh?
    @State private var message: String?
    @State private var working = false
    @State private var showCamera = false
    @State private var buildTask: Task<Void, Never>?

    private var options: PhotoShape.Options {
        var o = PhotoShape.Options()
        o.size = size
        o.thickness = thickness
        o.smoothing = smoothing
        o.keyRingHole = keyRing && kind == .silhouette
        o.holeDiameter = hole
        o.subjectIsBright = polarity == .auto ? nil : polarity == .bright
        o.mode = kind == .silhouette ? .silhouette : .relief(depth: depth, darkIsHigh: darkIsHigh)
        return o
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    if photo == nil { startPanel } else { previewPanel; settingsPanel; savePanel }
                    if let message { Text(message).font(.footnote).foregroundStyle(.orange).padding(.horizontal) }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Foto → Form")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label("Zurück", systemImage: "chevron.left") } }
            }
            .onChange(of: picked) { _, item in
                guard let item else { return }
                Task { if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { await load(image) } }
            }
            .onChange(of: kind) { _, _ in rebuild() }
            .onChange(of: polarity) { _, _ in rebuild() }
            .onChange(of: size) { _, _ in rebuild() }
            .onChange(of: thickness) { _, _ in rebuild() }
            .onChange(of: depth) { _, _ in rebuild() }
            .onChange(of: darkIsHigh) { _, _ in rebuild() }
            .onChange(of: smoothing) { _, _ in rebuild() }
            .onChange(of: keyRing) { _, _ in rebuild() }
            .onChange(of: hole) { _, _ in rebuild() }
            .sheet(isPresented: $showCamera) { CameraPicker { image in showCamera = false; if let image { Task { await load(image) } } } }
            .task {
                if ProcessInfo.processInfo.arguments.contains("-uiTestPhotoShape") { await load(PhotoPrep.syntheticPhoto()) }
            }
        }
    }

    private var startPanel: some View {
        VStack(spacing: Theme.spacing) {
            Panel(title: "So geht's", systemImage: "photo") {
                Text("Fotografiere ein Objekt oder eine Zeichnung von oben auf einem einfarbigen, hellen oder dunklen Untergrund. Die App macht daraus in Sekunden ein druckbares Teil: den Umriss als Schlüsselanhänger, Schablone oder Stempel – oder das Foto als Relief.")
                    .font(.subheadline)
                Text("Für ein echtes 3D-Modell eines Gegenstands bleibt der 3D-Scan (dauert Minuten, braucht ein iPhone mit LiDAR).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            PhotosPicker(selection: $picked, matching: .images) {
                Label("Foto aus der Mediathek", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("photoShapePick")
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Label("Foto aufnehmen", systemImage: "camera").frame(maxWidth: .infinity).padding(.vertical, 6) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var previewPanel: some View {
        Panel(title: "Vorschau", systemImage: "cube") {
            HStack(alignment: .top, spacing: 12) {
                if let photo {
                    Image(uiImage: photo).resizable().scaledToFit().frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let mesh {
                        let s = mesh.boundingBox.size
                        Text(String(format: "%.0f × %.0f × %.1f mm", s.x, s.y, s.z)).font(.headline)
                        Text(String(format: "%.1f g PLA etwa", mesh.volume / 1000 * 1.24)).font(.footnote).foregroundStyle(.secondary)
                    } else if working {
                        ProgressView("Rechnet …")
                    }
                }
                Spacer()
            }
            if let mesh {
                ModelSceneView(objects: [ModelObject(name: name, mesh: mesh).placedOnBed(center: (125, 125))], filaments: [], bedSize: 250)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("photoShapePreview")
            }
            Button { photo = nil; gray = nil; mesh = nil; picked = nil } label: { Label("Anderes Foto", systemImage: "arrow.counterclockwise") }
                .font(.footnote)
        }
    }

    private var settingsPanel: some View {
        Panel(title: "Einstellungen", systemImage: "slider.horizontal.3") {
            Picker("Art", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            slider("Größe (längste Seite)", $size, 20...200, step: 5, unit: "mm")
            slider(kind == .silhouette ? "Dicke" : "Grunddicke", $thickness, 1...10, step: 0.5, unit: "mm")
            if kind == .relief {
                slider("Relieftiefe", $depth, 0.5...6, step: 0.5, unit: "mm")
                Toggle("Dunkel = hoch", isOn: $darkIsHigh)
            } else {
                Picker("Objekt ist", selection: $polarity) { ForEach(Polarity.allCases) { Text($0.rawValue).tag($0) } }
                slider("Glätten", $smoothing, 0...5, step: 0.5, unit: "")
                Toggle("Loch zum Aufhängen", isOn: $keyRing)
                if keyRing { slider("Lochdurchmesser", $hole, 2...10, step: 0.5, unit: "mm") }
            }
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title): \(value.wrappedValue.formatted(.number.precision(.fractionLength(0...1)))) \(unit)").font(.subheadline)
            Slider(value: value, in: range, step: step)
        }
    }

    private var savePanel: some View {
        Panel(title: "Speichern", systemImage: "square.and.arrow.down") {
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            Button { save(open: true) } label: { Label("In Bibliothek sichern und öffnen", systemImage: "printer").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).disabled(mesh == nil)
                .accessibilityIdentifier("photoShapeSave")
            Button { save(open: false) } label: { Label("Nur in der Bibliothek sichern", systemImage: "books.vertical").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).disabled(mesh == nil)
        }
    }

    // MARK: Logic

    private func load(_ image: UIImage) async {
        photo = image
        message = nil
        gray = await PhotoPrep.prepare(image)
        rebuild()
    }

    private func rebuild() {
        guard let gray else { return }
        buildTask?.cancel()
        let options = options
        working = true
        buildTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)   // let sliders settle
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { Result { try PhotoShape.mesh(gray, options: options) } }.value
            guard !Task.isCancelled else { return }
            working = false
            switch result {
            case .success(let m): mesh = m; message = nil
            case .failure(let e): mesh = nil; message = e.localizedDescription
            }
        }
    }

    private func save(open: Bool) {
        guard let mesh else { return }
        var object = ModelObject(name: name.isEmpty ? "Foto-Form" : name, mesh: mesh)
        object = object.placedOnBed(center: (0, 0))
        do {
            let item = try app.library.add(data: ThreeMFWriter.write([object]), fileName: object.name + ".3mf", name: object.name)
            dismiss()
            if open { app.open(item) }
        } catch {
            message = "Sichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}

/// System camera.
struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(_ onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}
