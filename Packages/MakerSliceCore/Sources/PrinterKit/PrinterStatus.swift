import Foundation

/// Snapshot of the printer state, parsed from Moonraker's object query.
public struct PrinterStatus: Sendable, Equatable {
    public enum JobState: String, Sendable {
        case standby, printing, paused, complete, cancelled, error, unknown

        public var displayName: String {
            switch self {
            case .standby: return "Bereit"
            case .printing: return "Druckt"
            case .paused: return "Pausiert"
            case .complete: return "Fertig"
            case .cancelled: return "Abgebrochen"
            case .error: return "Fehler"
            case .unknown: return "Unbekannt"
            }
        }
    }

    public struct Heater: Sendable, Equatable {
        public var temperature: Double
        public var target: Double
    }

    /// Filament loaded in a tool head, as reported by the U1's RFID reader.
    public struct LoadedFilament: Sendable, Equatable {
        public var present: Bool
        public var vendor: String?
        public var type: String?
        public var subType: String?
        /// "#RRGGBB"
        public var color: String?

        public var displayName: String {
            guard present else { return "Leer" }
            return [vendor, type, subType].compactMap { $0 }.filter { $0 != "NONE" && !$0.isEmpty }.joined(separator: " ")
                .nilIfEmpty ?? "Unbekannt"
        }
    }

    public var state: JobState = .unknown
    public var stateMessage: String?
    public var fileName: String?
    /// 0...1
    public var progress: Double = 0
    public var printDuration: Double = 0
    public var currentLayer: Int?
    public var totalLayers: Int?
    public var bed = Heater(temperature: 0, target: 0)
    /// Index = tool (extruder, extruder1, extruder2, extruder3).
    public var tools: [Heater] = []
    public var activeTool: Int?
    public var filaments: [LoadedFilament] = []
    public var position: [Double] = []

    public init() {}

    /// Remaining time estimated from progress (like Fluidd's "file" estimate).
    public var remainingSeconds: Double? {
        guard state == .printing || state == .paused, progress > 0.01 else { return nil }
        return printDuration / progress - printDuration
    }

    /// Object names to request from Klipper.
    public static let queryObjects = [
        "print_stats", "virtual_sdcard", "display_status", "heater_bed",
        "extruder", "extruder1", "extruder2", "extruder3", "toolhead", "print_task_config",
    ]

    /// Parses the `status` dictionary of `/printer/objects/query`.
    public mutating func apply(_ status: [String: Any]) {
        if let ps = status["print_stats"] as? [String: Any] {
            if let s = ps["state"] as? String { state = JobState(rawValue: s) ?? .unknown }
            if let m = ps["message"] as? String { stateMessage = m.isEmpty ? nil : m }
            if let f = ps["filename"] as? String { fileName = f.isEmpty ? nil : f }
            if let d = number(ps["print_duration"]) { printDuration = d }
            if let info = ps["info"] as? [String: Any] {
                if let l = number(info["current_layer"]) { currentLayer = Int(l) }
                if let t = number(info["total_layer"]) { totalLayers = Int(t) }
            }
        }
        if let ds = status["display_status"] as? [String: Any], let p = number(ds["progress"]) {
            progress = p
        } else if let sd = status["virtual_sdcard"] as? [String: Any], let p = number(sd["progress"]) {
            progress = p
        }
        if let b = status["heater_bed"] as? [String: Any] {
            bed = Heater(temperature: number(b["temperature"]) ?? bed.temperature, target: number(b["target"]) ?? bed.target)
        }
        for (i, name) in ["extruder", "extruder1", "extruder2", "extruder3"].enumerated() {
            guard let e = status[name] as? [String: Any] else { continue }
            while tools.count <= i { tools.append(Heater(temperature: 0, target: 0)) }
            tools[i] = Heater(temperature: number(e["temperature"]) ?? tools[i].temperature,
                              target: number(e["target"]) ?? tools[i].target)
        }
        if let th = status["toolhead"] as? [String: Any] {
            if let ext = th["extruder"] as? String {
                activeTool = ext == "extruder" ? 0 : Int(ext.dropFirst("extruder".count))
            }
            if let pos = th["position"] as? [Any] { position = pos.compactMap(number) }
        }
        if let cfg = status["print_task_config"] as? [String: Any] {
            let exist = cfg["filament_exist"] as? [Any] ?? []
            let vendors = cfg["filament_vendor"] as? [Any] ?? []
            let types = cfg["filament_type"] as? [Any] ?? []
            let subTypes = cfg["filament_sub_type"] as? [Any] ?? []
            let colors = cfg["filament_color_rgba"] as? [Any] ?? []
            let count = max(exist.count, types.count, colors.count)
            if count > 0 {
                filaments = (0..<count).map { i in
                    func str(_ a: [Any]) -> String? { i < a.count ? a[i] as? String : nil }
                    let rgba = str(colors)
                    var present = true
                    if i < exist.count {
                        present = (exist[i] as? Bool) ?? ((number(exist[i]) ?? 0) != 0)
                    }
                    return LoadedFilament(
                        present: present,
                        vendor: str(vendors), type: str(types), subType: str(subTypes),
                        color: rgba.map { "#" + $0.prefix(6) }
                    )
                }
            }
        }
    }

    private func number(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
