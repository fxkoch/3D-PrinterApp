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
        public init(present: Bool, vendor: String? = nil, type: String? = nil, subType: String? = nil, color: String? = nil) {
            self.present = present
            self.vendor = vendor
            self.type = type
            self.subType = subType
            self.color = color
        }

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

    /// Filament dryer/box state (Anycubic ACE Pro).
    public struct FilamentBox: Sendable, Equatable {
        public var temperature: Double?
        public var humidity: Double?
        public var drying: Bool = false
        public var dryingTarget: Double?
        public var dryingRemainingMinutes: Double?
        public var activeSlot: Int?
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
    public var chamber: Heater?
    /// Part-cooling fan in percent.
    public var fanPercent: Double?
    public var auxFanPercent: Double?
    /// 1 silent, 2 standard, 3 sport (Anycubic).
    public var speedMode: Int?
    public var lightOn: Bool?
    public var filamentBox: FilamentBox?
    public var firmware: String?
    public var cameraStreamURL: URL?
    /// Remaining time reported by the printer itself, if any.
    public var reportedRemainingSeconds: Double?
    /// Anycubic task id of the running job.
    public var taskID: String?

    public init() {}

    /// Remaining time estimated from progress (like Fluidd's "file" estimate).
    public var remainingSeconds: Double? {
        if let r = reportedRemainingSeconds, state == .printing || state == .paused { return r }
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

// MARK: - Anycubic LAN reports

extension PrinterStatus {
    /// Merges one Anycubic MQTT report (`type` = topic kind, `data` = payload "data").
    public mutating func applyAnycubic(type: String, data: [String: Any]) {
        func num(_ v: Any?) -> Double? { jsonNumber(v) }
        func applyTemps(_ t: [String: Any]) {
            if tools.isEmpty { tools = [Heater(temperature: 0, target: 0)] }
            if let v = num(t["curr_nozzle_temp"]) { tools[0].temperature = v }
            if let v = num(t["target_nozzle_temp"]) { tools[0].target = v }
            if let v = num(t["curr_hotbed_temp"]) { bed.temperature = v }
            if let v = num(t["target_hotbed_temp"]) { bed.target = v }
            if let v = num(t["curr_chamber_temp"]) {
                chamber = Heater(temperature: v, target: num(t["target_chamber_temp"]) ?? chamber?.target ?? 0)
            }
        }
        func applyProject(_ p: [String: Any]) {
            if let v = num(p["progress"]) { progress = v / 100 }
            if let v = num(p["curr_layer"]) { currentLayer = Int(v) }
            if let v = num(p["total_layers"]) { totalLayers = Int(v) }
            if let v = num(p["remain_time"]) { reportedRemainingSeconds = v * 60 }
            if let v = num(p["print_time"]) { printDuration = v }
            if let f = p["filename"] as? String, !f.isEmpty { fileName = f }
            if let t = p["taskid"] { taskID = "\(t)" }
            if let st = p["state"] as? String { state = Self.anycubicState(st, pause: num(p["pause"])) }
        }
        switch type {
        case "info":
            if let t = data["temp"] as? [String: Any] { applyTemps(t) }
            if let v = data["version"] as? String { firmware = v }
            if let v = num(data["print_speed_mode"]) { speedMode = Int(v) }
            if let v = num(data["fan_speed_pct"]) { fanPercent = v }
            if let v = num(data["aux_fan_speed_pct"]) { auxFanPercent = v }
            if let project = data["project"] as? [String: Any], !project.isEmpty {
                applyProject(project)
            } else if (data["state"] as? String) == "free" {
                if state == .printing || state == .paused || state == .unknown { state = .standby }
                if let last = data["last_project"] as? [String: Any], let st = last["state"] as? String {
                    let s = Self.anycubicState(st, pause: nil)
                    if s == .complete || s == .cancelled || s == .error { state = s }
                    if let f = last["filename"] as? String { fileName = f }
                }
            }
            if let urls = data["urls"] as? [String: Any], let rtsp = urls["rtspUrl"] as? String { cameraStreamURL = URL(string: rtsp) }
        case "tempature", "temperature":
            applyTemps(data)
        case "fan":
            if let v = num(data["fan_speed_pct"]) { fanPercent = v }
            if let v = num(data["aux_fan_speed_pct"]) { auxFanPercent = v }
        case "print":
            if data["progress"] != nil { applyProject(data) }
        case "light":
            let light = (data["lights"] as? [[String: Any]])?.first ?? data
            if let st = num(light["status"]) { lightOn = st != 0 }
        case "multiColorBox":
            guard let box = (data["multi_color_box"] as? [[String: Any]])?.first else { return }
            var fb = filamentBox ?? FilamentBox()
            if let v = num(box["temp"]) { fb.temperature = v }
            let dry = box["drying_status"] as? [String: Any]
            if let v = num(box["humidity"]) ?? num(dry?["humidity"]) { fb.humidity = v }
            if let dry {
                if let st = num(dry["status"]) { fb.drying = st != 0 }
                if let v = num(dry["target_temp"]) { fb.dryingTarget = v }
                if let v = num(dry["remain_time"]) { fb.dryingRemainingMinutes = v }
            }
            if let v = num(box["loaded_slot"]) { fb.activeSlot = v >= 0 ? Int(v) : nil }
            filamentBox = fb
            if let slots = box["slots"] as? [[String: Any]] {
                for slot in slots {
                    guard let idx = num(slot["index"]).map(Int.init), idx >= 0, idx < 16 else { continue }
                    while filaments.count <= idx { filaments.append(LoadedFilament(present: false)) }
                    let type = (slot["type"] as? String) ?? ""
                    var color: String?
                    if let rgb = slot["color"] as? [Any], rgb.count >= 3 {
                        let c = rgb.prefix(3).map { Int(num($0) ?? 0) }
                        color = String(format: "#%02X%02X%02X", c[0], c[1], c[2])
                    }
                    filaments[idx] = LoadedFilament(present: !type.isEmpty, vendor: (slot["sku"] as? String).flatMap { $0.isEmpty ? nil : "Anycubic" },
                                                    type: type.isEmpty ? nil : type, subType: nil, color: color)
                }
            }
        default:
            break
        }
    }

    static func anycubicState(_ s: String, pause: Double?) -> JobState {
        if let p = pause, p == 1 || p == 2 { return .paused }
        switch s {
        case "printing", "resumed", "resuming", "preheating", "auto_leveling", "vibrating", "flow_calibrating", "updated", "busy":
            return .printing
        case "paused", "pausing": return .paused
        case "finished", "complete", "done": return .complete
        case "stoped", "stopped", "canceled", "cancelled", "stopping": return .cancelled
        case "failed": return .error
        case "free": return .standby
        default: return .printing
        }
    }
}
