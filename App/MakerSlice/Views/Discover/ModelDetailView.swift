import MakerWorldKit
import SwiftUI

/// Details of a search result: files (Printables) or print profiles (MakerWorld).
struct ModelDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let result: ModelSearchResult

    @State private var files: [ModelFile] = []
    @State private var design: MakerWorldDesign?
    @State private var loading = true
    @State private var downloading: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AsyncImage(url: result.imageURL) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Color(.tertiarySystemFill).frame(height: 200)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title).font(.title3.weight(.semibold))
                        HStack {
                            if let author = result.author { Text("von \(author)") }
                            Spacer()
                            StatusBadge(text: "Kostenlos", color: .green)
                        }
                        .font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                if loading {
                    Section { HStack { ProgressView(); Text("Lade Details …").foregroundStyle(.secondary) } }
                } else if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        if let url = result.pageURL { Link("Im Browser öffnen", destination: url) }
                    }
                }

                if result.source == .printables, !files.isEmpty {
                    Section("Dateien") {
                        ForEach(files) { file in
                            Button { download(file) } label: {
                                HStack {
                                    Image(systemName: "doc").foregroundStyle(.secondary)
                                    VStack(alignment: .leading) {
                                        Text(file.name).lineLimit(2)
                                        if let size = file.size {
                                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if downloading == file.id { ProgressView() } else {
                                        Text("Drucken").font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .disabled(downloading != nil)
                        }
                    }
                }

                if let design {
                    Section("Druckprofile") {
                        ForEach(design.profiles) { profile in
                            Button { download(profile, of: design) } label: {
                                ProfileRow(profile: profile, fallbackCover: design.coverURL, busy: downloading == String(profile.id))
                            }
                            .disabled(downloading != nil)
                        }
                    }
                }
            }
            .navigationTitle(result.source.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } }
                if let url = result.pageURL {
                    ToolbarItem(placement: .topBarTrailing) { ShareLink(item: url) }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            switch result.source {
            case .printables:
                files = try await PrintablesClient().files(modelID: result.modelID)
                if files.isEmpty { error = "Keine druckbaren Dateien (STL/3MF/OBJ) gefunden." }
            case .makerWorld:
                guard let id = Int(result.modelID) else { return }
                design = try await app.browser.loadDesign(id: id)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func download(_ file: ModelFile) {
        downloading = file.id
        Task {
            defer { downloading = nil }
            do {
                let data = try await PrintablesClient().download(file, modelID: result.modelID)
                dismiss()
                app.addDownloaded(data: data, fileName: file.name, title: result.title, source: .printables,
                                  sourceID: result.modelID, coverURL: result.imageURL)
            } catch {
                self.error = "Download fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }

    private func download(_ profile: MakerWorldProfile, of design: MakerWorldDesign) {
        downloading = String(profile.id)
        Task {
            defer { downloading = nil }
            do {
                let (data, name) = try await app.browser.download(profile: profile, of: design)
                dismiss()
                app.addDownloaded(data: data, fileName: name, title: "\(design.title) – \(profile.title)", source: .makerWorld,
                                  sourceID: String(design.id), coverURL: design.coverURL)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ProfileRow: View {
    let profile: MakerWorldProfile
    let fallbackCover: URL?
    var busy = false

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: profile.coverURL ?? fallbackCover) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color(.tertiarySystemFill)
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(profile.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    if profile.isDefault { StatusBadge(text: "Standard", color: .blue) }
                }
                HStack(spacing: 10) {
                    if let t = profile.printTimeSeconds { Label(Format.duration(Double(t)), systemImage: "clock") }
                    if let plates = profile.plateCount, plates > 1 { Label("\(plates) Platten", systemImage: "square.grid.2x2") }
                    if let w = profile.weightGrams { Label("\(Int(w)) g", systemImage: "scalemass") }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let printer = profile.printerName {
                    Text("Erstellt für \(printer) – wird an deinen Drucker angepasst").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if busy { ProgressView() } else { Image(systemName: "arrow.down.circle").foregroundStyle(Color.accentColor) }
        }
    }
}

/// Profile picker shown from the MakerWorld browser.
struct MakerWorldProfilesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let design: MakerWorldDesign
    let onDone: () -> Void
    @State private var busy: Int?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                ForEach(design.profiles) { profile in
                    Button {
                        busy = profile.id
                        Task {
                            defer { busy = nil }
                            do {
                                let (data, name) = try await app.browser.download(profile: profile, of: design)
                                dismiss()
                                onDone()
                                app.addDownloaded(data: data, fileName: name, title: "\(design.title) – \(profile.title)",
                                                  source: .makerWorld, sourceID: String(design.id), coverURL: design.coverURL)
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    } label: {
                        ProfileRow(profile: profile, fallbackCover: design.coverURL, busy: busy == profile.id)
                    }
                    .disabled(busy != nil)
                }
            }
            .navigationTitle(design.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
