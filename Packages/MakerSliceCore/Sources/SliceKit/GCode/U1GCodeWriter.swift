import Foundation

public struct PrintEstimate: Sendable, Equatable {
    public var seconds: Double
    /// Filament length per tool in mm.
    public var filamentMM: [Int: Double]
    /// Filament weight per tool in g.
    public var filamentGrams: [Int: Double]
    public var layerCount: Int
    public var toolChanges: Int

    public var totalGrams: Double { filamentGrams.values.reduce(0, +) }

    public var formattedTime: String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(max(m, 1)) min"
    }
}

public struct GCodeResult: Sendable {
    public var gcode: String
    public var estimate: PrintEstimate
}

/// Emits Klipper G-code for the Snapmaker U1 (four-tool toolchanger), following
/// the start/tool-change/end sequences of the official U1 Orca profile.
public struct U1GCodeWriter {
    public let settings: PrintSettings
    public var appVersion = "0.1"

    public init(settings: PrintSettings) {
        self.settings = settings
    }

    private static let filamentArea = Double.pi * 0.875 * 0.875 // 1.75 mm filament

    public func write(layers: [SlicedLayer], jobName: String) -> GCodeResult {
        let s = settings
        var out = GCodeBuffer()
        var stats = MotionStats(acceleration: s.acceleration)

        let usedTools = Array(Set(layers.flatMap { $0.islands.map(\.tool) })).sorted()
        let initialTool = layers.first?.islands.first?.tool ?? 0
        let initialFilament = s.filament(for: initialTool)

        // Pass 1: body (so the header can carry estimates).
        var body = GCodeBuffer()
        var state = MachineState(tool: initialTool)
        var toolChanges = 0

        for layer in layers {
            let height = layer.height
            body.line(";LAYER_CHANGE")
            body.line(";Z:\(fmt(layer.z))")
            body.line(";HEIGHT:\(fmt(height))")
            body.line(";BEFORE_LAYER_CHANGE")
            body.line(";\(fmt(layer.z))")
            body.line("G92 E0")
            if s.enableTimelapse { body.line("TIMELAPSE_TAKE_FRAME") }
            body.line("DEFECT_DETECTION_DETECT")
            retract(&body, &state, &stats)
            moveZ(&body, &state, &stats, to: layer.z)
            body.line(";AFTER_LAYER_CHANGE")
            body.line(";\(fmt(layer.z))")
            body.line("SET_PRINT_STATS_INFO TOTAL_LAYER=\(layers.count) CURRENT_LAYER=\(layer.index + 1)")

            // Keep the current tool first to save a change per layer.
            let islands = layer.islands.sorted { a, b in
                if a.tool == state.tool { return b.tool != state.tool }
                if b.tool == state.tool { return false }
                return a.tool < b.tool
            }
            let layerTime = estimateLayerTime(islands, height: height)
            let slowdown = layerTime > 0 && layerTime < s.minLayerTime ? layerTime / s.minLayerTime : 1

            for island in islands {
                let filament = s.filament(for: island.tool)
                if island.tool != state.tool {
                    toolChange(&body, &state, &stats, to: island.tool, layer: layer, initialTool: initialTool)
                    toolChanges += 1
                }
                setFan(&body, &state, filament: filament, layerIndex: layer.index)
                for extrusion in island.extrusions {
                    guard extrusion.points.count >= 2 else { continue }
                    let start = extrusion.points[0]
                    travel(&body, &state, &stats, to: start, layerZ: layer.z)
                    if state.lastRole != extrusion.role {
                        body.line(";TYPE:\(extrusion.role.gcodeLabel)")
                        if extrusion.role == .outerWall {
                            body.line("SET_VELOCITY_LIMIT ACCEL=\(Int(s.outerWallAcceleration))")
                        } else if state.lastRole == .outerWall {
                            body.line("SET_VELOCITY_LIMIT ACCEL=\(Int(s.acceleration))")
                        }
                        state.lastRole = extrusion.role
                    }
                    body.line(";WIDTH:\(fmt(extrusion.width))")
                    unretract(&body, &state, &stats)

                    let maxSpeed = filament.maxVolumetricSpeed / (extrusion.width * height)
                    let speed = max(min(extrusion.speed, maxSpeed) * slowdown, 10)
                    let ePerMM = extrusionPerMM(width: extrusion.width, height: height, filament: filament)
                    var points = Array(extrusion.points.dropFirst())
                    if extrusion.closed { points.append(start) }
                    var feedSet = false
                    for p in points {
                        let dist = state.position.distance(to: p) / Units.perMM
                        guard dist > 0.001 else { continue }
                        let e = dist * ePerMM
                        if feedSet {
                            body.line("G1 X\(fmt(p.mmX)) Y\(fmt(p.mmY)) E\(fmt5(e))")
                        } else {
                            body.line("G1 X\(fmt(p.mmX)) Y\(fmt(p.mmY)) E\(fmt5(e)) F\(Int(speed * 60))")
                            feedSet = true
                        }
                        stats.move(dist, speed: speed)
                        state.position = p
                        state.filament[island.tool, default: 0] += e
                    }
                    if extrusion.closed, extrusion.role == .outerWall {
                        wipeInward(&body, &state, &stats, along: extrusion.points)
                    }
                }
            }
        }

        // Header with summary for Moonraker/Fluidd and the U1 screen.
        let filamentMM = state.filament
        let filamentGrams = filamentMM.reduce(into: [Int: Double]()) { acc, item in
            acc[item.key] = item.value * Self.filamentArea / 1000 * s.filament(for: item.key).density
        }
        let estimatedSeconds = stats.seconds + Double(toolChanges) * 12 + 300 // tool changes + calibration
        let estimate = PrintEstimate(seconds: estimatedSeconds, filamentMM: filamentMM, filamentGrams: filamentGrams,
                                     layerCount: layers.count, toolChanges: toolChanges)

        let firstLayerBox = layers.first?.outline.boundingBox
        out.line("; generated by MakerSlice \(appVersion) on \(Self.timestamp())")
        out.line("; job: \(jobName.replacingOccurrences(of: "\n", with: " "))")
        out.line("; printer_model = Snapmaker U1")
        out.line("; estimated printing time (normal mode) = \(Self.orcaDuration(estimatedSeconds))")
        out.line("; total layer count = \(layers.count)")
        out.line("; filament used [mm] = \(usedTools.map { fmt(filamentMM[$0] ?? 0) }.joined(separator: ","))")
        out.line("; filament used [g] = \(usedTools.map { fmt(filamentGrams[$0] ?? 0) }.joined(separator: ","))")
        out.line("; filament_type = \(usedTools.map { s.filament(for: $0).type }.joined(separator: ";"))")
        out.line("; layer_height = \(fmt(s.layerHeight))")
        out.line("; first_layer_height = \(fmt(s.firstLayerHeight))")
        out.line("; max_layer_z = \(fmt(layers.last?.z ?? 0))")
        out.line("; nozzle_diameter = \(fmt(s.nozzleDiameter))")
        out.line("; curr_bed_type = \(s.plateType.rawValue)")
        out.line("")
        out.append(startGCode(initialTool: initialTool, filament: initialFilament, firstLayerBox: firstLayerBox,
                              totalLayers: layers.count))
        out.line("M83")
        out.line("G90")
        out.append(body.text)
        out.append(endGCode(usedTools: usedTools, state: &state))
        return GCodeResult(gcode: out.text, estimate: estimate)
    }

    // MARK: - Motion helpers

    private func travel(_ g: inout GCodeBuffer, _ state: inout MachineState, _ stats: inout MotionStats,
                        to p: IntPoint, layerZ: Double) {
        let dist = state.position.distance(to: p) / Units.perMM
        guard dist > 0.001 else { return }
        let needsRetract = dist > settings.retractMinTravel
        if needsRetract {
            retract(&g, &state, &stats)
            if settings.zHop > 0 && !state.hopped {
                g.line("G1 Z\(fmt(layerZ + settings.zHop)) F\(Int(min(settings.travelSpeed, 20) * 60))")
                stats.move(settings.zHop, speed: 20)
                state.hopped = true
            }
        }
        g.line("G1 X\(fmt(p.mmX)) Y\(fmt(p.mmY)) F\(Int(settings.travelSpeed * 60))")
        stats.move(dist, speed: settings.travelSpeed)
        state.position = p
        if state.hopped {
            g.line("G1 Z\(fmt(layerZ)) F\(Int(20 * 60))")
            stats.move(settings.zHop, speed: 20)
            state.hopped = false
        }
    }

    private func retract(_ g: inout GCodeBuffer, _ state: inout MachineState, _ stats: inout MotionStats) {
        guard !state.retracted else { return }
        let length = settings.filament(for: state.tool).retractLength
        g.line("G1 E-\(fmt5(length)) F\(Int(settings.retractSpeed * 60))")
        stats.add(length / settings.retractSpeed)
        state.retracted = true
    }

    private func unretract(_ g: inout GCodeBuffer, _ state: inout MachineState, _ stats: inout MotionStats) {
        guard state.retracted else { return }
        let length = settings.filament(for: state.tool).retractLength
        g.line("G1 E\(fmt5(length)) F\(Int(settings.retractSpeed * 60))")
        stats.add(length / settings.retractSpeed)
        state.retracted = false
    }

    private func moveZ(_ g: inout GCodeBuffer, _ state: inout MachineState, _ stats: inout MotionStats, to z: Double) {
        g.line("G1 Z\(fmt(z)) F\(Int(20 * 60))")
        stats.move(abs(z - state.z), speed: 20)
        state.z = z
        state.hopped = false
    }

    /// Short travel along the start of the outer loop to hide the seam.
    private func wipeInward(_ g: inout GCodeBuffer, _ state: inout MachineState, _ stats: inout MotionStats, along loop: Path) {
        guard loop.count >= 2 else { return }
        retract(&g, &state, &stats)
        var remaining = 2.0 * Units.perMM
        var prev = state.position
        for p in loop.dropFirst() {
            let d = prev.distance(to: p)
            if d >= remaining {
                let f = remaining / d
                let target = IntPoint(prev.x + Int64(Double(p.x - prev.x) * f), prev.y + Int64(Double(p.y - prev.y) * f))
                g.line("G1 X\(fmt(target.mmX)) Y\(fmt(target.mmY)) F\(Int(settings.travelSpeed * 60))")
                state.position = target
                break
            }
            g.line("G1 X\(fmt(p.mmX)) Y\(fmt(p.mmY)) F\(Int(settings.travelSpeed * 60))")
            remaining -= d
            prev = p
            state.position = p
        }
        stats.move(2, speed: settings.travelSpeed)
    }

    private func setFan(_ g: inout GCodeBuffer, _ state: inout MachineState, filament: Filament, layerIndex: Int) {
        let target = layerIndex < filament.fanOffLayers ? 0 : Int((filament.fanSpeed * 255).rounded())
        guard target != state.fan else { return }
        g.line(target == 0 ? "M107" : "M106 S\(target)")
        state.fan = target
    }

    private func extrusionPerMM(width: Double, height: Double, filament: Filament) -> Double {
        // Cross-section of a squished line: rectangle with semicircular ends.
        let area = (width - height) * height + Double.pi * height * height / 4
        return area / Self.filamentArea * filament.flowRatio
    }

    private func estimateLayerTime(_ islands: [ToolIsland], height: Double) -> Double {
        var t = 0.0
        for island in islands {
            let filament = settings.filament(for: island.tool)
            for e in island.extrusions {
                let maxSpeed = filament.maxVolumetricSpeed / (e.width * height)
                t += e.lengthMM / max(min(e.speed, maxSpeed), 1)
            }
        }
        return t
    }

    // MARK: - U1 sequences (from the official Snapmaker U1 Orca profile)

    private func toolChange(_ g: inout GCodeBuffer, _ state: inout MachineState, _ stats: inout MotionStats,
                            to next: Int, layer: SlicedLayer, initialTool: Int) {
        let s = settings
        let filament = s.filament(for: next)
        retract(&g, &state, &stats)
        let speed = min(s.travelSpeed, 350)
        g.line("; Change Tool\(state.tool) -> Tool\(next) (layer \(layer.index))")
        g.line("G91")
        g.line("G1 Z1.5 F600")
        g.line("G90")
        g.line("G1 F\(Int(speed * 60))")
        let temp = layer.index == 0 ? filament.firstLayerNozzleTemp : filament.nozzleTemp
        g.line("M109 S\(temp) T\(next)")
        g.line("M400")
        g.line("T\(next)")
        if filament.type == "PVA" { g.line("SET_VELOCITY_LIMIT ACCEL=3000") }
        if next != initialTool { g.line("SM_PRINT_PREEXTRUDE_FILAMENT INDEX=\(next)") }
        g.line("G90")
        g.line("M83")
        g.line("G92 E0")
        state.tool = next
        // The macro parks the tool; we don't know where, so force a full move back.
        state.position = IntPoint(Int64.min / 4, Int64.min / 4)
        state.retracted = false
        state.lastRole = nil
        state.fan = -1
        g.line("G1 Z\(fmt(layer.z + 1.5)) F600")
        state.z = layer.z + 1.5
        state.hopped = true
        stats.add(30)
    }

    private func startGCode(initialTool t: Int, filament f: Filament, firstLayerBox: (min: IntPoint, max: IntPoint)?,
                            totalLayers: Int) -> String {
        let s = settings
        let bed = f.firstLayerBedTemp
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
        let zOffset = highTemp ? " Z_OFFSET -0.07" : ""
        let bedMesh = bedMeshCommand(firstLayerBox: firstLayerBox, zOffset: highTemp ? " Z_OFFSET=-0.07" : "")

        var lines: [String] = []
        lines.append("SET_PRINT_AUTO_BED_LEVELING ENABLE=\(s.enableBedLeveling ? 1 : 0)")
        lines.append("SET_TIME_LAPSE_CAMERA ENABLE=\(s.enableTimelapse ? 1 : 0)")
        lines.append("PRINT_START")
        lines.append("DEFECT_DETECTION_START")
        lines.append("SET_PRINT_STATS_INFO TOTAL_LAYER=\(totalLayers) CURRENT_LAYER=0")
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
            "G28 Z\(zOffset)",
            ";===== bed leveling =====",
            "M107",
            bedMesh,
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
        return lines.joined(separator: "\n") + "\n"
    }

    /// Adaptive bed mesh limited to the first-layer footprint, like Orca does.
    private func bedMeshCommand(firstLayerBox: (min: IntPoint, max: IntPoint)?, zOffset: String) -> String {
        let margin = 5.0
        var minX = 3.0, minY = 3.0, maxX = 267.0, maxY = 267.0
        if let box = firstLayerBox {
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

    private func endGCode(usedTools: [Int], state: inout MachineState) -> String {
        var lines: [String] = []
        if !state.retracted {
            lines.append("G1 E-\(fmt5(settings.filament(for: state.tool).retractLength)) F\(Int(settings.retractSpeed * 60))")
        }
        lines.append("M107")
        lines.append("PRINT_END")
        if settings.enableTimelapse { lines.append("TIMELAPSE_STOP") }
        lines.append("; U1 nozzle flow metadata, in logical filament order")
        lines.append("; filament_volume_type = " + usedTools.map { _ in "standard" }.joined(separator: ","))
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Formatting

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH:mm:ss"
        return f.string(from: Date())
    }

    static func orcaDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d)d") }
        if h > 0 || d > 0 { parts.append("\(h)h") }
        if m > 0 || h > 0 || d > 0 { parts.append("\(m)m") }
        parts.append("\(s)s")
        return parts.joined(separator: " ")
    }
}

private struct MachineState {
    var tool: Int
    var position = IntPoint(0, 0)
    var z = 0.0
    var retracted = true // the prime line ends retracted-equivalent; first unretract primes
    var hopped = false
    var fan = -1
    var lastRole: ExtrusionRole?
    var filament: [Int: Double] = [:]
}

/// Rough time estimate using trapezoidal acceleration.
private struct MotionStats {
    let acceleration: Double
    var seconds = 0.0

    mutating func move(_ distance: Double, speed: Double) {
        guard distance > 0, speed > 0 else { return }
        let accelDist = speed * speed / acceleration
        if distance >= accelDist {
            seconds += distance / speed + speed / acceleration
        } else {
            seconds += 2 * (distance / acceleration).squareRoot()
        }
    }

    mutating func add(_ s: Double) { seconds += s }
}

struct GCodeBuffer {
    private(set) var text = ""

    init() {
        text.reserveCapacity(1 << 20)
    }

    mutating func line(_ s: String) {
        text += s
        text += "\n"
    }

    mutating func append(_ s: String) { text += s }
}

@inline(__always) func fmt(_ v: Double) -> String {
    formatDecimal(v, digits: 3)
}

@inline(__always) func fmt5(_ v: Double) -> String {
    formatDecimal(v, digits: 5)
}

/// Fast fixed-point formatting without trailing zeros (String(format:) is slow).
func formatDecimal(_ value: Double, digits: Int) -> String {
    var scale = 1.0
    for _ in 0..<digits { scale *= 10 }
    var scaled = (abs(value) * scale).rounded()
    if !scaled.isFinite { return "0" }
    let negative = value < 0 && scaled != 0
    let intScale = Int64(scale)
    let n = Int64(scaled)
    scaled = 0
    let whole = n / intScale
    var frac = n % intScale
    var result = negative ? "-" : ""
    result += String(whole)
    if frac != 0 {
        var width = digits
        while frac % 10 == 0 { frac /= 10; width -= 1 }
        let fracString = String(frac)
        result += "." + String(repeating: "0", count: width - fracString.count) + fracString
    }
    return result
}
