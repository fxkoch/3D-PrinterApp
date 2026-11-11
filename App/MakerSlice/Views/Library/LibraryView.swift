import SwiftUI
import SliceKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var showImporter = false
    @State private var renaming: LibraryItem?
    @State private var newName = ""
    @State private var filter = ""
    @State private var workshopItem: LibraryItem?
    @State private var showScan = false
    @State private var showPhotoShape = false

    private static let modelTypes: [UTType] = [
        UTType(filenameExtension: "3mf") ?? .data,
        UTType(filenameExtension: "stl") ?? .data,
        UTType(filenameExtension: "obj") ?? .data,
    ]

    private var items: [LibraryItem] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? app.library.items : app.library.items.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if app.library.items.isEmpty {
                    ContentUnavailableView {
                        Label("Noch keine Modelle", systemImage: "cube.transparent")
                    } description: {
                        Text("Suche unter „Entdecken“ kostenlose Modelle oder importiere 3MF-, STL- oder OBJ-Dateien.")
                    } actions: {
                        Button("Datei importieren") { showImporter = true }.buttonStyle(.borderedProminent)
                        Button("Testwürfel öffnen") { app.loadSample() }.accessibilityIdentifier("openSample")
                    }
                } else {
                    List {
                        ForEach(items) { item in
                            Button { app.open(item) } label: { LibraryRow(item: item) }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .leading) {
                                    Button { workshopItem = item } label: { Label("Prüfen", systemImage: "checkmark.shield") }
                                        .tint(.indigo)
                                }
                                .contextMenu {
                                    Button { workshopItem = item } label: { Label("Festigkeit prüfen und optimieren", systemImage: "checkmark.shield") }
                                    Button { app.open(item) } label: { Label("Zum Drucken öffnen", systemImage: "printer") }
                                }
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
                                    .tint(.gray)
                                }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $filter, prompt: "Bibliothek durchsuchen")
                }
            }
            .navigationTitle("Bibliothek")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showImporter = true } label: { Label("Datei importieren", systemImage: "doc.badge.plus") }
                        Button { showPhotoShape = true } label: { Label("Foto → Form (Sekunden)", systemImage: "photo.badge.plus") }
                            .accessibilityIdentifier("libraryPhotoShape")
                        Button { showScan = true } label: { Label("3D-Scan (genau, dauert Minuten)", systemImage: "camera.viewfinder") }
                            .accessibilityIdentifier("libraryScan")
                        Button { app.loadSample() } label: { Label("Testwürfel", systemImage: "cube") }
                        Menu {
                            ForEach(ModelTemplates.all) { template in
                                Button { app.open(template: template) } label: { Text(template.name); Text(template.note) }
                            }
                        } label: {
                            Label("Vorlagen", systemImage: "square.stack.3d.up")
                        }
                        .accessibilityIdentifier("libraryTemplates")
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("libraryAdd")
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.modelTypes, allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                var imported: [LibraryItem] = []
                for url in urls {
                    do {
                        imported.append(try app.library.importFile(at: url))
                    } catch {
                        app.alert = "Import fehlgeschlagen: \(error.localizedDescription)"
                    }
                }
                if imported.count == 1 { app.open(imported[0]) }
            }
            .sheet(item: $workshopItem) { WorkbenchView(item: $0) }
            .sheet(isPresented: $showScan) { ScanView() }
            .sheet(isPresented: $showPhotoShape) { PhotoShapeView() }
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
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.tertiarySystemFill))
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.source.displayName)
                    Text("·")
                    Text(item.added, style: .date)
                    Text("·")
                    Text((item.fileName as NSString).pathExtension.uppercased())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
