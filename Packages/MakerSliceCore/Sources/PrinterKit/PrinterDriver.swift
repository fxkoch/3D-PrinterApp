import Foundation

/// How the app talks to a printer.
public enum ConnectionKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Klipper/Moonraker HTTP API (Snapmaker U1, Kobra S1 with Rinkhals firmware).
    case moonraker
    /// Anycubic stock firmware in LAN mode (local MQTT + HTTP upload).
    case anycubicLAN

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .moonraker: return "Moonraker (Klipper)"
        case .anycubicLAN: return "Anycubic LAN-Modus"
        }
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
    func setLight(_ on: Bool) async throws
    func calibration() async throws -> CalibrationData
    /// Recent messages from the printer (console, errors).
    func recentEvents() async throws -> [PrinterEvent]
    func disconnect()
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
        }
    }
}
