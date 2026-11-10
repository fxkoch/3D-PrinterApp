import Foundation

/// How the app talks to a printer.
public enum ConnectionKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Klipper/Moonraker HTTP API (Snapmaker U1, Kobra S1 with Rinkhals firmware).
    case moonraker
    /// Anycubic stock firmware in LAN mode (local MQTT + HTTP upload).
    case anycubicLAN
    /// Bambu Lab printers in LAN mode (local MQTT over TLS + FTPS upload), e.g. the P1S.
    case bambuLAN

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .moonraker: return "Moonraker (Klipper)"
        case .anycubicLAN: return "Anycubic LAN-Modus"
        case .bambuLAN: return "Bambu LAN-Modus"
        }
    }
}

/// What the printer does before a print starts (the same switches the makers' own apps offer in their send dialog).
public struct PrintStartOptions: Equatable, Sendable {
    public var autoLeveling = true
    public var vibrationCompensation = false
    public var flowCalibration = false

    public init(autoLeveling: Bool = true, vibrationCompensation: Bool = false, flowCalibration: Bool = false) {
        self.autoLeveling = autoLeveling
        self.vibrationCompensation = vibrationCompensation
        self.flowCalibration = flowCalibration
    }
}

/// Filament slot assignment sent with a print start (ACE mapping).
public struct SlotMapping: Sendable, Equatable {
    /// Tool index in the G-code (T0…T3).
    public var tool: Int
    /// Physical slot on the printer (0-based).
    public var slot: Int
    public var materialType: String
    /// RGB(A) colour of the filament as used in the model.
    public var color: [Int]

    public init(tool: Int, slot: Int, materialType: String, color: [Int]) {
        self.tool = tool
        self.slot = slot
        self.materialType = materialType
        self.color = color
    }
}

/// A line for the printer log.
public struct PrinterEvent: Identifiable, Sendable, Equatable, Codable {
    public enum Level: String, Sendable, Codable, CaseIterable {
        case info, warning, error
    }

    public var id = UUID()
    public var date: Date
    public var level: Level
    public var message: String
    public var source: String

    public init(date: Date = Date(), level: Level, message: String, source: String) {
        self.date = date
        self.level = level
        self.message = message
        self.source = source
    }
}

/// Calibration values reported by the printer.
public struct CalibrationData: Sendable, Equatable {
    public struct BedMesh: Sendable, Equatable {
        public var profile: String
        public var min: (x: Double, y: Double)
        public var max: (x: Double, y: Double)
        /// Rows from front (min y) to back, values in mm.
        public var points: [[Double]]

        public static func == (a: BedMesh, b: BedMesh) -> Bool {
            a.profile == b.profile && a.points == b.points && a.min == b.min && a.max == b.max
        }

        public var range: Double {
            let flat = points.flatMap { $0 }
            guard let lo = flat.min(), let hi = flat.max() else { return 0 }
            return hi - lo
        }
    }

    public var bedMesh: BedMesh?
    public var zOffset: Double?
    /// Pressure advance per extruder name.
    public var pressureAdvance: [String: Double] = [:]
    public var inputShaper: [String: String] = [:]
    /// Free-form facts (firmware, feature flags, …).
    public var notes: [(String, String)] = []

    public init() {}

    public static func == (a: CalibrationData, b: CalibrationData) -> Bool {
        a.bedMesh == b.bedMesh && a.zOffset == b.zOffset && a.pressureAdvance == b.pressureAdvance
            && a.inputShaper == b.inputShaper && a.notes.map { "\($0.0)=\($0.1)" } == b.notes.map { "\($0.0)=\($0.1)" }
    }
}

/// Common interface of all printer connections.
public protocol PrinterDriver: AnyObject, Sendable {
    var connection: PrinterConnection { get }
    func status() async throws -> PrinterStatus
    func upload(gcode: Data, fileName: String, startPrint: Bool, mapping: [SlotMapping]) async throws
    func pause() async throws
    func resume() async throws
    func cancel() async throws
    func setBedTemperature(_ t: Int) async throws
    func setToolTemperature(tool: Int, _ t: Int) async throws
    /// Heats bed and (first) nozzle together.
    func preheat(bed: Int, nozzle: Int) async throws
    /// What this printer lets the app do with the filament (extrude, load a slot, unload).
    var filamentControl: FilamentControlSupport { get }
    /// Pushes (positive) or pulls back (negative) filament by `millimetres` with the hot nozzle.
    func extrude(millimetres: Double) async throws
    /// AMS/ACE: feeds the filament of `slot` (0-based) to the nozzle.
    func loadSlot(_ slot: Int) async throws
    /// Pulls the filament out completely.
    func unloadFilament() async throws
    /// ACE: pulls the filament of `slot` back into the box.
    func retractSlot(_ slot: Int) async throws
    func setLight(_ on: Bool) async throws
    func calibration() async throws -> CalibrationData
    /// Recent messages from the printer (console, errors).
    func recentEvents() async throws -> [PrinterEvent]
    func disconnect()
}

/// What the app may do with the filament on a printer.
public struct FilamentControlSupport: Sendable, Equatable {
    public var extrude = false
    public var loadSlot = false
    public var unload = false
    /// Pull the filament back into the box without unloading it completely (ACE).
    public var retract = false
    /// Explanation when something is not possible, or a hint.
    public var note: String?

    public init(extrude: Bool = false, loadSlot: Bool = false, unload: Bool = false, retract: Bool = false, note: String? = nil) {
        self.retract = retract
        self.extrude = extrude
        self.loadSlot = loadSlot
        self.unload = unload
        self.note = note
    }

    public var any: Bool { extrude || loadSlot || unload || retract }
}

/// G-code for a filament move: relative extruder, slow enough for a hot nozzle to melt it (pushing 3 mm/s, pulling 5 mm/s).
public enum FilamentMove {
    /// Longest single move the app sends.
    public static let maxMillimetres = 100.0
    /// Below this temperature filament must not be pushed through the nozzle.
    public static let minimumNozzleTemperature = 170.0

    public static func script(millimetres mm: Double) -> String {
        let clamped = max(-maxMillimetres, min(maxMillimetres, mm))
        let speed = clamped >= 0 ? 180 : 300   // mm/min
        return "M83\nG1 E\(String(format: "%.1f", clamped)) F\(speed)"
    }
}

extension PrinterDriver {
    public func preheat(bed: Int, nozzle: Int) async throws {
        try await setBedTemperature(bed)
        try await setToolTemperature(tool: 0, nozzle)
    }

    public var filamentControl: FilamentControlSupport {
        FilamentControlSupport(note: "Dieser Drucker lässt sich vom Handy aus nicht beim Filament bedienen.")
    }

    public func extrude(millimetres: Double) async throws { throw PrinterError.unsupported(filamentControl.note ?? "Nicht möglich.") }
    public func loadSlot(_ slot: Int) async throws { throw PrinterError.unsupported(filamentControl.note ?? "Nicht möglich.") }
    public func unloadFilament() async throws { throw PrinterError.unsupported(filamentControl.note ?? "Nicht möglich.") }
    public func retractSlot(_ slot: Int) async throws { throw PrinterError.unsupported(filamentControl.note ?? "Nicht möglich.") }

    /// Refuses to move filament through a cold nozzle (it would grind the filament or clog the extruder).
    func requireHotNozzle() async throws {
        let s = try await status()
        let hot = s.tools.map(\.temperature).max() ?? 0
        guard hot >= FilamentMove.minimumNozzleTemperature else {
            throw PrinterError.unsupported("Die Düse ist nur \(Int(hot)) °C warm. Zum Vorschieben oder Zurückziehen muss sie mindestens \(Int(FilamentMove.minimumNozzleTemperature)) °C haben – erst aufheizen.")
        }
    }
}

public enum PrinterDrivers {
    /// Creates the right driver for a configured printer.
    public static func make(for connection: PrinterConnection) -> PrinterDriver {
        switch connection.kind {
        case .moonraker:
            return MoonrakerClient(connection: connection)
        case .anycubicLAN:
            #if canImport(Network)
            return AnycubicLANClient(connection: connection)
            #else
            return MoonrakerClient(connection: connection)
            #endif
        case .bambuLAN:
            #if canImport(Network)
            return BambuLANClient(connection: connection)
            #else
            return MoonrakerClient(connection: connection)
            #endif
        }
    }
}
