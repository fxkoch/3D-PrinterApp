import Foundation

/// Snapmaker U1 (four-tool toolchanger), from the official U1 Orca profile.
struct U1Dialect: MachineDialect {
    var toolChangeSeconds: Double { 12 }
    var preparationSeconds: Double { 300 }

    var thumbnailSizes: [(width: Int, height: Int)] { [(48, 48), (300, 300)] }

    func header(_ ctx: PrintContext) -> [String] {
        ["; curr_bed_type = \(ctx.settings.plateType.rawValue)"]
    }

    func start(_ ctx: PrintContext) -> [String] {
        let s = ctx.settings
        let t = ctx.initialTool
        let f = ctx.initialFilament
        let bed = f.bedTemp(for: s.plateType, firstLayer: true)
        let nozzle = f.nozzleTemp
        let purifier: String
        if f.vitrificationTemp <= 50 {
            purifier = "SET_PURIFIER_MODE MODE=1 DESIRE_TEMP=42 ALARM_TEMP=48 FAN_SPEED=0.6 DELAY_OFF=0 ; strong cooling"
        } else if f.vitrificationTemp <= 70 {
            purifier = "SET_PURIFIER_MODE MODE=1 DESIRE_TEMP=45 ALARM_TEMP=51 FAN_SPEED=0.6 DELAY_OFF=0 ; weak cooling"
        } else {
            purifier = "SET_PURIFIER_MODE MODE=3 DESIRE_TEMP=45 FAN_SPEED=0.6 DELAY_OFF=600 ; keep warm"
        }
        let highTemp = s.plateType == .highTemp
        var lines: [String] = [
            "SET_PRINT_AUTO_BED_LEVELING ENABLE=\(s.enableBedLeveling ? 1 : 0)",
            "SET_TIME_LAPSE_CAMERA ENABLE=\(s.enableTimelapse ? 1 : 0)",
            "PRINT_START",
            "DEFECT_DETECTION_START",
            "SET_PRINT_STATS_INFO TOTAL_LAYER=\(ctx.layers.count) CURRENT_LAYER=0",
        ]
        if s.enableTimelapse { lines.append("TIMELAPSE_START") }
        lines += [
            "M140 S\(bed)",
            "M104 T\(t) S140",
            "M204 S10000",
            ";===== top cover purifier =====",
            purifier,
            "G28 X Y",
            "DEFECT_DETECT_NOODLE_FIRST",
            ";===== bed foreign object detection =====",
            "T\(t)",
            "G90",
            "DEFECT_DETECTION_DETECT_BED",
            ";===== tool head check =====",
            "SM_PRINT_CHECK_SWITCH_EXTRUDER",
            ";===== auto feed & flow calibration =====",
            "SM_PRINT_EXTRUDER_PREHEAT EXTRUDER=1 TEMP=140",
            "SM_PRINT_AUTO_FEED EXTRUDER=0",
            "SM_PRINT_FLOW_CALIBRATE EXTRUDER=0",
            "SM_PRINT_EXTRUDER_PREHEAT EXTRUDER=2 TEMP=140",
            "SM_PRINT_AUTO_FEED EXTRUDER=1",
            "SM_PRINT_FLOW_CALIBRATE EXTRUDER=1",
            "SM_PRINT_EXTRUDER_PREHEAT EXTRUDER=3 TEMP=140",
            "SM_PRINT_AUTO_FEED EXTRUDER=2",
            "SM_PRINT_FLOW_CALIBRATE EXTRUDER=2",
            "SM_PRINT_AUTO_FEED EXTRUDER=3",
            "SM_PRINT_FLOW_CALIBRATE EXTRUDER=3",
            "M104 S0 T0 A0",
            "M104 S0 T1 A0",
            "M104 S0 T2 A0",
            "M104 S0 T3 A0",
            ";===== pre-extrude filament =====",
            "M104 T\(t) S\(nozzle)",
            "T\(t)",
            "M109 T\(t) S\(nozzle)",
            "SM_PRINT_PREEXTRUDE_FILAMENT INDEX=\(t)",
            "M104 T\(t) S\(nozzle - 90)",
            ";===== rough homing =====",
            "T\(t)",
            "M106 S255",
            "M106 P2 S0",
            "MOVE_TO_DISCARD_FILAMENT_POSITION",
            "M109 T\(t) S\(nozzle - 90)",
            "ROUGHLY_CLEAN_NOZZLE_WITH_DISCARD",
            "MOVE_TO_XY_IDLE_POSITION_EXTRUDER",
            "M107",
            "G28 Z I140 J140",
            ";===== detect build plate =====",
            "M107",
            "DETECT_BED_PLATE",
            ";===== deep nozzle cleaning =====",
            "M106 S255",
            "G90",
            "G0 Z5 F10000",
            "MOVE_TO_DISCARD_FILAMENT_POSITION",
            "M109 S\(nozzle - 50)",
            "ROUGHLY_CLEAN_NOZZLE",
            "MOVE_TO_XY_IDLE_POSITION_EXTRUDER",
            "FINELY_CLEAN_NOZZLE_STAGE_1",
            "M104 S\(nozzle - 90)",
            "G0 Z5 F10000",
            "MOVE_TO_DISCARD_FILAMENT_POSITION",
            "ROUGHLY_CLEAN_NOZZLE",
            "MOVE_TO_XY_IDLE_POSITION_EXTRUDER",
            "FINELY_CLEAN_NOZZLE_STAGE_2",
            ";===== fine homing =====",
            "M106 S255",
            "M109 S\(nozzle - 90)",
            "M190 S\(bed)",
            "M107 P2",
            "G90",
            "G0 Z5 F10000",
            "WAIT_CHAMBER_TEMP TIMEOUT=180",
            "M107",
            "G28 Z" + (highTemp ? " Z_OFFSET -0.07" : ""),
            ";===== bed leveling =====",
            "M107",
            bedMesh(ctx, zOffset: highTemp ? " Z_OFFSET=-0.07" : ""),
            ";===== prime line =====",
            "G90",
            "G1 Z1.5",
            "G0 X85 Y1 Z2 F18000",
            "M109 S\(f.firstLayerNozzleTemp)",
            "G1 Z0.2",
            "M83",
            "G1 X185 E15 F360",
            "G1 Z1.5",
            "G90",
            "M106 S0",
        ]
        return lines
    }

    /// Adaptive bed mesh limited to the first-layer footprint, like Orca does.
    private func bedMesh(_ ctx: PrintContext, zOffset: String) -> String {
        let margin = 5.0
        var minX = 3.0, minY = 3.0, maxX = 267.0, maxY = 267.0
        if let box = ctx.firstLayerBox {
            minX = max(3, box.min.mmX - margin); minY = max(3, box.min.mmY - margin)
            maxX = min(267, box.max.mmX + margin); maxY = min(267, box.max.mmY + margin)
            if maxX - minX < 10 { maxX = min(267, minX + 10) }
            if maxY - minY < 10 { maxY = min(267, minY + 10) }
        }
        let cx = max(3, min(7, Int(((maxX - minX) / 50).rounded(.up)) + 1))
        let cy = max(3, min(7, Int(((maxY - minY) / 50).rounded(.up)) + 1))
        let algo = min(cx, cy) >= 4 ? "bicubic" : "lagrange"
        return "BED_MESH_CALIBRATE mesh_min=\(fmt(minX)),\(fmt(minY)) mesh_max=\(fmt(maxX)),\(fmt(maxY)) "
            + "ALGORITHM=\(algo) PROBE_COUNT=\(cx),\(cy) ADAPTIVE=0 ADAPTIVE_MARGIN=0\(zOffset)"
    }

    func beforeLayer(_ layer: SlicedLayer, _ ctx: PrintContext) -> [String] {
        var lines = [";BEFORE_LAYER_CHANGE", ";\(fmt(layer.z))", "G92 E0"]
        if ctx.settings.enableTimelapse { lines.append("TIMELAPSE_TAKE_FRAME") }
        lines.append("DEFECT_DETECTION_DETECT")
        return lines
    }

    func afterLayer(_ layer: SlicedLayer, _ ctx: PrintContext) -> [String] {
        [";AFTER_LAYER_CHANGE", ";\(fmt(layer.z))",
         "SET_PRINT_STATS_INFO TOTAL_LAYER=\(ctx.layers.count) CURRENT_LAYER=\(layer.index + 1)"]
    }

    func toolChange(from: Int, to: Int, layer: SlicedLayer, _ ctx: PrintContext) -> [String] {
        let s = ctx.settings
        let filament = s.filament(for: to)
        let speed = min(s.travelSpeed, 350)
        let temp = layer.index == 0 ? filament.firstLayerNozzleTemp : filament.nozzleTemp
        var lines = [
            "; Change Tool\(from) -> Tool\(to) (layer \(layer.index))",
            "G91",
            "G1 Z1.5 F600",
            "G90",
            "G1 F\(Int(speed * 60))",
            "M109 S\(temp) T\(to)",
            "M400",
            "T\(to)",
        ]
        if filament.type == "PVA" { lines.append("SET_VELOCITY_LIMIT ACCEL=3000") }
        if to != ctx.initialTool { lines.append("SM_PRINT_PREEXTRUDE_FILAMENT INDEX=\(to)") }
        lines.append("G90")
        return lines
    }

    func end(_ ctx: PrintContext) -> [String] {
        var lines = ["M107", "PRINT_END"]
        if ctx.settings.enableTimelapse { lines.append("TIMELAPSE_STOP") }
        lines.append("; U1 nozzle flow metadata, in logical filament order")
        let slots = max(ctx.settings.machine.toolCount, (ctx.usedTools.max() ?? 0) + 1)
        lines.append("; filament_volume_type = " + Array(repeating: "standard", count: slots).joined(separator: ","))
        return lines
    }
}

/// Anycubic Kobra S1 with ACE Pro, from the official Kobra S1 Orca profile.
/// The firmware macro G9111 handles heating, levelling and priming; filament
/// changes are a plain `T<n>` that the ACE executes (cut, retract, feed, purge).
struct KobraS1Dialect: MachineDialect {
    var toolChangeSeconds: Double { 60 }
    var preparationSeconds: Double { 240 }

    var thumbnailSizes: [(width: Int, height: Int)] { [(230, 110)] }

    func header(_ ctx: PrintContext) -> [String] {
        ["; nozzle_type = brass", "; single_extruder_multi_material = 1"]
    }

    func start(_ ctx: PrintContext) -> [String] {
        let f = ctx.initialFilament
        let bed = f.bedTemp(for: ctx.settings.plateType, firstLayer: true)
        return [
            "G9111 bedTemp=\(bed) extruderTemp=\(f.firstLayerNozzleTemp)",
            "M117",
            "M190 S\(bed)",
            "M109 S\(f.firstLayerNozzleTemp)",
        ]
    }

    func beforeLayer(_ layer: SlicedLayer, _ ctx: PrintContext) -> [String] {
        ["; BEFORE_LAYER_CHANGE \(layer.index) @ \(fmt(layer.z))mm", "G92 E0"]
    }

    func afterLayer(_ layer: SlicedLayer, _ ctx: PrintContext) -> [String] {
        var lines = ["; AFTER_LAYER_CHANGE \(layer.index) @ \(fmt(layer.z))mm"]
        if layer.index == 1 {
            // Second layer: switch to the normal (non-first-layer) temperatures.
            let f = ctx.settings.filament(for: layer.islands.first?.tool ?? ctx.initialTool)
            lines.append("M104 S\(f.nozzleTemp)")
            lines.append("M140 S\(f.bedTemp(for: ctx.settings.plateType, firstLayer: false))")
        }
        return lines
    }

    func toolChange(from: Int, to: Int, layer: SlicedLayer, _ ctx: PrintContext) -> [String] {
        let f = ctx.settings.filament(for: to)
        let temp = layer.index == 0 ? f.firstLayerNozzleTemp : f.nozzleTemp
        return [
            "; FLUSH_START",
            "M104 S\(temp)",
            "T\(to) ; change extruder",
            "M109 S\(temp)",
            "; FLUSH_END",
        ]
    }

    func end(_ ctx: PrintContext) -> [String] {
        let maxZ = ctx.layers.last?.z ?? 0
        let maxH = ctx.settings.maxHeight
        var lines = ["G92 E0", "G1 E-2 F3000"]
        if maxZ < maxH - 1 {
            lines.append("G1 Z\(fmt(min(maxZ + 2, maxH))) F900 ; Move print head further up")
        }
        lines += [
            "G1 F12000; present print",
            "G1 X44;  throw_position_x",
            "G1 Y270; throw_position_y",
            "M140 S0 ; turn off heatbed",
            "M104 S0 ; turn off temperature",
            "M106 P1 S0 ; turn off fan",
            "M106 P2 S0",
            "M106 P3 S0",
            "M84; disable motors",
        ]
        return lines
    }
}
