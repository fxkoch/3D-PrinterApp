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
        // Quiet air: exhaust fan starts low (the printer raises it by itself above the desired chamber temperature),
        // the filter (inner) fan runs at a fixed low speed. Hot materials already use the inner fan only.
        let inner = String(format: "%.2f", s.quietInnerFanSpeed)
        let coolStart = s.quietAir ? "0.30" : "0.6"
        let purifier: String
        if f.vitrificationTemp <= 50 {
            purifier = "SET_PURIFIER_MODE MODE=1 DESIRE_TEMP=42 ALARM_TEMP=48 FAN_SPEED=\(coolStart) DELAY_OFF=0 ; strong cooling"
        } else if f.vitrificationTemp <= 70 {
            purifier = "SET_PURIFIER_MODE MODE=1 DESIRE_TEMP=45 ALARM_TEMP=51 FAN_SPEED=\(coolStart) DELAY_OFF=0 ; weak cooling"
        } else {
            purifier = "SET_PURIFIER_MODE MODE=3 DESIRE_TEMP=45 FAN_SPEED=\(s.quietAir ? inner : "0.6") DELAY_OFF=600 ; keep warm"
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
        ] + (s.quietAir && f.vitrificationTemp <= 70 ? ["SET_PURIFIER FAN=inner SPEED=\(inner) ; filter fan, quiet"] : []) + [
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

/// Bambu Lab P1S (Marlin-based firmware, optional AMS), from the official Bambu Studio / OrcaSlicer machine profile
/// "Bambu Lab P1S 0.4 nozzle". The printer starts the file itself (`project_file` over MQTT), reports progress from
/// M73 and takes the AMS slot from `T<n>`.
struct BambuP1SDialect: MachineDialect {
    var toolChangeSeconds: Double { 45 }
    var preparationSeconds: Double { 360 }
    var thumbnailSizes: [(width: Int, height: Int)] { [] }

    func pressureAdvance(_ k: Double) -> String { "M900 K\(fmt5(k)) ; pressure advance" }
    func acceleration(_ a: Int) -> String { "M204 S\(a)" }

    func header(_ ctx: PrintContext) -> [String] {
        ["; curr_bed_type = \(ctx.settings.plateType.rawValue)", "; nozzle_type = hardened_steel", "; single_extruder_multi_material = 1"]
    }

    func start(_ ctx: PrintContext) -> [String] {
        let f = ctx.initialFilament
        let s = ctx.settings
        let bed = f.bedTemp(for: s.plateType, firstLayer: true)
        let nozzle = f.firstLayerNozzleTemp
        let slot = ctx.initialTool
        var box = (x: 0.0, y: 0.0, w: s.bedSize, h: s.bedSize)
        if let b = ctx.firstLayerBox {
            box = (max(0, b.min.mmX), max(0, b.min.mmY), min(s.bedSize, b.max.mmX) - max(0, b.min.mmX), min(s.bedSize, b.max.mmY) - max(0, b.min.mmY))
        }
        let pla = f.type.uppercased().hasPrefix("PLA") && bed > 45
        var lines: [String] = [
            ";===== machine: P1S-0.4 ========================",
            ";===== turn on the HB fan & MC board fan =================",
            "M104 S75 ;set extruder temp to turn on the HB fan and prevent filament oozing from nozzle",
            "M710 A1 S255 ;turn on MC fan by default(P1S)",
            ";===== reset machine status =================",
            "M290 X40 Y40 Z2.6666666",
            "G91",
            "M17 Z0.4 ; lower the z-motor current",
            "G380 S2 Z30 F300 ; lower the hotbed , to prevent the nozzle is below the hotbed",
            "G380 S2 Z-25 F300 ;",
            "G1 Z5 F300;",
            "G90",
            "M17 X1.2 Y1.2 Z0.75 ; reset motor current to default",
            "M960 S5 P1 ; turn on logo lamp",
            "G90",
            "M220 S100 ;Reset Feedrate",
            "M221 S100 ;Reset Flowrate",
            "M73.2   R1.0 ;Reset left time magnitude",
            "M1002 set_gcode_claim_speed_level : 5",
            "M221 X0 Y0 Z0 ; turn off soft endstop to prevent protential logic problem",
            "G29.1 Z{+0.0} ; clear z-trim value first",
            "M204 S10000 ; init ACC set to 10m/s^2",
            ";===== heatbed preheat ====================",
            "M1002 gcode_claim_action : 2",
            "M140 S\(bed) ;set bed temp",
            "M190 S\(bed) ;wait for bed temp",
        ]
        if pla { lines.append("M106 P3 S180 ;Prevent PLA from jamming") }
        lines += [
            "M106 P2 S100 ; turn on big fan ,to cool down toolhead",
            ";===== prepare print temperature and material ==========",
            "M104 S\(nozzle) ;set extruder temp",
            "G91",
            "G0 Z10 F1200",
            "G90",
            "G28 X",
            "M975 S1 ; turn on",
            "G1 X60 F12000",
            "G1 Y245",
            "G1 Y265 F3000",
            "M620 M",
            "M620 S\(slot)A   ; switch material if AMS exist",
            "    M109 S\(nozzle)",
            "    G1 X120 F12000",
            "    G1 X20 Y50 F12000",
            "    G1 Y-3",
            "    T\(slot)",
            "    G1 X54 F12000",
            "    G1 Y265",
            "    M400",
            "M621 S\(slot)A",
            "M620.1 E F\(Int(f.maxVolumetricSpeed / 2.4053 * 60)) T\(nozzle)",
            "M412 S1 ; ===turn on filament runout detection===",
            "M109 S250 ;set nozzle to common flush temp",
            "M106 P1 S0",
            "G92 E0",
            "G1 E50 F200",
            "M400",
            "M104 S\(nozzle)",
            "G92 E0",
            "G1 E50 F200",
            "M400",
            "M106 P1 S255",
            "G92 E0",
            "G1 E5 F300",
            "M109 S\(nozzle - 20) ; drop nozzle temp, make filament shink a bit",
            "G92 E0",
            "G1 E-0.5 F300",
            "G1 X70 F9000",
            "G1 X76 F15000",
            "G1 X65 F15000",
            "G1 X76 F15000",
            "G1 X65 F15000; shake to put down garbage",
            "G1 X80 F6000",
            "G1 X95 F15000",
            "G1 X80 F15000",
            "G1 X165 F15000; wipe and shake",
            "M400",
            "M106 P1 S0",
            ";===== prepare print temperature and material end =====",
            ";===== wipe nozzle ===============================",
            "M1002 gcode_claim_action : 14",
            "M975 S1",
            "M106 S255",
            "G1 X65 Y230 F18000",
            "G1 Y264 F6000",
            "M109 S\(nozzle - 20)",
            "G1 X100 F18000 ; first wipe mouth",
            "G0 X135 Y253 F20000  ; move to exposed steel surface edge",
            "G28 Z P0 T300; home z with low precision,permit 300deg temperature",
            "G29.2 S0 ; turn off ABL",
            "G0 Z5 F20000",
            "G1 X60 Y265",
            "G92 E0",
            "G1 E-0.5 F300 ; retrack more",
            "G1 X100 F5000; second wipe mouth",
            "G1 X70 F15000",
            "G1 X100 F5000",
            "G1 X70 F15000",
            "G1 X100 F5000",
            "G1 X70 F15000",
            "G1 X90 F5000",
            "G0 X128 Y261 Z-1.5 F20000  ; move to exposed steel surface and stop the nozzle",
            "M104 S140 ; set temp down to heatbed acceptable",
            "M106 S255 ; turn on fan (G28 has turn off fan)",
            "M221 S; push soft endstop status",
            "M221 Z0 ;turn off Z axis endstop",
            "G0 Z0.5 F20000",
            "G0 X125 Y259.5 Z-1.01",
            "G0 X131 F211",
            "G0 X124",
            "G0 Z0.5 F20000",
            "G0 X125 Y262.5",
            "G0 Z-1.01",
            "G0 X131 F211",
            "G0 X124",
            "G0 Z0.5 F20000",
            "G0 X125 Y260.0",
            "G0 Z-1.01",
            "G0 X131 F211",
            "G0 X124",
            "G0 X128",
            "G2 I0.5 J0 F300",
            "G2 I0.5 J0 F300",
            "M109 S140 ; wait nozzle temp down to heatbed acceptable",
            "G2 I0.5 J0 F3000",
            "G2 I0.5 J0 F3000",
            "M221 R; pop softend status",
            "G1 Z10 F1200",
            "M400",
            "G1 Z10",
            "G1 F30000",
            "G1 X230 Y15",
            "G29.2 S1 ; turn on ABL",
            "M106 S0 ; turn off fan , too noisy",
            ";===== wipe nozzle end ================================",
        ]
        if s.enableBedLeveling {
            lines += [
                ";===== bed leveling ==================================",
                "M1002 gcode_claim_action : 1",
                "G29 A X\(fmt(box.x)) Y\(fmt(box.y)) I\(fmt(box.w)) J\(fmt(box.h))",
                "M400",
                "M500 ; save cali data",
            ]
        }
        lines += [
            "M975 S1 ; turn on vibration supression",
            "M104 S\(nozzle) ; set extrude temp earlier, to reduce wait time",
            ";===== nozzle load line ===============================",
            "M975 S1",
            "G90",
            "M83",
            "T1000",
            "G1 X18.0 Y1.0 Z0.8 F18000;Move to start position",
            "M109 S\(nozzle)",
            "G1 Z0.2",
            "G0 E2 F300",
            "G0 X240 E15 F6000",
            "G0 Y11 E0.700 F1500",
            "G0 X239.5",
            "G0 E0.2",
            "G0 Y1.5 E0.700",
            "G0 X18 E15 F6000",
            "M400",
        ]
        if s.plateType == .texturedPEI { lines.append("G29.1 Z-0.04 ; for Textured PEI Plate") }
        lines += [
            "M1002 gcode_claim_action : 0",
            "M106 S0 ; turn off fan",
            "M106 P2 S0 ; turn off big fan",
            "M106 P3 S0 ; turn off chamber fan",
            "M975 S1 ; turn on mech mode supression",
        ]
        return lines
    }

    func beforeLayer(_ layer: SlicedLayer, _ ctx: PrintContext) -> [String] {
        let total = max(ctx.layers.count, 1)
        let percent = min(99, Int(Double(layer.index) / Double(total) * 100))
        return ["; layer num/total_layer_count: \(layer.index + 1)/\(total)", "; update layer progress",
                "M73 P\(percent)", "M73 L\(layer.index + 1)", "M991 S0 P\(layer.index) ;notify layer change", "G92 E0"]
    }

    func afterLayer(_ layer: SlicedLayer, _ ctx: PrintContext) -> [String] {
        var lines = [";AFTER_LAYER_CHANGE"]
        if layer.index == 1 {
            let f = ctx.settings.filament(for: layer.islands.first?.tool ?? ctx.initialTool)
            lines.append("M104 S\(f.nozzleTemp)")
            lines.append("M140 S\(f.bedTemp(for: ctx.settings.plateType, firstLayer: false))")
        }
        return lines
    }

    func toolChange(from: Int, to: Int, layer: SlicedLayer, _ ctx: PrintContext) -> [String] {
        let next = ctx.settings.filament(for: to)
        let previous = ctx.settings.filament(for: from)
        let temp = layer.index == 0 ? next.firstLayerNozzleTemp : next.nozzleTemp
        let flushSpeed = Int(next.maxVolumetricSpeed / 2.4053 * 60)
        let flushTemp = next.type.uppercased().hasPrefix("PETG") ? 260 : max(temp, 250)
        return [
            "M620 S\(to)A",
            "M204 S9000",
            "G1 Z\(fmt(layer.z + 3)) F1200",
            "G1 X70 F21000",
            "G1 Y245",
            "G1 Y265 F3000",
            "M400",
            "M106 P1 S0",
            "M106 P2 S0",
            "M104 S\(max(previous.nozzleTemp, 143))",
            "M620.11 S0",
            "M400",
            "G1 X90 F3000",
            "G1 Y255 F4000",
            "G1 X100 F5000",
            "G1 X120 F15000",
            "G1 X20 Y50 F21000",
            "G1 Y-3",
            "T\(to)",
            "M620.1 E F\(flushSpeed) T\(flushTemp)",
            "G92 E0",
            "M83",
            "; FLUSH_START",
            "M400",
            "M109 S\(flushTemp)",
            "G1 E2 F\(flushSpeed) ;Compensate for filament spillage during waiting temperature",
            "; FLUSH_END",
            "M400",
            "M109 S\(temp)",
            "G92 E0",
            "M106 P1 S255",
            "M400 S3",
            "G1 X70 F5000",
            "G1 X90 F3000",
            "G1 Y255 F4000",
            "G1 X105 F5000",
            "G1 Y265 F5000",
            "G1 X70 F10000",
            "G1 X100 F5000",
            "G1 X70 F10000",
            "G1 X80 F15000",
            "G1 X60",
            "G1 X80",
            "G1 X100 F5000",
            "G1 X165 F15000; wipe and shake",
            "G1 Y256 ; move Y to aside, prevent collision",
            "M400",
            "G1 Z\(fmt(layer.z + 3)) F3000",
            "M621 S\(to)A",
        ]
    }

    func end(_ ctx: PrintContext) -> [String] {
        let maxZ = ctx.layers.last?.z ?? 0
        let top = ctx.settings.maxHeight
        var lines = [
            "M400 ; wait for buffer to clear",
            "G92 E0 ; zero the extruder",
            "G1 E-0.8 F1800 ; retract",
            "G1 Z\(fmt(min(maxZ + 0.5, top))) F900 ; lower z a little",
            "G1 X65 Y245 F12000 ; move to safe pos",
            "G1 Y265 F3000",
            "M140 S0 ; turn off bed",
            "M106 S0 ; turn off fan",
            "M106 P2 S0 ; turn off remote part cooling fan",
            "M106 P3 S0 ; turn off chamber cooling fan",
            "G1 X100 F12000 ; wipe",
            "; pull back filament to AMS",
            "M620 S255",
            "G1 X20 Y50 F12000",
            "G1 Y-3",
            "T255",
            "G1 X65 F12000",
            "G1 Y265",
            "G1 X100 F12000 ; wipe",
            "M621 S255",
            "M104 S0 ; turn off hotend",
            "M400 ; wait all motion done",
            "M17 S",
            "M17 Z0.4 ; lower z motor current to reduce impact if there is something in the bottom",
        ]
        if maxZ + 100 < top {
            lines += ["G1 Z\(fmt(maxZ + 100)) F600", "G1 Z\(fmt(maxZ + 98))"]
        } else {
            lines += ["G1 Z\(fmt(top)) F600", "G1 Z\(fmt(top - 2))"]
        }
        lines += [
            "M400 P100",
            "M17 R ; restore z current",
            "M220 S100  ; Reset feedrate magnitude",
            "M201.2 K1.0 ; Reset acc magnitude",
            "M73.2   R1.0 ;Reset left time magnitude",
            "M1002 set_gcode_claim_speed_level : 0",
            "M17 X0.8 Y0.8 Z0.5 ; lower motor current to 45% power",
        ]
        return lines
    }
}
