import Foundation

public struct SliceProgress: Sendable {
    public var phase: String
    public var fraction: Double
}

public enum SliceError: Error, LocalizedError, Equatable {
    case nothingToPrint
    case outsideBed(String)
    case tooTall(Double)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .nothingToPrint: return "Keine Objekte auf dem Druckbett."
        case .outsideBed(let name): return "„\(name)“ ragt über das Druckbett hinaus."
        case .tooTall(let h): return String(format: "Objekt ist %.1f mm hoch – zu hoch für den Drucker.", h)
        case .cancelled: return "Slicen abgebrochen."
        }
    }
}

/// Turns arranged model objects into printable layers.
public final class Slicer: @unchecked Sendable {
    public let settings: PrintSettings
    private let isCancelled: () -> Bool

    public init(settings: PrintSettings, isCancelled: @escaping () -> Bool = { false }) {
        self.settings = settings
        self.isCancelled = isCancelled
    }

    /// Layer top heights for a print of the given height.
    public func layerHeights(forHeight height: Double) -> [Double] {
        var z = settings.firstLayerHeight
        var result: [Double] = []
        while z < height + settings.layerHeight * 0.5 || result.isEmpty {
            result.append(z)
            z += settings.layerHeight
            if result.count > 20_000 { break }
        }
        return result
    }

    public func slice(_ objects: [ModelObject], progress: (SliceProgress) -> Void = { _ in }) throws -> [SlicedLayer] {
        let s = settings
        let printable = objects.filter { !$0.mesh.isEmpty }
        guard !printable.isEmpty else { throw SliceError.nothingToPrint }
        var height = 0.0
        for object in printable {
            let box = object.boundingBox
            if box.min.x < -0.01 || box.min.y < -0.01 || box.max.x > s.bedSize + 0.01 || box.max.y > s.bedSize + 0.01 {
                throw SliceError.outsideBed(object.name)
            }
            height = max(height, box.max.z)
        }
        if height > s.maxHeight { throw SliceError.tooTall(height) }

        let tops = layerHeights(forHeight: height)
        // Slice each layer through its vertical middle.
        let mids = tops.enumerated().map { i, top in top - (i == 0 ? s.firstLayerHeight : s.layerHeight) / 2 }
        let tools = Array(Set(printable.map(\.tool))).sorted()

        // 1. Outlines per tool and layer.
        progress(SliceProgress(phase: "Schichten schneiden", fraction: 0))
        var regions: [Int: [Polygons]] = [:]
        for (n, tool) in tools.enumerated() {
            var perLayer = [Polygons](repeating: Polygons(), count: tops.count)
            for object in printable where object.tool == tool {
                var slices = MeshSlicer.slice(object.mesh, at: mids)
                // Connector pegs are added, connector holes cut away.
                for volume in object.volumes {
                    let extra = MeshSlicer.slice(volume.mesh, at: mids)
                    for i in 0..<tops.count where !extra[i].isEmpty {
                        switch volume.kind {
                        case .add: slices[i] = (slices[i] + extra[i]).union()
                        case .subtract: slices[i] = slices[i].difference(extra[i])
                        }
                    }
                }
                for i in 0..<tops.count where !slices[i].isEmpty {
                    perLayer[i] = perLayer[i].isEmpty ? slices[i] : (perLayer[i] + slices[i]).union()
                }
                if isCancelled() { throw SliceError.cancelled }
            }
            regions[tool] = perLayer
            progress(SliceProgress(phase: "Schichten schneiden", fraction: Double(n + 1) / Double(tools.count) * 0.3))
        }
        // Earlier tools win where objects of different tools overlap.
        var claimed = [Polygons](repeating: Polygons(), count: tops.count)
        for tool in tools {
            var perLayer = regions[tool]!
            for i in perLayer.indices where !claimed[i].isEmpty {
                perLayer[i] = perLayer[i].difference(claimed[i])
            }
            for i in perLayer.indices where !perLayer[i].isEmpty {
                claimed[i] = claimed[i].isEmpty ? perLayer[i] : (claimed[i] + perLayer[i]).union()
            }
            regions[tool] = perLayer
        }
        let all = claimed

        // 2. Support areas (need the full stack, so done up-front).
        progress(SliceProgress(phase: "Stützen berechnen", fraction: 0.3))
        let support = s.support == .off ? nil : SupportGenerator(settings: s).generate(layers: all, tops: tops)
        if isCancelled() { throw SliceError.cancelled }

        // 3. Walls and infill per layer, in parallel.
        progress(SliceProgress(phase: "Wände & Füllung", fraction: 0.4))
        var layers = [SlicedLayer?](repeating: nil, count: tops.count)
        let lock = NSLock()
        var done = 0
        layers.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: tops.count) { i in
                if isCancelled() { return }
                let height = i == 0 ? s.firstLayerHeight : s.layerHeight
                var islands: [ToolIsland] = []
                for tool in tools {
                    let region = regions[tool]![i]
                    guard !region.isEmpty else { continue }
                    let gen = LayerToolpathGenerator(settings: s, layerIndex: i, z: tops[i], height: height)
                    let extrusions = gen.generate(region: region, above: { k in i + k < all.count ? all[i + k] : nil },
                                                  below: { k in i - k >= 0 ? all[i - k] : nil })
                    if !extrusions.isEmpty { islands.append(ToolIsland(tool: tool, extrusions: extrusions)) }
                }
                if let support, !support.areas[i].isEmpty {
                    let gen = LayerToolpathGenerator(settings: s, layerIndex: i, z: tops[i], height: height)
                    let supportPaths = gen.supportPaths(area: support.areas[i], interface: support.interfaces[i])
                    let supportTool = tools.first ?? 0
                    if let idx = islands.firstIndex(where: { $0.tool == supportTool }) {
                        islands[idx].extrusions.insert(contentsOf: supportPaths, at: 0)
                    } else {
                        islands.insert(ToolIsland(tool: supportTool, extrusions: supportPaths), at: 0)
                    }
                }
                out[i] = SlicedLayer(index: i, z: tops[i], height: height, islands: islands, outline: all[i])
                lock.lock()
                done += 1
                let fraction = 0.4 + 0.55 * Double(done) / Double(tops.count)
                lock.unlock()
                if i % 10 == 0 { progress(SliceProgress(phase: "Wände & Füllung", fraction: fraction)) }
            }
        }
        if isCancelled() { throw SliceError.cancelled }
        var result = layers.compactMap { $0 }

        // 4. Skirt/brim on the first layer.
        if let firstTool = result.first?.islands.first?.tool ?? tools.first {
            let adhesion = adhesionPaths(firstLayer: all[0], supportFirstLayer: support?.areas.first)
            if !adhesion.isEmpty, !result.isEmpty {
                if let idx = result[0].islands.firstIndex(where: { $0.tool == firstTool }) {
                    result[0].islands[idx].extrusions.insert(contentsOf: adhesion, at: 0)
                } else {
                    result[0].islands.insert(ToolIsland(tool: firstTool, extrusions: adhesion), at: 0)
                }
            }
        }
        // Drop empty layers at the top (e.g. rounding past the model).
        while let last = result.last, last.islands.isEmpty { result.removeLast() }
        guard !result.isEmpty else { throw SliceError.nothingToPrint }

        // 5. Print order: keep the active tool first on every layer to minimise changes.
        var current = result.first?.islands.first?.tool ?? 0
        for i in result.indices {
            result[i].islands.sort { a, b in
                if a.tool == current { return b.tool != current }
                if b.tool == current { return false }
                return a.tool < b.tool
            }
            if let last = result[i].islands.last { current = last.tool }
        }

        // 6. Purge tower for single-nozzle multi-material printers.
        if s.primeTower, s.machine.multiMaterial == .filamentSwitcher, tools.count > 1 {
            try PrimeTower(settings: s).insert(into: &result, footprint: all)
        }
        progress(SliceProgress(phase: "Fertig", fraction: 1))
        return result
    }

    private func adhesionPaths(firstLayer: Polygons, supportFirstLayer: Polygons?) -> [Extrusion] {
        let s = settings
        let w = s.firstLayerLineWidth
        var base = firstLayer
        if let supportFirstLayer, !supportFirstLayer.isEmpty { base = (base + supportFirstLayer).union() }
        guard !base.isEmpty else { return [] }
        var result: [Extrusion] = []

        var brimOuter = base
        if s.brimWidth > 0 {
            let loops = max(1, Int((s.brimWidth / w).rounded()))
            var brim: [Extrusion] = []
            for k in 0..<loops {
                let ring = base.offset(w * (Double(k) + 0.5), join: .round)
                for path in ring.paths {
                    brim.append(Extrusion(role: .brim, points: path, closed: true, width: w, speed: s.firstLayerSpeed))
                }
            }
            // Print brim from the inside out so it hugs the part.
            result.append(contentsOf: brim)
            brimOuter = base.offset(w * Double(loops), join: .round)
        }
        if s.skirtLoops > 0 {
            // The skirt is a single outline around everything (helps prime the nozzle).
            let hull = brimOuter.offset(s.skirtDistance + 5, join: .round).offset(-5, join: .round)
            for k in 0..<s.skirtLoops {
                let ring = hull.offset(w * Double(k), join: .round)
                for path in ring.paths where Polygons.signedArea(path) > 0 {
                    result.insert(Extrusion(role: .skirt, points: path, closed: true, width: w, speed: s.firstLayerSpeed), at: 0)
                }
            }
        }
        return result
    }
}
