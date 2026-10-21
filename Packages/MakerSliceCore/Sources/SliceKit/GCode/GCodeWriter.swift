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

/// Facts about a print that the machine dialects need.
struct PrintContext {
    var settings: PrintSettings
    var layers: [SlicedLayer]
    var usedTools: [Int]
    var initialTool: Int
    var firstLayerBox: (min: IntPoint, max: IntPoint)?
    var jobName: String

    var initialFilament: Filament { settings.filament(for: initialTool) }
}

/// Printer-specific G-code fragments (start, tool change, layer change, end).
protocol MachineDialect {
    func header(_ ctx: PrintContext) -> [String]
    func start(_ ctx: PrintContext) -> [String]
    func beforeLayer(_ layer: SlicedLayer, _ ctx: PrintContext) -> [String]
    func afterLayer(_ layer: SlicedLayer, _ ctx: PrintContext) -> [String]
    /// Lines that switch from `from` to `to`; the writer handles retraction before and travel after.
    func toolChange(from: Int, to: Int, layer: SlicedLayer, _ ctx: PrintContext) -> [String]
    /// Rough duration of a tool change in seconds (for the estimate).
    var toolChangeSeconds: Double { get }
    /// Seconds spent on homing, calibration and heating before the first layer.
    var preparationSeconds: Double { get }
    /// Preview images the printer's screen shows (sizes from the official profile).
    var thumbnailSizes: [(width: Int, height: Int)] { get }
    func end(_ ctx: PrintContext) -> [String]
}

/// Emits Klipper G-code for the selected printer. The machine-specific parts
/// follow the official OrcaSlicer profiles of the Snapmaker U1 and Anycubic Kobra S1.
public struct GCodeWriter {
    public let settings: PrintSettings
    public var appVersion = "0.3"
    /// G-code format version written in the header. Moonraker (and the printers' screens) only read
    /// time, filament and thumbnails from slicers they know, so the file follows OrcaSlicer's layout.
    static let orcaFormatVersion = "2.4.0"

    public init(settings: PrintSettings) {
        self.settings = settings
    }

    private var dialect: MachineDialect {
        switch settings.printer {
        case .snapmakerU1: return U1Dialect()
        case .kobraS1: return KobraS1Dialect()
        }
    }

    static let filamentArea = Double.pi * 0.875 * 0.875 // 1.75 mm filament

    /// - Parameter objects: used to render the preview images for the printer screen.
    public func write(layers: [SlicedLayer], jobName: String, objects: [ModelObject] = []) -> GCodeResult {
        let s = settings
        let dialect = self.dialect
        var out = GCodeBuffer()
        var stats = MotionStats(acceleration: s.acceleration)

        let usedTools = Array(Set(layers.flatMap { $0.islands.map(\.tool) })).sorted()
        let initialTool = layers.first?.islands.first?.tool ?? 0
        let ctx = PrintContext(settings: s, layers: layers, usedTools: usedTools, initialTool: initialTool,
                               firstLayerBox: layers.first?.outline.boundingBox, jobName: jobName)
        let minLayerTime = s.minLayerTime(for: usedTools)

        // Pass 1: body (so the header can carry estimates).
        var body = GCodeBuffer()
        var state = MachineState(tool: initialTool)
        var toolChanges = 0
        if let pa = s.filament(for: initialTool).pressureAdvance {
            body.line("SET_PRESSURE_ADVANCE ADVANCE=\(fmt5(pa))")
        }

        for layer in layers {
            let height = layer.height
            body.line(";LAYER_CHANGE")
            body.line(";Z:\(fmt(layer.z))")
            body.line(";HEIGHT:\(fmt(height))")
            dialect.beforeLayer(layer, ctx).forEach { body.line($0) }
            // Spiral layers rise during the wall itself – no retract, no separate Z move.
            let spiralFromZ = layer.isSpiral ? state.z : nil
            if !layer.isSpiral {
                retract(&body, &state, &stats)
                moveZ(&body, &state, &stats, to: layer.z)
            }
            dialect.afterLayer(layer, ctx).forEach { body.line($0) }

            let layerTime = estimateLayerTime(layer.islands, height: height)
            let slowdown = layerTime > 0 && layerTime < minLayerTime ? layerTime / minLayerTime : 1

            for island in layer.islands {
                let filament = s.filament(for: island.tool)
                if island.tool != state.tool {
                    retract(&body, &state, &stats)
                    dialect.toolChange(from: state.tool, to: island.tool, layer: layer, ctx).forEach { body.line($0) }
                    body.line("M83")
                    body.line("G92 E0")
                    if let pa = filament.pressureAdvance { body.line("SET_PRESSURE_ADVANCE ADVANCE=\(fmt5(pa))") }
                    toolChanges += 1
                    stats.add(dialect.toolChangeSeconds)
                    state.tool = island.tool
                    // The tool change parks the head somewhere; force a full move back.
                    state.position = IntPoint(Int64.min / 4, Int64.min / 4)
                    state.retracted = false
                    state.lastRole = nil
                    state.fan = -1
                    body.line("G1 Z\(fmt(layer.z + 1.5)) F600")
                    state.z = layer.z + 1.5
                    state.hopped = true
                }
                setFan(&body, &state, filament: filament, layerIndex: layer.index, role: nil)
                for extrusion in island.extrusions {
                    guard extrusion.points.count >= 2 else { continue }
                    let start = extrusion.points[0]
                    if spiralFromZ != nil {
                        // Short hop to the next loop's start while staying in the vase wall.
                        if state.position.distance(to: start) / Units.perMM > 0.001 {
                            body.line("G1 X\(fmt(start.mmX)) Y\(fmt(start.mmY)) F\(Int(settings.travelSpeed * 60))")
                            stats.move(state.position.distance(to: start) / Units.perMM, speed: settings.travelSpeed)
                            state.position = start
                        }
                    } else {
                        travel(&body, &state, &stats, to: start, layerZ: layer.z)
                    }
                    if state.lastRole != extrusion.role {
                        body.line(";TYPE:\(extrusion.role.gcodeLabel)")
                        if extrusion.role == .outerWall {
                            body.line("SET_VELOCITY_LIMIT ACCEL=\(Int(s.outerWallAcceleration))")
                        } else if state.lastRole == .outerWall {
                            body.line("SET_VELOCITY_LIMIT ACCEL=\(Int(s.acceleration))")
                        }
                        setFan(&body, &state, filament: filament, layerIndex: layer.index, role: extrusion.role)
                        state.lastRole = extrusion.role
                    }
                    body.line(";WIDTH:\(fmt(extrusion.width))")
                    unretract(&body, &state, &stats)

                    let flow = extrusion.flow
                    let maxSpeed = filament.maxVolumetricSpeed / (extrusion.width * height * max(flow, 0.05))
                    let roleSlowdown = extrusion.role == .bridge || extrusion.role == .ironing ? 1 : slowdown
                    let speed = max(min(extrusion.speed, maxSpeed) * roleSlowdown, 5)
                    let ePerMM = extrusionPerMM(width: extrusion.width, height: height, filament: filament) * flow
                    var points = Array(extrusion.points.dropFirst())
                    if extrusion.closed { points.append(start) }
                    var feedSet = false
                    // Spiral vase: Z climbs linearly with the distance along the loop.
                    let spiralLength = spiralFromZ != nil ? max(extrusion.lengthMM, 0.001) : 0
                    var travelled = 0.0
                    for p in points {
                        let dist = state.position.distance(to: p) / Units.perMM
                        guard dist > 0.001 else { continue }
                        let e = dist * ePerMM
                        var zPart = ""
                        if let fromZ = spiralFromZ {
                            travelled += dist
                            let z = fromZ + (layer.z - fromZ) * min(travelled / spiralLength, 1)
                            zPart = " Z\(fmt(z))"
                            state.z = z
                        }
                        if feedSet {
                            body.line("G1 X\(fmt(p.mmX)) Y\(fmt(p.mmY))\(zPart) E\(fmt5(e))")
                        } else {
                            body.line("G1 X\(fmt(p.mmX)) Y\(fmt(p.mmY))\(zPart) E\(fmt5(e)) F\(Int(speed * 60))")
                            feedSet = true
                        }
                        stats.move(dist, speed: speed)
                        state.position = p
                        state.filament[island.tool, default: 0] += e
                    }
                    if extrusion.closed, extrusion.role == .outerWall, spiralFromZ == nil {
                        wipeInward(&body, &state, &stats, along: extrusion.points)
                    }
                }
            }
        }

        // Header with summary for Moonraker/Fluidd and the printer screen.
        let filamentMM = state.filament
        let filamentGrams = filamentMM.reduce(into: [Int: Double]()) { acc, item in
            acc[item.key] = item.value * Self.filamentArea / 1000 * s.filament(for: item.key).density
        }
        let estimatedSeconds = stats.seconds + dialect.preparationSeconds
        let estimate = PrintEstimate(seconds: estimatedSeconds, filamentMM: filamentMM, filamentGrams: filamentGrams,
                                     layerCount: layers.count, toolChanges: toolChanges)

        let slots = Array(0..<max(s.machine.toolCount, (usedTools.max() ?? 0) + 1))
        func perSlot(_ value: (Int) -> String, _ separator: String = ",") -> String {
            slots.map(value).joined(separator: separator)
        }
        let totalGrams = filamentGrams.values.reduce(0, +)

        out.line("; HEADER_BLOCK_START")
        out.line("; generated by MakerSlice \(appVersion) (G-code format of OrcaSlicer \(Self.orcaFormatVersion) on \(Self.timestamp()))")
        out.line("; job: \(jobName.replacingOccurrences(of: "\n", with: " "))")
        out.line("; total layer number: \(layers.count)")
        out.line("; estimated printing time (normal mode) = \(Self.orcaDuration(estimatedSeconds))")
        out.line("; HEADER_BLOCK_END")
        out.line("")
        if !objects.isEmpty {
            let images = dialect.thumbnailSizes.compactMap { size -> (width: Int, height: Int, png: Data)? in
                Thumbnail.render(objects, filaments: s.filaments, width: size.width, height: size.height)
                    .map { (size.width, size.height, $0) }
            }
            Thumbnail.gcodeBlock(images).forEach { out.line($0) }
            out.line("")
        }
        out.line("; printer_model = \(s.printer.displayName)")
        out.line("; total layer count = \(layers.count)")
        out.line("; filament used [mm] = \(perSlot { fmt(filamentMM[$0] ?? 0) })")
        out.line("; filament used [g] = \(perSlot { fmt(filamentGrams[$0] ?? 0) })")
        out.line("; filament_type = \(perSlot({ s.filament(for: $0).type }, ";"))")
        out.line("; filament_colour = \(perSlot({ s.filament(for: $0).color }, ";"))")
        out.line("; layer_height = \(fmt(s.layerHeight))")
        out.line("; first_layer_height = \(fmt(s.firstLayerHeight))")
        out.line("; max_layer_z = \(fmt(layers.last?.z ?? 0))")
        out.line("; nozzle_diameter = \(fmt(s.nozzleDiameter))")
        dialect.header(ctx).forEach { out.line($0) }
        out.line("")
        dialect.start(ctx).forEach { out.line($0) }
        out.line("M83")
        out.line("G90")
        out.append(body.text)
        if !state.retracted {
            out.line("G1 E-\(fmt5(s.filament(for: state.tool).retractLength)) F\(Int(s.retractSpeed * 60))")
        }
        dialect.end(ctx).forEach { out.line($0) }

        // Trailer in OrcaSlicer's layout: Moonraker reads time, filament and temperatures from here.
        out.line("; EXECUTABLE_BLOCK_END")
        out.line("")
        out.line("; filament used [mm] = \(perSlot { fmt(filamentMM[$0] ?? 0) })")
        out.line("; filament used [cm3] = \(perSlot { fmt((filamentMM[$0] ?? 0) * Self.filamentArea / 1000) })")
        out.line("; filament used [g] = \(perSlot { fmt(filamentGrams[$0] ?? 0) })")
        out.line("; total filament used [g] = \(fmt(totalGrams))")
        out.line("; total layers count = \(layers.count)")
        out.line("; estimated printing time (normal mode) = \(Self.orcaDuration(estimatedSeconds))")
        out.line("")
        out.line("; CONFIG_BLOCK_START")
        out.line("; curr_bed_type = \(s.plateType.rawValue)")
        out.line("; filament_colour = \(perSlot({ s.filament(for: $0).color }, ";"))")
        out.line("; filament_diameter = \(perSlot { _ in "1.75" })")
        out.line("; filament_flow_ratio = \(perSlot { fmt(s.filament(for: $0).flowRatio) })")
        out.line("; filament_max_volumetric_speed = \(perSlot { fmt(s.filament(for: $0).maxVolumetricSpeed) })")
        out.line("; filament_settings_id = \(perSlot({ "\"\(s.filament(for: $0).name)\"" }, ";"))")
        out.line("; filament_type = \(perSlot({ s.filament(for: $0).type }, ";"))")
        out.line("; first_layer_bed_temperature = \(perSlot { "\(s.filament(for: $0).bedTemp(for: s.plateType, firstLayer: true))" })")
        out.line("; first_layer_height = \(fmt(s.firstLayerHeight))")
        out.line("; first_layer_temperature = \(perSlot { "\(s.filament(for: $0).firstLayerNozzleTemp)" })")
        out.line("; layer_height = \(fmt(s.layerHeight))")
        out.line("; line_width = \(fmt(s.lineWidth))")
        out.line("; nozzle_diameter = \(perSlot { _ in fmt(s.nozzleDiameter) })")
        out.line("; nozzle_temperature = \(perSlot { "\(s.filament(for: $0).nozzleTemp)" })")
        out.line("; outer_wall_acceleration = \(Int(s.outerWallAcceleration))")
        out.line("; outer_wall_speed = \(fmt(s.outerWallSpeed))")
        out.line("; printer_model = \(s.printer.displayName)")
        out.line("; sparse_infill_density = \(Int((s.infillDensity * 100).rounded()))%")
        out.line("; CONFIG_BLOCK_END")
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
                g.line("G1 Z\(fmt(layerZ + settings.zHop)) F\(Int(20 * 60))")
                stats.move(settings.zHop, speed: 20)
                state.hopped = true
            }
        }
        g.line("G1 X\(fmt(p.mmX)) Y\(fmt(p.mmY)) F\(Int(settings.travelSpeed * 60))")
        stats.move(min(dist, 400), speed: settings.travelSpeed)
        state.position = p
        if state.hopped {
            g.line("G1 Z\(fmt(layerZ)) F\(Int(20 * 60))")
            stats.move(settings.zHop, speed: 20)
            state.hopped = false
            state.z = layerZ
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

    /// Part cooling: off for the first layers, full for bridges/overhangs, filament default otherwise.
    private func setFan(_ g: inout GCodeBuffer, _ state: inout MachineState, filament: Filament, layerIndex: Int, role: ExtrusionRole?) {
        var speed = layerIndex < filament.fanOffLayers ? 0 : filament.fanSpeed
        if layerIndex > 0, role == .bridge { speed = max(speed, filament.overhangFanSpeed) }
        let target = Int((speed * 255).rounded())
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
                let maxSpeed = filament.maxVolumetricSpeed / (e.width * height * max(e.flow, 0.05))
                t += e.lengthMM / max(min(e.speed, maxSpeed), 1)
            }
        }
        return t
    }

    // MARK: - Formatting

    static func timestamp() -> String {
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
    var retracted = true // the first unretract primes the nozzle
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
    let scaled = (abs(value) * scale).rounded()
    if !scaled.isFinite { return "0" }
    let negative = value < 0 && scaled != 0
    let intScale = Int64(scale)
    let n = Int64(scaled)
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
