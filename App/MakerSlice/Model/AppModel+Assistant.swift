import Foundation
import PrintAssistant
import PrinterKit
import SliceKit

/// Gives the Claude assistant live access to the app. Everything it reads is the current
/// state; everything it changes goes through the same functions the UI uses.
extension AppModel: AssistantHost {
    var assistantPrinters: [AssistantPrinter] {
        let selectedID = printers.selected?.id
        return printers.printers.map { p in
            AssistantPrinter(name: p.name, model: printers.model(of: p), host: p.host, isSelected: p.id == selectedID,
                             status: printers.statuses[p.id], error: printers.errors[p.id])
        }
    }

    var assistantProject: AssistantProject? {
        guard let p = project else { return nil }
        let objects = p.objects.enumerated().map { i, o in
            let box = o.boundingBox
            return AssistantObject(index: i + 1, name: o.name,
                                   size: Vec3(box.max.x - box.min.x, box.max.y - box.min.y, box.max.z - box.min.z),
                                   slot: o.tool + 1)
        }
        let slice: AssistantSliceState
        switch p.state {
        case .idle: slice = .idle
        case .slicing(let phase, let fraction): slice = .slicing(phase: phase, fraction: fraction)
        case .done(let output): slice = .done(output.estimate, engine: output.engine)
        case .failed(let message): slice = .failed(message)
        }
        return AssistantProject(name: p.name, objects: objects, settings: p.settings,
                                recommendations: p.recommendations.filter { !p.dismissed.contains($0.id) },
                                slice: slice, warning: p.warning)
    }

    var assistantLibrary: [AssistantLibraryItem] {
        library.items.map { AssistantLibraryItem(name: $0.name, source: $0.source.displayName, added: $0.added) }
    }

    var cloudSlicingAvailable: Bool { cloud.isComplete }

    func assistantEvents(limit: Int) -> [PrinterEvent] {
        Array(log.entries.prefix(limit))
    }

    // MARK: - Changes

    private func openProject() throws -> PrintProject {
        guard let p = project else { throw AssistantError("Es ist kein Projekt geöffnet.") }
        return p
    }

    func assistantSetSettings(_ settings: PrintSettings) throws {
        let p = try openProject()
        p.settings = settings
        log.add(.info, "Claude hat Einstellungen geändert", source: "Claude")
    }

    func assistantEdit(object index: Int, _ edit: ObjectEdit) throws {
        let p = try openProject()
        guard p.objects.indices.contains(index - 1) else { throw AssistantError("Objekt \(index) gibt es nicht.") }
        let id = p.objects[index - 1].id
        switch edit {
        case .rotate(let degrees): p.rotate(id, degrees: degrees)
        case .scale(let factor): p.scale(id, factor: factor)
        case .layFlat: p.layFlat(id)
        case .duplicate: p.duplicate(id)
        case .remove: p.remove(id)
        case .setSlot(let slot): p.setTool(slot - 1, for: id)
        case .autoSplit: try p.autoSplit(id)
        }
    }

    func assistantApply(recommendationID: String) throws {
        let p = try openProject()
        guard let action = p.recommendations.first(where: { $0.id == recommendationID })?.action else {
            throw AssistantError("Diese Empfehlung lässt sich nicht automatisch übernehmen.")
        }
        try p.apply(action)
    }

    func assistantSlice(cloud useCloud: Bool) async throws -> (PrintEstimate, engine: String) {
        let p = try openProject()
        p.slice(cloud: useCloud ? cloud : nil)
        let deadline = Date().addingTimeInterval(useCloud ? 900 : 600)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 300_000_000)
            guard project === p else { throw AssistantError("Das Projekt wurde geschlossen.") }
            switch p.state {
            case .slicing: continue
            case .done(let output): return (output.estimate, output.engine)
            case .failed(let message): throw AssistantError("Slicen fehlgeschlagen: \(message)")
            case .idle: throw AssistantError("Slicen wurde abgebrochen (z. B. weil sich Einstellungen geändert haben).")
            }
        }
        p.cancelSlicing()
        throw AssistantError("Slicen dauert zu lange und wurde abgebrochen.")
    }

    func assistantSelectPrinter(named name: String) throws {
        guard let p = printers.printers.first(where: { $0.name == name }) else { throw AssistantError("Drucker nicht gefunden.") }
        printers.selectedID = p.id
    }

    func assistantRun(_ command: PrinterCommand, on printerName: String) async throws {
        guard let printer = printers.printers.first(where: { $0.name == printerName }) else {
            throw AssistantError("Drucker nicht gefunden.")
        }
        let driver = printers.driver(for: printer)
        do {
            switch command {
            case .pause: try await driver.pause()
            case .resume: try await driver.resume()
            case .cancel: try await driver.cancel()
            case .bedTemperature(let t): try await driver.setBedTemperature(t)
            case .nozzleTemperature(let tool, let t): try await driver.setToolTemperature(tool: tool, t)
            case .light(let on): try await driver.setLight(on)
            }
            log.add(.info, "\(command.displayName) (über Claude)", source: printer.name)
        } catch {
            log.add(.error, "\(command.displayName) fehlgeschlagen: \(error.localizedDescription)", source: printer.name)
            throw error
        }
        await printers.refresh(printer)
    }

    func assistantSend(startPrint: Bool) async throws -> String {
        let p = try openProject()
        await send(p, startPrint: startPrint)
        switch sendState {
        case .done: return startPrint ? "Druck gestartet: \(p.gcodeFileName)" : "Hochgeladen: \(p.gcodeFileName)"
        case .failed(let message): throw AssistantError(message)
        default: throw AssistantError("Senden nicht abgeschlossen.")
        }
    }

    func assistantOpenLibrary(index: Int) async throws -> String {
        guard library.items.indices.contains(index - 1) else { throw AssistantError("Modell \(index) gibt es nicht.") }
        open(library.items[index - 1])
        return try await waitForProject()
    }

    func assistantImport(data: Data, fileName: String, title: String) async throws -> String {
        addDownloaded(data: data, fileName: fileName, title: title, source: .printables)
        return try await waitForProject()
    }

    private func waitForProject() async throws -> String {
        // open() loads in the background; wait until the project is there.
        try await Task.sleep(nanoseconds: 100_000_000)
        while isLoadingModel { try await Task.sleep(nanoseconds: 200_000_000) }
        guard let p = project else { throw AssistantError(alert ?? "Das Modell konnte nicht geöffnet werden.") }
        return "Geöffnet: „\(p.name)“ mit \(p.objects.count) Objekt(en) für \(p.settings.printer.displayName)."
    }

    func assistantConfirm(title: String, detail: String) async -> Bool {
        await assistant.confirm(title: title, detail: detail)
    }
}
