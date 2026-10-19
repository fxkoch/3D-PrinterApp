import Foundation
import Observation
import PrinterKit
import SliceKit

enum AppTab: Hashable {
    case discover, library, printer
}

@MainActor
@Observable
final class AppModel {
    let library = Library()
    let printers = PrinterManager()
    /// Kept for the app's lifetime so the MakerWorld page and login survive tab switches.
    let browser = MakerWorldBrowser()

    var tab: AppTab = .discover
    /// Project shown in the "prepare & slice" sheet.
    var project: PrintProject?
    var isLoadingModel = false
    var alert: String?

    enum SendState: Equatable {
        case idle, uploading, done, failed(String)
    }

    var sendState: SendState = .idle

    /// Settings the user last used; new projects start from these.
    var defaultSettings: PrintSettings {
        didSet {
            if let data = try? JSONEncoder().encode(defaultSettings) {
                UserDefaults.standard.set(data, forKey: "defaultSettings")
            }
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "defaultSettings"),
           let saved = try? JSONDecoder().decode(PrintSettings.self, from: data) {
            defaultSettings = saved
        } else {
            defaultSettings = PrintSettings()
        }
    }

    // MARK: - Opening models

    func open(_ item: LibraryItem) {
        let url = library.url(for: item)
        load(name: item.name) {
            let data = try Data(contentsOf: url)
            return try ModelImporter.load(data: data, fileName: item.fileName)
        }
    }

    /// Handles files opened from other apps (Files, AirDrop, "Öffnen in …").
    func handleIncoming(_ url: URL) {
        do {
            let item = try library.importFile(at: url)
            tab = .library
            open(item)
        } catch {
            alert = "Datei konnte nicht geöffnet werden: \(error.localizedDescription)"
        }
    }

    func addDownloaded(data: Data, fileName: String, title: String?, makerWorldID: Int?, coverURL: URL?) {
        do {
            let item = try library.add(data: data, fileName: fileName, name: title,
                                       origin: makerWorldID == nil ? .file : .makerWorld,
                                       makerWorldID: makerWorldID, coverURL: coverURL)
            open(item)
        } catch {
            alert = "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func load(name: String, _ work: @escaping @Sendable () throws -> ImportedModel) {
        isLoadingModel = true
        var settings = defaultSettings
        settings.filaments = printers.suggestedFilaments(current: settings.filaments)
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
            isLoadingModel = false
            switch result {
            case .success(let model):
                project = PrintProject(name: name, imported: model, settings: settings)
            case .failure(let error):
                alert = error.localizedDescription
            }
        }
    }

    // MARK: - Printing

    func send(_ project: PrintProject, startPrint: Bool = true) async {
        guard let output = project.output else { return }
        guard let client = printers.client else {
            sendState = .failed("Kein Drucker eingerichtet. Füge im Tab „Drucker“ deinen U1 hinzu.")
            return
        }
        sendState = .uploading
        do {
            let data = Data(output.gcode.utf8)
            try await client.upload(gcode: data, fileName: project.gcodeFileName, startPrint: startPrint)
            sendState = .done
            // Remember choices for the next model.
            defaultSettings = project.settings
            await printers.refresh()
        } catch {
            sendState = .failed(error.localizedDescription)
        }
    }
}
