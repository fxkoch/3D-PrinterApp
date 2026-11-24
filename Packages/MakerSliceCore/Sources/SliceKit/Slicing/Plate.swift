import Foundation

/// Arranges objects on the build plate.
public enum PlateArranger {
    /// Places every object on the bed (z = 0), packed bottom-left into a compact, nearly square group that is centred
    /// on the bed. Big parts first; every candidate corner is tried and the one that keeps the group smallest wins.
    /// Returns nil when the objects don't fit.
    public static func arrange(_ objects: [ModelObject], bedSize: Double, spacing: Double = 6) -> [ModelObject]? {
        guard !objects.isEmpty else { return objects }
        var dropped = objects.map { $0.placedOnBed(center: (0, 0)) }
        let sizes = dropped.map { $0.boundingBox.size }
        let order = dropped.indices.sorted {
            let a = sizes[$0].x * sizes[$0].y, b = sizes[$1].x * sizes[$1].y
            return a == b ? $0 < $1 : a > b
        }
        struct Rect { var x, y, w, h: Double }
        func clash(_ a: Rect, _ b: Rect) -> Bool {
            a.x < b.x + b.w + spacing - 1e-6 && b.x < a.x + a.w + spacing - 1e-6 &&
                a.y < b.y + b.h + spacing - 1e-6 && b.y < a.y + a.h + spacing - 1e-6
        }
        var placed: [Rect] = []
        var positions = [Int: (Double, Double)]()
        var corners: [(Double, Double)] = [(0, 0)]
        for i in order {
            let w = sizes[i].x, h = sizes[i].y
            guard w <= bedSize + 0.01, h <= bedSize + 0.01 else { return nil }
            var best: Rect?
            var bestScore = Double.infinity
            let groupW = placed.map { $0.x + $0.w }.max() ?? 0, groupH = placed.map { $0.y + $0.h }.max() ?? 0
            for (cx, cy) in corners where cx + w <= bedSize + 0.01 && cy + h <= bedSize + 0.01 {
                let r = Rect(x: cx, y: cy, w: w, h: h)
                if placed.contains(where: { clash($0, r) }) { continue }
                let gw = max(groupW, cx + w), gh = max(groupH, cy + h)
                // Smallest square first, then the smallest area, then bottom-left.
                let score = max(gw, gh) * 1e6 + gw * gh + cy * 1e-3 + cx * 1e-6
                if score < bestScore { bestScore = score; best = r }
            }
            guard let r = best else { return nil }
            placed.append(r)
            positions[i] = (r.x + w / 2, r.y + h / 2)
            corners += [(r.x + w + spacing, r.y), (r.x, r.y + h + spacing), (r.x + w + spacing, 0), (0, r.y + h + spacing)]
        }
        let usedWidth = placed.map { $0.x + $0.w }.max() ?? 0, usedHeight = placed.map { $0.y + $0.h }.max() ?? 0
        let offsetX = (bedSize - usedWidth) / 2, offsetY = (bedSize - usedHeight) / 2
        for i in dropped.indices {
            guard let p = positions[i] else { continue }
            dropped[i] = dropped[i].placedOnBed(center: (p.0 + offsetX, p.1 + offsetY))
        }
        return dropped
    }

    /// Keeps the relative layout of objects (e.g. a Bambu plate) but recentres
    /// the group on this printer's bed. Returns nil if it doesn't fit.
    public static func recenter(_ objects: [ModelObject], bedSize: Double) -> [ModelObject]? {
        var box = BoundingBox.empty
        for o in objects { box.include(o.boundingBox) }
        guard !box.isEmpty else { return objects }
        let size = box.size
        guard size.x <= bedSize, size.y <= bedSize else { return nil }
        let shift = Vec3(bedSize / 2 - box.center.x, bedSize / 2 - box.center.y, -box.min.z)
        return objects.map { $0.transformed(.translation(shift)) }
    }
}

/// Result of distributing objects over several plates.
public struct PlateLayout: Sendable {
    /// Objects per plate (index 0 = plate 1), each arranged on the bed; `plate` is set on every object.
    public var plates: [[ModelObject]]
    /// Objects that are too large for the bed even when alone; they are not on any plate.
    public var unplaceable: [ModelObject]
}

extension PlateArranger {
    /// Like `arrange`, but turns objects by 90° when that makes everything fit.
    public static func arrangeFitting(_ objects: [ModelObject], bedSize: Double, spacing: Double = 6) -> [ModelObject]? {
        if let result = arrange(objects, bedSize: bedSize, spacing: spacing) { return result }
        // Wide side along X packs rows tighter.
        let landscape = objects.map { object -> ModelObject in
            let size = object.boundingBox.size
            guard size.y > size.x else { return object }
            let center = object.boundingBox.center
            return object.transformed(.translation(Vec3(-center.x, -center.y, 0)).then(.rotationZ(.pi / 2)))
        }
        return arrange(landscape, bedSize: bedSize, spacing: spacing)
    }

    /// Adds `new` objects to existing plates: biggest first, each on the first plate where everything still fits
    /// (starting with `preferred`), otherwise on a new plate. Existing objects are re-arranged together with the new ones.
    public static func place(_ new: [ModelObject], into plates: [[ModelObject]], bedSize: Double,
                             preferred: Int = 0, spacing: Double = 6) -> PlateLayout {
        var plates = plates.isEmpty ? [[]] : plates
        var unplaceable: [ModelObject] = []
        let order = new.sorted { footprint($0) > footprint($1) }
        for object in order {
            let first = min(max(preferred, 0), plates.count - 1)
            let candidates = [first] + plates.indices.filter { $0 != first }
            var placed = false
            for index in candidates {
                if let arranged = arrangeFitting(plates[index] + [object], bedSize: bedSize, spacing: spacing) {
                    plates[index] = arranged
                    placed = true
                    break
                }
            }
            if placed { continue }
            if let alone = arrangeFitting([object], bedSize: bedSize, spacing: spacing) {
                plates.append(alone)
            } else {
                unplaceable.append(object)
            }
        }
        for index in plates.indices {
            for i in plates[index].indices { plates[index][i].plate = index + 1 }
        }
        return PlateLayout(plates: plates, unplaceable: unplaceable)
    }

    /// Distributes all objects over as few plates as possible.
    public static func distribute(_ objects: [ModelObject], bedSize: Double, spacing: Double = 6) -> PlateLayout {
        place(objects, into: [[]], bedSize: bedSize, preferred: 0, spacing: spacing)
    }

    /// True when any two objects overlap in the XY plane (their layout can't be kept as it is).
    public static func hasOverlap(_ objects: [ModelObject], tolerance: Double = 0.01) -> Bool {
        let boxes = objects.map(\.boundingBox)
        for i in boxes.indices {
            for j in boxes.indices where j > i {
                let a = boxes[i], b = boxes[j]
                if a.min.x < b.max.x - tolerance, b.min.x < a.max.x - tolerance,
                   a.min.y < b.max.y - tolerance, b.min.y < a.max.y - tolerance { return true }
            }
        }
        return false
    }

    private static func footprint(_ object: ModelObject) -> Double {
        let size = object.boundingBox.size
        return size.x * size.y
    }
}

/// High-level entry point: objects + settings → G-code.
public struct SliceJob: Sendable {
    public var name: String
    public var objects: [ModelObject]
    public var settings: PrintSettings

    public init(name: String, objects: [ModelObject], settings: PrintSettings) {
        self.name = name
        self.objects = objects
        self.settings = settings
    }

    public struct Output: Sendable {
        public var layers: [SlicedLayer]
        public var gcode: String
        public var estimate: PrintEstimate
        /// Which slicer produced the G-code.
        public var engine: String

        public init(layers: [SlicedLayer], gcode: String, estimate: PrintEstimate, engine: String = "MakerSlice (iPhone)") {
            self.layers = layers
            self.gcode = gcode
            self.estimate = estimate
            self.engine = engine
        }
    }

    public func run(isCancelled: @escaping () -> Bool = { false },
                    progress: @escaping (SliceProgress) -> Void = { _ in }) throws -> Output {
        let layers = try Slicer(settings: settings, isCancelled: isCancelled).slice(objects, progress: progress)
        let result = GCodeWriter(settings: settings.effective).write(layers: layers, jobName: name, objects: objects)
        return Output(layers: layers, gcode: result.gcode, estimate: result.estimate)
    }
}
