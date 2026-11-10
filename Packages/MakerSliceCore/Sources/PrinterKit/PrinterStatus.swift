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

    /// Anycubic ACE Pro 2 units on a Snapmaker U1, reported by the multiACE add-on (`ace` Klipper object).
    public struct MultiACE: Sendable, Equatable {
        public struct Slot: Sendable, Equatable {
            public var index: Int
            public var present: Bool
            public var material: String?
            /// "#RRGGBB"
            public var color: String?
        }

        public struct Unit: Sendable, Equatable {
            public var index: Int
            public var model: String
            public var connected: Bool
            public var humidity: Double?
            public var temperature: Double?
            public var drying = false
            public var dryingTarget: Double?
            public var dryingRemainingMinutes: Double?
            public var slots: [Slot] = []
        }

        /// "normal" (stock feeders), "head" or "multi" (every tool head fed from the ACE).
        public var mode: String
        public var units: [Unit]
        /// Index = tool head (0...3): the ACE slot that feeds it, `nil` when none is assigned.
        public var headSlots: [Slot?]
        public var swapInProgress: Bool

        public var isMultiMode: Bool { mode == "multi" || mode == "head" }
    }

    public var state: JobState = .unknown
    /// True when the printer itself says it is idle: a "failed" or "finished" state is then only the result of the last job
    /// (there is nothing to cancel).
    public var isIdle = false
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
    /// Set when the multiACE add-on runs on the printer.
    public var ace: MultiACE?
    /// Snapmaker U1 top cover: filter fan (inner) and exhaust fan, set when the cover is detected.
    public var purifier: Purifier?
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
        "extruder", "extruder1", "extruder2", "extruder3", "toolhead", "print_task_config", "ace", "purifier",
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
        if let ace = status["ace"] as? [String: Any] { applyMultiACE(ace) }
        if let p = status["purifier"] as? [String: Any], (p["power_detected"] as? Bool) == true {
            func speed(_ key: String) -> Double { ((p[key] as? [String: Any])?["speed"] as? Double) ?? 0 }
            let modes = [0: "Leerlauf", 1: "Abluft (kühlt die Kammer)", 2: "Vorheizen (Umluft)", 3: "Umluft (Filter)"]
            purifier = Purifier(mode: modes[(p["mode"] as? Int) ?? 0] ?? "?", exhaustSpeed: speed("exhaust_fan"), innerSpeed: speed("inner_fan"),
                                innerRPM: (p["inner_fan_rpm"] as? Double) ?? 0, innerHours: ((p["inner_fan_work_time"] as? Double) ?? 0) / 3600)
        }
    }

    public struct Purifier: Equatable, Sendable {
        public var mode: String
        public var exhaustSpeed: Double
        public var innerSpeed: Double
        public var innerRPM: Double
        /// Operating hours of the filter fan (the filter should be changed after about 720 h of recirculation).
        public var innerHours: Double
    }

    /// Parses the multiACE `ace` object: units, slots, humidity/dryer and which slot feeds which tool head.
    mutating func applyMultiACE(_ ace: [String: Any]) {
        func hex(_ rgb: Any?) -> String? {
            if let s = rgb as? String, !s.isEmpty { return "#" + s.replacingOccurrences(of: "#", with: "").prefix(6).uppercased() }
            guard let a = rgb as? [Any], a.count >= 3 else { return nil }
            let c = a.prefix(3).map { Int(number($0) ?? 0) }
            return String(format: "#%02X%02X%02X", c[0], c[1], c[2])
        }
        var units: [MultiACE.Unit] = []
        for u in ace["aces"] as? [[String: Any]] ?? [] {
            var unit = MultiACE.Unit(index: Int(number(u["idx"]) ?? Double(units.count)), model: (u["model"] as? String) ?? "ACE",
                                     connected: (u["connected"] as? Bool) ?? true)
            unit.humidity = number(u["humidity_effective"]) ?? number(u["humidity"])
            unit.temperature = number(u["temp"])
            if let d = u["dryer_status"] as? [String: Any] {
                let st = (d["status"] as? String) ?? ""
                unit.drying = ["drying", "keeping", "heating", "running"].contains(st)
                unit.dryingTarget = number(d["target_temp"])
                unit.dryingRemainingMinutes = number(d["remain_time"]).map { $0 / 60 }
            }
            // The gate sensors know whether a spool is in the slot; spools without an RFID chip report no material.
            let gates = u["gate_status"] as? [Any] ?? []
            unit.slots = (u["slots"] as? [[String: Any]] ?? []).map { sl in
                let index = Int(number(sl["index"]) ?? 0)
                let material = (sl["material"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let gate = index < gates.count ? (number(gates[index]) ?? 0) != 0 : false
                return MultiACE.Slot(index: index, present: gate || material != nil || (sl["status"] as? String) == "ready",
                                     material: material, color: material == nil ? nil : hex(sl["color"]))
            }
            units.append(unit)
        }
        var heads: [MultiACE.Slot?] = Array(repeating: nil, count: 4)
        let sources = ace["head_source"] as? [String: Any] ?? [:]
        for (key, value) in sources {
            guard let head = Int(key), (0..<4).contains(head), let src = value as? [String: Any] else { continue }
            let type = (src["type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            heads[head] = MultiACE.Slot(index: Int(number(src["slot"]) ?? 0), present: type != nil,
                                        material: [type, (src["subtype"] as? String).flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }.joined(separator: " ").nilIfEmpty,
                                        color: hex(src["color"]))
            if type != nil {
                while filaments.count <= head { filaments.append(LoadedFilament(present: false)) }
                filaments[head] = LoadedFilament(present: true, vendor: (src["brand"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                                 type: type, subType: (src["subtype"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                                 color: hex(src["color"]))
            }
        }
        self.ace = MultiACE(mode: (ace["mode"] as? String) ?? "normal", units: units, headSlots: heads,
                            swapInProgress: (ace["swap_in_progress"] as? Bool) ?? false)
        if let first = units.first {
            filamentBox = FilamentBox(temperature: first.temperature, humidity: first.humidity, drying: first.drying,
                                      dryingTarget: first.dryingTarget, dryingRemainingMinutes: first.dryingRemainingMinutes, activeSlot: nil)
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
            if let t = p["taskid"] ?? p["task_id"], !(t is NSNull) { taskID = "\(t)" }
            if let st = p["state"] as? String { state = Self.anycubicState(st, pause: num(p["pause"])) }
        }
        switch type {
        case "info":
            if let t = data["temp"] as? [String: Any] { applyTemps(t) }
            if let v = data["version"] as? String { firmware = v }
            if let v = num(data["print_speed_mode"]) { speedMode = Int(v) }
            if let v = num(data["fan_speed_pct"]) { fanPercent = v }
            if let v = num(data["aux_fan_speed_pct"]) { auxFanPercent = v }
            let top = data["state"] as? String
            isIdle = top == "free"
            if let project = data["project"] as? [String: Any], !project.isEmpty {
                applyProject(project)
                // While a job starts (heating, leveling) the printer reports `project.state: null` and only the
                // top-level state ("busy"); without this the app would show "unknown" and offer no cancel button.
                if project["state"] == nil || project["state"] is NSNull, let top = data["state"] as? String {
                    state = Self.anycubicState(top, pause: num(project["pause"]))
                }
            } else if top == "busy", state != .paused {
                // Heating, leveling or loading before the job reports anything of its own.
                state = .printing
            } else if top == "free" {
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
