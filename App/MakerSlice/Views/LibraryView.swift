import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var showImporter = false
    @State private var renaming: LibraryItem?
    @State private var newName = ""

    private static let modelTypes: [UTType] = [
        UTType(filenameExtension: "3mf") ?? .data,
        UTType(filenameExtension: "stl") ?? .data,
        UTType(filenameExtension: "obj") ?? .data,
    ]

    var body: some View {
        NavigationStack {
            Group {
                if app.library.items.isEmpty {
                    ContentUnavailableView {
                        Label("Noch keine Modelle", systemImage: "cube.transparent")
                    } description: {
                        Text("Lade Modelle in „Entdecken“ von MakerWorld oder importiere 3MF-, STL- oder OBJ-Dateien.")
                    } actions: {
                        Button("Datei importieren") { showImporter = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(app.library.items) { item in
                            Button { app.open(item) } label: { LibraryRow(item: item) }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button(role: .destructive) { app.library.delete(item) } label: {
                                        Label("Löschen", systemImage: "trash")
                                    }
                                    Button {
                                        newName = item.name
                                        renaming = item
                                    } label: {
                                        Label("Umbenennen", systemImage: "pencil")
                                    }
                                    .tint(.orange)
                                }
                        }
                    }
                }
            }
            .navigationTitle("Bibliothek")
            .toolbar {
                Button { showImporter = true } label: { Image(systemName: "plus") }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.modelTypes,
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                for url in urls {
                    do {
                        try app.library.importFile(at: url)
                    } catch {
                        app.alert = "Import fehlgeschlagen: \(error.localizedDescription)"
                    }
                }
                if urls.count == 1, let first = app.library.items.first { app.open(first) }
            }
            .alert("Umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Sichern") { if let r = renaming { app.library.rename(r, to: newName) } }
                Button("Abbrechen", role: .cancel) {}
            }
        }
    }
}

private struct LibraryRow: View {
    let item: LibraryItem

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.coverURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "cube")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.12))
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    if item.source == .makerWorld {
                        Label("MakerWorld", systemImage: "globe").labelStyle(.titleAndIcon)
                    }
                    Text(item.added, style: .date)
                    Text((item.fileName as NSString).pathExtension.uppercased())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
