import Foundation

/// Purge ("wipe") tower for printers with one nozzle and a filament switcher
/// (Anycubic Kobra S1 + ACE Pro). After every filament change the new material
/// is primed on a dense strip of the tower; layers without a change get a
/// sparse fill so the tower keeps growing evenly.
struct PrimeTower {
    let settings: PrintSettings

    enum TowerError: Error, LocalizedError {
        case noSpace
        var errorDescription: String? {
            "Kein Platz für den Reinigungsturm. Rücke die Objekte zusammen oder schalte den Turm in den Experten-Einstellungen ab."
        }
    }

    func insert(into layers: inout [SlicedLayer], footprint: [Polygons]) throws {
        guard let lastChange = lastChangeLayer(layers) else { return }
        let rect = try placement(footprint: footprint, size: fittedSize(layers, lastChange: lastChange))
        let w = settings.lineWidth
        var previousTool = layers.first?.islands.first?.tool
        // Materials that do not weld to each other (PLA on PETG, …) would split the tower at every change. Then one
        // material builds the frame: walls and fill on every layer it prints, the others only purge inside it.
        let frameTool = frameTool(layers, lastChange: lastChange)

        for i in 0...lastChange {
            let height = layers[i].height
            let first = i == 0
            let width = first ? settings.firstLayerLineWidth : w
            let speed = first ? settings.firstLayerSpeed : min(settings.solidInfillSpeed, 150)
            let islands = layers[i].islands
            guard !islands.isEmpty else { continue }

            // Islands that start right after a filament change.
            var changeIslands: [Int] = []
            for (j, island) in islands.enumerated() {
                let before = j == 0 ? previousTool : islands[j - 1].tool
                if before != nil && before != island.tool { changeIslands.append(j) }
            }
            previousTool = islands.last?.tool

            let outer = Polygons.rectangle(minX: rect.minX, minY: rect.minY, maxX: rect.maxX, maxY: rect.maxY)
            // The island that prints walls and fill: the frame material when it prints on this layer.
            let frameIsland = frameTool.flatMap { tool in islands.firstIndex { $0.tool == tool } }
            let walls = frameTool == nil ? 1 : 2
            var frame: [Extrusion] = (0..<walls).compactMap { k in
                outer.offset(-width * (Double(k) + 0.5)).paths.first.map {
                    Extrusion(role: .primeTower, points: $0, closed: true, width: width, speed: speed)
                }
            }
            if first {
                // A few brim loops keep a slim tower on the bed.
                frame += (0..<4).compactMap { k in
                    outer.offset(width * (Double(k) + 0.5), join: .round).paths.first.map {
                        Extrusion(role: .primeTower, points: $0, closed: true, width: width, speed: speed)
                    }
                }
            }
            let inner = outer.offset(-width * Double(walls))
            let gen = LayerToolpathGenerator(settings: settings, layerIndex: i, z: layers[i].z, height: height)
            let angle = i % 2 == 0 ? 45.0 : 135.0

            var additions: [Int: [Extrusion]] = [:]
            // Light fill that keeps the tower growing (dense on the first layer for adhesion).
            func fill(_ area: Polygons) -> [Extrusion] {
                gen.lines(in: area, angle: angle, spacing: first ? width : 3, phase: 0).map {
                    Extrusion(role: .primeTower, points: $0, closed: false, width: width, speed: speed)
                }
            }
            if changeIslands.isEmpty {
                frame += fill(inner)
            } else {
                let strips = changeIslands.count
                var stripDepth = (rect.maxY - rect.minY) / Double(strips)
                if settings.purgeVolume > 0 {
                    // Depth of a fully filled strip that holds the purge volume (volume = width × depth × layer height).
                    let wanted = settings.purgeVolume / max((rect.maxX - rect.minX - 2 * width) * height, 0.01)
                    stripDepth = min(stripDepth, max(wanted, 2 * width))
                }
                for (k, j) in changeIslands.enumerated() {
                    let y0 = rect.minY + Double(k) * stripDepth
                    let strip = inner.intersection(Polygons.rectangle(minX: rect.minX, minY: y0,
                                                                      maxX: rect.maxX, maxY: y0 + stripDepth))
                    additions[j, default: []] += gen.lines(in: strip, angle: angle, spacing: width, phase: 0).map {
                        Extrusion(role: .primeTower, points: $0, closed: false, width: width, speed: speed)
                    }
                }
                if frameIsland != nil {
                    // The frame material also fills what the purge strips leave free, so its layers stay connected.
                    let y0 = rect.minY + Double(strips) * stripDepth
                    frame += fill(inner.intersection(Polygons.rectangle(minX: rect.minX, minY: y0, maxX: rect.maxX, maxY: rect.maxY)))
                }
            }
            // Purge strips first (they prime the nozzle), then walls and fill.
            additions[frameIsland ?? 0, default: []] += frame
            for (j, extra) in additions {
                layers[i].islands[j].extrusions.insert(contentsOf: extra, at: 0)
            }
        }
    }

    /// Materials that weld to each other share a group.
    static func bondGroup(_ type: String) -> String {
        let t = type.uppercased()
        let groups = [("PLA", "PLA"), ("PETG", "PETG"), ("PCTG", "PETG"), ("PET", "PETG"), ("ABS", "ABS"), ("ASA", "ABS"),
                      ("TPU", "TPU"), ("TPE", "TPU"), ("PVA", "PVA"), ("PA", "PA"), ("PC", "PC")]
        return groups.first { t.hasPrefix($0.0) }?.1 ?? t
    }

    /// True when the filaments of `tools` do not all weld to each other.
    static func mixesMaterials(_ tools: Set<Int>, settings: PrintSettings) -> Bool {
        Set(tools.map { bondGroup(settings.filament(for: $0).type) }).count > 1
    }

    /// With materials that do not bond: the tool that prints on most layers builds the frame of the tower.
    func frameTool(_ layers: [SlicedLayer], lastChange: Int) -> Int? {
        var count: [Int: Int] = [:]
        for layer in layers[...lastChange] {
            for tool in Set(layer.islands.map(\.tool)) { count[tool, default: 0] += 1 }
        }
        guard PrimeTower.mixesMaterials(Set(count.keys), settings: settings) else { return nil }
        return count.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
    }

    /// Side of the tower: just large enough for the purge strips of the busiest layer. `primeTowerWidth` is the upper
    /// limit; a tall tower keeps a wider base so it does not get knocked over (about an eighth of its height).
    func fittedSize(_ layers: [SlicedLayer], lastChange: Int) -> Double {
        let limit = max(10, settings.primeTowerWidth)
        guard settings.purgeVolume > 0 else { return limit }   // "default dense strip" fills the whole tower
        var previous = layers.first?.islands.first?.tool
        var mostChanges = 1
        var thinnest = Double.greatestFiniteMagnitude
        for layer in layers[...lastChange] where !layer.islands.isEmpty {
            var changes = 0
            for island in layer.islands {
                if let p = previous, p != island.tool { changes += 1 }
                previous = island.tool
            }
            mostChanges = max(mostChanges, changes)
            thinnest = min(thinnest, layer.height)
        }
        let area = Double(mostChanges) * settings.purgeVolume / max(thinnest, 0.04)
        let mixed = frameTool(layers, lastChange: lastChange) != nil
        // With a frame material: second wall, and a third of the tower stays free for its fill.
        let needed = (mixed ? (area * 1.5).squareRoot() + 4 * settings.lineWidth : area.squareRoot() + 2 * settings.lineWidth) + 1
        let stable = max(mixed ? 14 : 10, layers[lastChange].z * (mixed ? 0.16 : 0.12))
        return min(limit, max(needed, stable))
    }

    /// Last layer on which the filament changes (the tower only needs to reach it).
    func lastChangeLayer(_ layers: [SlicedLayer]) -> Int? {
        var last: Int?
        var previous = layers.first?.islands.first?.tool
        for (i, layer) in layers.enumerated() {
            for island in layer.islands {
                if let p = previous, p != island.tool { last = i }
                previous = island.tool
            }
        }
        return last
    }

    /// Picks a free bed corner for the tower.
    func placement(footprint: [Polygons], size: Double? = nil) throws -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let size = size ?? max(10, settings.primeTowerWidth)
        let bed = settings.bedSize
        let margin = 8.0
        var used = Polygons()
        for (i, layer) in footprint.enumerated() where i % 4 == 0 || i == footprint.count - 1 {
            if !layer.isEmpty { used = (used + layer).union() }
        }
        let keepOut = used.offset(settings.brimWidth + settings.skirtDistance + 6, join: .round)
        let candidates = [
            (bed - margin - size, bed - margin - size), (margin, bed - margin - size),
            (bed - margin - size, margin), (margin, margin),
        ]
        for (x, y) in candidates {
            let rect = Polygons.rectangle(minX: x, minY: y, maxX: x + size, maxY: y + size)
            if rect.intersection(keepOut).isEmpty {
                return (x, y, x + size, y + size)
            }
        }
        throw TowerError.noSpace
    }
}
