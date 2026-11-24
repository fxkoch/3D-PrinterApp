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
    /// The last command the printer refused or could not carry out – shown to the user (a failed command must never be silent).
    struct ActionFailure: Identifiable, Equatable {
        let id = UUID()
        let printerID: UUID
        let title: String
        let message: String
    }
    var actionFailure: ActionFailure?

    /// How each printer was reached last (home network or its address on the way). Kept across launches, so the app
    /// (and the background check) starts with the way that worked.
    private(set) var routes: [UUID: RemoteAccess.Route] = [:] {
        didSet {
            guard routes != oldValue else { return }
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: routes.map { ($0.key.uuidString, $0.value.rawValue) }), forKey: "printerRoutes")
        }
    }

    @ObservationIgnored private var drivers: [UUID: PrinterDriver] = [:]
    @ObservationIgnored private var remoteDrivers: [UUID: PrinterDriver] = [:]
    @ObservationIgnored private var lastHomeTry: [UUID: Date] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored weak var log: EventLog?
    @ObservationIgnored private var lastEventFetch: [UUID: Date] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: "printers"),
           let saved = try? JSONDecoder().decode([PrinterConnection].self, from: data) {
            printers = saved
        }
        selectedID = UserDefaults.standard.string(forKey: "selectedPrinter").flatMap(UUID.init) ?? printers.first?.id
        if let saved = UserDefaults.standard.dictionary(forKey: "printerRoutes") as? [String: String] {
            routes = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in
                guard let id = UUID(uuidString: key), let route = RemoteAccess.Route(rawValue: value),
                      printers.contains(where: { $0.id == id && $0.remote != nil }) else { return nil }
                return (id, route)
            })
        }
    }

    /// Closes every connection (both ways to each printer).
    func disconnectAll() {
        drivers.values.forEach { $0.disconnect() }
        remoteDrivers.values.forEach { $0.disconnect() }
        drivers = [:]
        remoteDrivers = [:]
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

    /// The driver for the way the printer was reached last (home address or remote address).
    func driver(for printer: PrinterConnection) -> PrinterDriver {
        driver(for: printer, route: routes[printer.id] ?? .home)
    }

    private func driver(for printer: PrinterConnection, route: RemoteAccess.Route) -> PrinterDriver {
        let target = route == .remote ? (printer.remote ?? printer) : printer
        if route == .remote {
            if let d = remoteDrivers[printer.id], d.connection == target { return d }
            remoteDrivers[printer.id]?.disconnect()
            let d = PrinterDrivers.make(for: target)
            remoteDrivers[printer.id] = d
            return d
        }
        if let d = drivers[printer.id], d.connection == target { return d }
        drivers[printer.id]?.disconnect()
        let d = PrinterDrivers.make(for: target)
        drivers[printer.id] = d
        return d
    }

    /// True when the app reaches the printer at its remote address (away from home).
    func isRemote(_ printer: PrinterConnection) -> Bool { routes[printer.id] == .remote && isOnline(printer) }

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
        drivers.removeValue(forKey: printer.id)?.disconnect()
        remoteDrivers.removeValue(forKey: printer.id)?.disconnect()
        routes[printer.id] = nil
        statuses[printer.id] = nil
        errors[printer.id] = nil
        save()
        restartPolling()
    }

    func remove(_ printer: PrinterConnection) {
        printers.removeAll { $0.id == printer.id }
        drivers.removeValue(forKey: printer.id)?.disconnect()
        remoteDrivers.removeValue(forKey: printer.id)?.disconnect()
        routes[printer.id] = nil
        errors[printer.id] = nil
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

    /// All printers at the same time: one that does not answer must not hold up the others.
    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for printer in printers {
                group.addTask { await self.refresh(printer) }
            }
        }
    }

    /// Asks the printer for its status – at home under its home address, away from home (when it has one) under its
    /// remote address. The way that worked is kept; the home address is tried again every minute.
    func refresh(_ printer: PrinterConnection) async {
        let order = RemoteAccess.order(last: routes[printer.id], hasRemote: printer.remote != nil,
                                       sinceHomeTry: Date().timeIntervalSince(lastHomeTry[printer.id] ?? .distantPast))
        var lastError: Error?
        for (i, route) in order.enumerated() {
            if route == .home, routes[printer.id] == .remote {
                // Back home? A quick knock first, so a missing home network does not cost a full timeout every minute.
                lastHomeTry[printer.id] = Date()
                guard await RemoteAccess.answers(printer, timeout: 1.5) else { continue }
            }
            let driver = driver(for: printer, route: route)
            do {
                let new = try await driver.status()
                if routes[printer.id] != route, routes[printer.id] != nil || route == .remote {
                    log?.add(.info, route == .remote ? "Verbunden über die Adresse unterwegs (\(printer.remoteAddress ?? ""))"
                                                     : "Wieder im Heimnetz verbunden", source: printer.name)
                }
                routes[printer.id] = route
                // The way that did not work is closed (a live MQTT connection would keep retrying it).
                if i > 0 {
                    if route == .home { remoteDrivers.removeValue(forKey: printer.id)?.disconnect() }
                    else { drivers.removeValue(forKey: printer.id)?.disconnect() }
                }
                await received(new, from: printer, driver: driver)
                return
            } catch {
                lastError = error
            }
        }
        if let error = lastError { failed(printer, error) }
    }

    private func failed(_ printer: PrinterConnection, _ error: Error) {
        guard printers.contains(where: { $0.id == printer.id }) else { return }
        if errors[printer.id] == nil {
            log?.add(.warning, "Nicht erreichbar: \(error.localizedDescription)", source: printer.name)
        }
        errors[printer.id] = error.localizedDescription
    }

    private func received(_ new: PrinterStatus, from printer: PrinterConnection, driver: PrinterDriver) async {
        // The printer may have been removed while the request was under way.
        guard printers.contains(where: { $0.id == printer.id }) else { return }
        let old = statuses[printer.id]
        statuses[printer.id] = new
        if errors[printer.id] != nil { log?.add(.info, "Verbindung wiederhergestellt", source: printer.name) }
        errors[printer.id] = nil
        noteChanges(printer, old: old, new: new)
        NotificationService.shared.observe(printer: printer, status: new)
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
            actionFailure = ActionFailure(printerID: printer.id, title: "\(name) fehlgeschlagen", message: error.localizedDescription)
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
        // "?" = a spool is there, its material is unknown (no RFID tag) – not the same as empty.
        return s.filaments.map { f in f.present ? (f.type.flatMap { $0.isEmpty ? nil : $0 } ?? "?") : "NONE" }
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
