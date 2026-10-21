import Foundation

/// Reads G-code (from MakerSlice, OrcaSlicer or Bambu/Anycubic slicers) back into layers for the
/// preview, plus the estimate written in its comments.
public enum GCodePreview {
    static let roles: [String: ExtrusionRole] = {
        var map: [String: ExtrusionRole] = [:]
        for role in ExtrusionRole.allCases { map[role.gcodeLabel.lowercased()] = role }
        map["overhang wall"] = .outerWall
        map["external perimeter"] = .outerWall
        map["perimeter"] = .innerWall
        map["internal infill"] = .sparseInfill
        map["solid infill"] = .solidInfill
        map["gap infill"] = .solidInfill
        map["internal bridge"] = .bridge
        map["bridge infill"] = .bridge
        map["support transition"] = .supportInterface
        map["wipe tower"] = .primeTower
        return map
    }()

    public static func parse(_ gcode: String) -> (layers: [SlicedLayer], estimate: PrintEstimate) {
        var layers: [SlicedLayer] = []
        var islands: [ToolIsland] = []
        var layerZ = 0.0, layerHeight = 0.2
        var tool = 0, role = ExtrusionRole.innerWall, width = 0.45
        var x = 0.0, y = 0.0, e = 0.0
        var relativeXY = false, relativeE = false
        var path: Path = []
        var toolsUsed = Set<Int>()
        var toolChanges = 0
        var meta: [String: String] = [:]
        var pending = false // any extrusion in the current layer
        var started = false // start-G-code purge lines are not part of the print

        func flushPath() {
            guard path.count >= 2 else { path.removeAll(keepingCapacity: true); return }
            let ext = Extrusion(role: role, points: path, closed: false, width: width, speed: 0)
            if let last = islands.indices.last, islands[last].tool == tool {
                islands[last].extrusions.append(ext)
            } else {
                islands.append(ToolIsland(tool: tool, extrusions: [ext]))
            }
            path.removeAll(keepingCapacity: true)
            pending = true
        }
        func flushLayer() {
            flushPath()
            guard pending else { return }
            layers.append(SlicedLayer(index: layers.count, z: layerZ, height: layerHeight, islands: islands, outline: Polygons()))
            islands = []
            pending = false
        }

        gcode.enumerateLines { raw, _ in
            var line = Substring(raw)
            if line.hasPrefix(";") {
                let c = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if c == "LAYER_CHANGE" || c.hasPrefix("CHANGE_LAYER") {
                    flushLayer()
                    started = true
                } else if c.hasPrefix("Z:"), let v = Double(c.dropFirst(2)) {
                    layerZ = v
                } else if c.hasPrefix("HEIGHT:"), let v = Double(c.dropFirst(7)) {
                    layerHeight = v
                } else if c.hasPrefix("TYPE:") {
                    flushPath()
                    role = roles[c.dropFirst(5).lowercased()] ?? .innerWall
                } else if c.hasPrefix("WIDTH:"), let v = Double(c.dropFirst(6)) {
                    if abs(v - width) > 1e-6 { flushPath() }
                    width = v
                } else if let eq = c.range(of: " = ") {
                    let key = String(c[..<eq.lowerBound])
                    if key.hasPrefix("estimated printing time") || key.hasPrefix("filament used") || key.hasPrefix("total filament") {
                        meta[key] = String(c[eq.upperBound...])
                    }
                }
                return
            }
            if let semicolon = line.firstIndex(of: ";") { line = line[..<semicolon] }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let head = parts.first else { return }
            switch head {
            case "G0", "G1", "G2", "G3":
                var nx = x, ny = y, de = 0.0, hasE = false
                for p in parts.dropFirst() {
                    guard let letter = p.first, let v = Double(p.dropFirst()) else { continue }
                    switch letter {
                    case "X": nx = relativeXY ? x + v : v
                    case "Y": ny = relativeXY ? y + v : v
                    case "E":
                        hasE = true
                        de = relativeE ? v : v - e
                        e = relativeE ? e : v
                    default: break
                    }
                }
                let moved = nx != x || ny != y
                if moved && hasE && de > 0 && started {
                    if path.isEmpty { path.append(IntPoint(mmX: x, mmY: y)) }
                    path.append(IntPoint(mmX: nx, mmY: ny))
                } else if moved {
                    flushPath()
                }
                x = nx; y = ny
            case "G90": relativeXY = false
            case "G91": relativeXY = true
            case "M82": relativeE = false
            case "M83": relativeE = true
            case "G92":
                for p in parts.dropFirst() where p.first == "E" { e = Double(p.dropFirst()) ?? 0 }
            default:
                if head.first == "T", let t = Int(head.dropFirst()), t < 16 {
                    flushPath()
                    if t != tool, !toolsUsed.isEmpty { toolChanges += 1 }
                    tool = t
                    toolsUsed.insert(t)
                }
            }
        }
        flushLayer()

        let seconds = duration(meta.first { $0.key.hasPrefix("estimated printing time") }?.value)
        func perTool(_ key: String) -> [Int: Double] {
            guard let value = meta[key] else { return [:] }
            let numbers = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            var result: [Int: Double] = [:]
            for (i, n) in numbers.enumerated() where n > 0 { result[i] = n }
            return result
        }
        let estimate = PrintEstimate(seconds: seconds ?? 0, filamentMM: perTool("filament used [mm]"),
                                     filamentGrams: perTool("filament used [g]"), layerCount: layers.count,
                                     toolChanges: toolChanges)
        return (layers, estimate)
    }

    /// "1d 2h 3m 4s" → seconds.
    static func duration(_ text: String?) -> Double? {
        guard let text else { return nil }
        var total = 0.0, number = ""
        for ch in text {
            if ch.isNumber { number.append(ch); continue }
            if let n = Double(number) {
                switch ch {
                case "d": total += n * 86400
                case "h": total += n * 3600
                case "m": total += n * 60
                case "s": total += n
                default: break
                }
            }
            number = ""
        }
        return total > 0 ? total : nil
    }
}
