import Foundation
import Observation
import PrinterKit
import SliceKit

/// Keeps the configured printers, their drivers and live status.
@MainActor
@Observable
final class PrinterManager {
    private(set) var printers: [PrinterConnection] = []
    var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "selectedPrinter") }
    }

    private(set) var statuses: [UUID: PrinterStatus] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var calibration: [UUID: CalibrationData] = [:]

    @ObservationIgnored private var drivers: [UUID: PrinterDriver] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored weak var log: EventLog?
    @ObservationIgnored private var lastEventFetch: [UUID: Date] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: "printers"),
           let saved = try? JSONDecoder().decode([PrinterConnection].self, from: data) {
            printers = saved
        }
        selectedID = UserDefaults.standard.string(forKey: "selectedPrinter").flatMap(UUID.init) ?? printers.first?.id
    }

    var selected: PrinterConnection? {
        printers.first { $0.id == selectedID } ?? printers.first
    }

    func model(of printer: PrinterConnection) -> PrinterModel {
        PrinterModel(rawValue: printer.model) ?? .snapmakerU1
    }

    func status(of printer: PrinterConnection?) -> PrinterStatus? {
        printer.flatMap { statuses[$0.id] }
    }

    func isOnline(_ printer: PrinterConnection) -> Bool {
        statuses[printer.id] != nil && errors[printer.id] == nil
    }

    func driver(for printer: PrinterConnection) -> PrinterDriver {
        if let d = drivers[printer.id], d.connection == printer { return d }
        drivers[printer.id]?.disconnect()
        let d = PrinterDrivers.make(for: printer)
        drivers[printer.id] = d
        return d
    }

    // MARK: - Editing

    func add(_ printer: PrinterConnection) {
        printers.append(printer)
        selectedID = printer.id
        save()
        restartPolling()
    }

    func update(_ printer: PrinterConnection) {
        guard let idx = printers.firstIndex(where: { $0.id == printer.id }) else { return }
        printers[idx] = printer
        drivers[printer.id]?.disconnect()
        drivers[printer.id] = nil
        statuses[printer.id] = nil
        save()
        restartPolling()
    }

    func remove(_ printer: PrinterConnection) {
        printers.removeAll { $0.id == printer.id }
        drivers.removeValue(forKey: printer.id)?.disconnect()
        statuses[printer.id] = nil
        if selectedID == printer.id { selectedID = printers.first?.id }
        save()
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
                guard let self else { return }
                await self.refreshAll()
                let busy = self.statuses.values.contains { $0.state == .printing }
                try? await Task.sleep(nanoseconds: UInt64((busy ? 2 : 5) * 1_000_000_000))
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

    func refreshAll() async {
        for printer in printers {
            await refresh(printer)
        }
    }

    func refresh(_ printer: PrinterConnection) async {
        let driver = driver(for: printer)
        do {
            let new = try await driver.status()
            let old = statuses[printer.id]
            statuses[printer.id] = new
            if errors[printer.id] != nil { log?.add(.info, "Verbindung wiederhergestellt", source: printer.name) }
            errors[printer.id] = nil
            noteChanges(printer, old: old, new: new)
            // Printer-side messages (console / reports) every 30 s.
            if Date().timeIntervalSince(lastEventFetch[printer.id] ?? .distantPast) > 30 {
                lastEventFetch[printer.id] = Date()
                if let events = try? await driver.recentEvents() {
                    log?.merge(events.map { (event: PrinterEvent) -> PrinterEvent in
                        var e = event
                        e.source = "\(printer.name) · \(event.source)"
                        return e
                    })
                }
            }
        } catch {
            if errors[printer.id] == nil {
                log?.add(.warning, "Nicht erreichbar: \(error.localizedDescription)", source: printer.name)
            }
            errors[printer.id] = error.localizedDescription
        }
    }

    private func noteChanges(_ printer: PrinterConnection, old: PrinterStatus?, new: PrinterStatus) {
        guard let old, old.state != new.state else { return }
        switch new.state {
        case .error:
            log?.add(.error, "Druckfehler" + (new.stateMessage.map { ": \($0)" } ?? ""), source: printer.name)
        case .complete:
            log?.add(.info, "Druck fertig: \(new.fileName ?? "")", source: printer.name)
        case .cancelled:
            log?.add(.warning, "Druck abgebrochen", source: printer.name)
        case .paused:
            log?.add(.warning, "Druck pausiert" + (new.stateMessage.map { ": \($0)" } ?? ""), source: printer.name)
        case .printing:
            log?.add(.info, "Druck läuft: \(new.fileName ?? "")", source: printer.name)
        default:
            break
        }
    }

    /// Runs a printer command and refreshes the status afterwards.
    func perform(on printer: PrinterConnection, _ name: String, _ action: @escaping (PrinterDriver) async throws -> Void) async {
        do {
            try await action(driver(for: printer))
            log?.add(.info, name, source: printer.name)
        } catch {
            log?.add(.error, "\(name) fehlgeschlagen: \(error.localizedDescription)", source: printer.name)
            errors[printer.id] = error.localizedDescription
        }
        await refresh(printer)
    }

    func loadCalibration(_ printer: PrinterConnection) async {
        do {
            calibration[printer.id] = try await driver(for: printer).calibration()
        } catch {
            log?.add(.warning, "Kalibrierdaten nicht lesbar: \(error.localizedDescription)", source: printer.name)
        }
    }

    /// Material types loaded per slot (for the advisor), nil when unknown.
    func loadedTypes(_ printer: PrinterConnection?) -> [String?] {
        guard let s = status(of: printer), !s.filaments.isEmpty else { return [] }
        return s.filaments.map { $0.present ? ($0.type ?? "") : "NONE" }
    }

    /// Filament profiles matching what is loaded in the printer (RFID / ACE), per slot.
    func suggestedFilaments(for printer: PrinterConnection?, current: [Filament], model: PrinterModel) -> [Filament] {
        guard let loaded = status(of: printer)?.filaments, !loaded.isEmpty else { return current }
        var result = current
        for (i, f) in loaded.prefix(result.count).enumerated() where f.present {
            if let type = f.type, var match = FilamentLibrary.bestMatch(type: type, vendor: f.vendor, printer: model) {
                match.color = f.color ?? result[i].color
                result[i] = match
            } else if let color = f.color {
                result[i].color = color
            }
        }
        return result
    }
}
