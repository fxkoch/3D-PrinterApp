import Foundation
import Observation
import PrinterKit
import SliceKit

/// Keeps the list of printers and polls the selected one.
@MainActor
@Observable
final class PrinterManager {
    private(set) var printers: [PrinterConnection] = []
    var selectedID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedID?.uuidString, forKey: "selectedPrinter")
            status = nil
            lastError = nil
        }
    }

    private(set) var status: PrinterStatus?
    private(set) var lastError: String?
    private(set) var isOnline = false

    private var pollTask: Task<Void, Never>?

    var selected: PrinterConnection? {
        printers.first { $0.id == selectedID } ?? printers.first
    }

    var client: MoonrakerClient? {
        selected.map { MoonrakerClient(connection: $0) }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "printers"),
           let saved = try? JSONDecoder().decode([PrinterConnection].self, from: data) {
            printers = saved
        }
        selectedID = UserDefaults.standard.string(forKey: "selectedPrinter").flatMap(UUID.init) ?? printers.first?.id
    }

    func add(_ printer: PrinterConnection) {
        printers.append(printer)
        selectedID = printer.id
        save()
        restartPolling()
    }

    func update(_ printer: PrinterConnection) {
        guard let idx = printers.firstIndex(where: { $0.id == printer.id }) else { return }
        printers[idx] = printer
        save()
        restartPolling()
    }

    func remove(_ printer: PrinterConnection) {
        printers.removeAll { $0.id == printer.id }
        if selectedID == printer.id { selectedID = printers.first?.id }
        save()
        restartPolling()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(printers) {
            UserDefaults.standard.set(data, forKey: "printers")
        }
    }

    // MARK: - Polling

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let printing = self?.status?.state == .printing
                try? await Task.sleep(for: .seconds(printing ? 2 : 5))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func restartPolling() {
        stopPolling()
        startPolling()
    }

    func refresh() async {
        guard let client else {
            status = nil
            isOnline = false
            return
        }
        do {
            status = try await client.status()
            isOnline = true
            lastError = nil
        } catch {
            isOnline = false
            lastError = error.localizedDescription
        }
    }

    /// Runs a printer command and refreshes the status afterwards.
    func perform(_ action: @escaping (MoonrakerClient) async throws -> Void) async {
        guard let client else { return }
        do {
            try await action(client)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    /// Filament presets matching what is loaded in the printer (RFID), per tool head.
    func suggestedFilaments(current: [Filament]) -> [Filament] {
        guard let loaded = status?.filaments, !loaded.isEmpty else { return current }
        var result = current
        for (i, f) in loaded.prefix(4).enumerated() where f.present {
            var preset = result[i]
            if let type = f.type, type != "NONE",
               let match = Filament.presets.first(where: { $0.type.caseInsensitiveCompare(type) == .orderedSame })
                ?? Filament.presets.first(where: { type.uppercased().hasPrefix($0.type) }) {
                preset = match
            }
            if let color = f.color { preset.color = color }
            result[i] = preset
        }
        return result
    }
}
