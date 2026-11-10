import SliceKit
import SwiftUI

/// Strength check and optimisation of a library model on its own – no slicer, no printer, no print project.
/// What you find out here goes to the print only when you hand it over.
struct WorkbenchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    let item: LibraryItem

    @State private var model: ImportedModel?
    @State private var chosen = 0
    @State private var failure: String?

    var body: some View {
        Group {
            if let model, model.objects.indices.contains(chosen) {
                VStack(spacing: 0) {
                    if model.objects.count > 1 {
                        Picker("Teil", selection: $chosen) {
                            ForEach(Array(model.objects.enumerated()), id: \.offset) { Text($1.name).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .padding(.horizontal)
                    }
                    StrengthView(ctx: StrengthContext(standalone: model.objects[chosen], settings: startSettings), onHandOver: { dismiss() })
                        .id(chosen)
                }
            } else if let failure {
                ContentUnavailableView("Modell nicht lesbar", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                ProgressView("Modell wird geladen …")
            }
        }
        .task {
            let url = app.library.url(for: item), name = item.fileName
            do {
                model = try await Task.detached(priority: .userInitiated) { try ModelImporter.load(data: Data(contentsOf: url), fileName: name) }.value
            } catch { failure = error.localizedDescription }
        }
    }

    private var startSettings: PrintSettings {
        var s = app.settings(for: app.printers.selected.map { app.printers.model(of: $0) } ?? .snapmakerU1)
        if let hints = item.hints { s.wallLoops = hints.wallLoops; s.infillDensity = hints.infillDensity }
        return s
    }
}
