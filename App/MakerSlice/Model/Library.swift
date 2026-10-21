import Foundation
import Observation

/// A model file stored in the app's library.
struct LibraryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var fileName: String
    var added = Date()
    var source: Source = .file
    /// MakerWorld design id, if it came from there.
    var makerWorldID: Int?
    var coverURL: URL?

    enum Source: String, Codable {
        case file, makerWorld, printables
    }
}

/// Persists imported model files under Documents/Library.
@MainActor
@Observable
final class Library {
    private(set) var items: [LibraryItem] = []

    private let folder: URL
    private var indexURL: URL { folder.appendingPathComponent("library.json") }

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = docs.appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    func url(for item: LibraryItem) -> URL {
        folder.appendingPathComponent(item.fileName)
    }

    /// Copies a file into the library. Security-scoped URLs (Files app) are handled.
    @discardableResult
    func importFile(at source: URL, name: String? = nil, origin: LibraryItem.Source = .file,
                    makerWorldID: Int? = nil, coverURL: URL? = nil) throws -> LibraryItem {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        return try add(data: data, fileName: source.lastPathComponent, name: name, origin: origin,
                       makerWorldID: makerWorldID, coverURL: coverURL)
    }

    @discardableResult
    func add(data: Data, fileName: String, name: String? = nil, origin: LibraryItem.Source = .file,
             makerWorldID: Int? = nil, coverURL: URL? = nil) throws -> LibraryItem {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let stored = "\(UUID().uuidString).\(ext.isEmpty ? "3mf" : ext)"
        try data.write(to: folder.appendingPathComponent(stored), options: .atomic)
        let displayName = name ?? (fileName as NSString).deletingPathExtension
        let item = LibraryItem(name: displayName, fileName: stored, source: origin,
                               makerWorldID: makerWorldID, coverURL: coverURL)
        items.insert(item, at: 0)
        save()
        return item
    }

    func delete(_ item: LibraryItem) {
        try? FileManager.default.removeItem(at: url(for: item))
        items.removeAll { $0.id == item.id }
        save()
    }

    func rename(_ item: LibraryItem, to name: String) {
        guard let idx = items.firstIndex(of: item) else { return }
        items[idx].name = name
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([LibraryItem].self, from: data) else { return }
        items = decoded.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
