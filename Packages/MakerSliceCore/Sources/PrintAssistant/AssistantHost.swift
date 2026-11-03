import Foundation
import PrinterKit
import SliceKit

/// A configured printer as the assistant sees it (live).
public struct AssistantPrinter {
    public var name: String
    public var model: PrinterModel
    public var host: String
    public var isSelected: Bool
    public var status: PrinterStatus?
    public var error: String?

    public init(name: String, model: PrinterModel, host: String, isSelected: Bool, status: PrinterStatus?, error: String?) {
        self.name = name
        self.model = model
        self.host = host
        self.isSelected = isSelected
        self.status = status
        self.error = error
    }

    public var isOnline: Bool { status != nil && error == nil }
}

public struct AssistantObject {
    /// 1-based, as shown to the user.
    public var index: Int
    public var name: String
    public var size: Vec3
    /// 1-based material slot.
    public var slot: Int

    public init(index: Int, name: String, size: Vec3, slot: Int) {
        self.index = index
        self.name = name
        self.size = size
        self.slot = slot
    }
}

public enum AssistantSliceState {
    case idle
    case slicing(phase: String, fraction: Double)
    case done(PrintEstimate, engine: String)
    case failed(String)
}

/// The open project ("Vorbereiten" screen).
public struct AssistantProject {
    public var name: String
    public var objects: [AssistantObject]
    public var settings: PrintSettings
    public var recommendations: [Recommendation]
    public var slice: AssistantSliceState
    public var warning: String?

    public init(name: String, objects: [AssistantObject], settings: PrintSettings, recommendations: [Recommendation],
                slice: AssistantSliceState, warning: String?) {
        self.name = name
        self.objects = objects
        self.settings = settings
        self.recommendations = recommendations
        self.slice = slice
        self.warning = warning
    }
}

public struct AssistantLibraryItem {
    public var name: String
    public var source: String
    public var added: Date

    public init(name: String, source: String, added: Date) {
        self.name = name
        self.source = source
        self.added = added
    }
}

public enum ObjectEdit: Equatable {
    case rotate(degrees: Double)
    case scale(factor: Double)
    case layFlat
    case duplicate
    case remove
    case setSlot(Int)
    case autoSplit
}

public enum PrinterCommand: Equatable {
    case pause, resume, cancel
    case bedTemperature(Int)
    case nozzleTemperature(tool: Int, Int)
    case light(Bool)

    public var displayName: String {
        switch self {
        case .pause: return "Druck pausieren"
        case .resume: return "Druck fortsetzen"
        case .cancel: return "Druck abbrechen"
        case .bedTemperature(let t): return t == 0 ? "Bettheizung aus" : "Bett auf \(t) °C heizen"
        case .nozzleTemperature(let tool, let t): return t == 0 ? "Düse \(tool + 1) aus" : "Düse \(tool + 1) auf \(t) °C heizen"
        case .light(let on): return on ? "Licht an" : "Licht aus"
        }
    }
}

/// Live access to the app. Implemented by the app's model; the assistant reads and changes
/// state only through this protocol.
@MainActor
public protocol AssistantHost: AnyObject {
    var assistantPrinters: [AssistantPrinter] { get }
    var assistantProject: AssistantProject? { get }
    var assistantLibrary: [AssistantLibraryItem] { get }
    var cloudSlicingAvailable: Bool { get }
    func assistantEvents(limit: Int) -> [PrinterEvent]

    func assistantSetSettings(_ settings: PrintSettings) throws
    func assistantEdit(object index: Int, _ edit: ObjectEdit) throws
    func assistantApply(recommendationID: String) throws
    /// Slices the open project and waits for the result.
    func assistantSlice(cloud: Bool) async throws -> (PrintEstimate, engine: String)
    func assistantSelectPrinter(named name: String) throws
    func assistantRun(_ command: PrinterCommand, on printerName: String) async throws
    /// Uploads the sliced project to the selected printer; returns a short status text.
    func assistantSend(startPrint: Bool) async throws -> String
    func assistantOpenLibrary(index: Int) async throws -> String
    func assistantImport(data: Data, fileName: String, title: String) async throws -> String
    /// Asks the user in the chat. Every action that moves the printer goes through here.
    func assistantConfirm(title: String, detail: String) async -> Bool
}

public struct AssistantError: LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
