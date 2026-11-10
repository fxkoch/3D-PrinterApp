import Foundation

extension PrinterStatus {
    /// Merges one `print` object of a Bambu report (the printer sends the full state on `pushall` and changes afterwards).
    mutating func applyBambu(_ p: [String: Any]) {
        if let s = p["gcode_state"] as? String {
            switch s {
            case "IDLE": state = .standby
            case "PREPARE", "RUNNING": state = .printing
            case "PAUSE": state = .paused
            case "FINISH": state = .complete
            case "FAILED": state = .error
            default: break
            }
        }
        if let code = jsonNumber(p["print_error"]) {
            let c = Int(code)
            if c == 0 { if state == .error { stateMessage = nil } }
            else if c == 50348044 { if state == .error { state = .cancelled }; stateMessage = "Druck wurde abgebrochen." }
            else { stateMessage = Self.bambuErrorText(c) }
        }
        if let v = jsonNumber(p["mc_percent"]) { progress = max(0, min(1, v / 100)) }
        if let v = jsonNumber(p["mc_remaining_time"]) { reportedRemainingSeconds = v * 60 }
        if let v = jsonNumber(p["layer_num"]) { currentLayer = Int(v) }
        if let v = jsonNumber(p["total_layer_num"]) { totalLayers = Int(v) }
        if let n = (p["gcode_file"] as? String) ?? (p["subtask_name"] as? String), !n.isEmpty { fileName = n }
        if p["nozzle_temper"] != nil || p["nozzle_target_temper"] != nil {
            let cur = tools.first ?? Heater(temperature: 0, target: 0)
            let heater = Heater(temperature: jsonNumber(p["nozzle_temper"]) ?? cur.temperature, target: jsonNumber(p["nozzle_target_temper"]) ?? cur.target)
            if tools.isEmpty { tools = [heater] } else { tools[0] = heater }
            activeTool = 0
        }
        if p["bed_temper"] != nil || p["bed_target_temper"] != nil {
            bed = Heater(temperature: jsonNumber(p["bed_temper"]) ?? bed.temperature, target: jsonNumber(p["bed_target_temper"]) ?? bed.target)
        }
        if let v = jsonNumber(p["chamber_temper"]) { chamber = Heater(temperature: v, target: chamber?.target ?? 0) }
        if let v = jsonNumber(p["cooling_fan_speed"]) { fanPercent = (v / 15 * 100).rounded() }
        if let v = jsonNumber(p["big_fan1_speed"]) { auxFanPercent = (v / 15 * 100).rounded() }
        if let v = jsonNumber(p["spd_lvl"]) { speedMode = max(1, min(3, Int(v))) }
        if let lights = p["lights_report"] as? [[String: Any]] {
            for l in lights where (l["node"] as? String) == "chamber_light" { lightOn = (l["mode"] as? String) == "on" }
        }
        if let ams = p["ams"] as? [String: Any] { applyBambuAMS(ams) }
    }

    private mutating func applyBambuAMS(_ ams: [String: Any]) {
        guard let units = ams["ams"] as? [[String: Any]] else { return }
        var slots: [LoadedFilament] = []
        var humidity: Double?
        for unit in units {
            if let h = jsonNumber(unit["humidity_raw"]) { humidity = h }
            let trays = unit["tray"] as? [[String: Any]] ?? []
            for tray in trays {
                let type = tray["tray_type"] as? String ?? ""
                let sub = tray["tray_sub_brands"] as? String
                var color = tray["tray_color"] as? String
                if let c = color, c.count >= 6 { color = "#" + c.prefix(6) }
                slots.append(LoadedFilament(present: !type.isEmpty, vendor: (tray["tray_uuid"] as? String).flatMap { $0.allSatisfy { $0 == "0" } ? nil : "Bambu Lab" },
                                            type: type.isEmpty ? nil : type, subType: sub?.isEmpty == false ? sub : nil, color: type.isEmpty ? nil : color))
            }
        }
        if !slots.isEmpty { filaments = slots }
        if filamentBox == nil { filamentBox = FilamentBox() }
        if let humidity { filamentBox?.humidity = humidity }
        if let now = jsonNumber(ams["tray_now"]) { filamentBox?.activeSlot = now < 254 ? Int(now) : nil }
    }

    /// Error codes are shown as in the printer's own display: "0300-4012".
    static func bambuErrorText(_ code: Int) -> String {
        let hex = String(format: "%08X", code)
        let formatted = "\(hex.prefix(4))-\(hex.suffix(4))"
        switch hex.prefix(4) {
        case "0700": return "AMS-Meldung \(formatted): Filament oder AMS-Slot prüfen."
        case "0300": return "Bewegungsfehler \(formatted): Achsen, Riemen und Druckkopf prüfen."
        case "0500": return "Systemmeldung \(formatted): Details am Drucker-Display."
        case "0C00": return "Kamera/Erste-Schicht-Prüfung \(formatted): Haftung am Bett prüfen."
        default: return "Druckerfehler \(formatted)."
        }
    }
}
