import Foundation

/// Arranges objects on the build plate.
public enum PlateArranger {
    /// Places every object on the bed (z = 0) using simple shelf packing,
    /// centring the whole group. Returns nil when the objects don't fit.
    public static func arrange(_ objects: [ModelObject], bedSize: Double, spacing: Double = 6) -> [ModelObject]? {
        guard !objects.isEmpty else { return objects }
        var dropped = objects.map { $0.placedOnBed(center: (0, 0)) }
        // Largest footprints first.
        let order = dropped.indices.sorted {
            let a = dropped[$0].boundingBox.size, b = dropped[$1].boundingBox.size
            return a.y == b.y ? a.x > b.x : a.y > b.y
        }
        var x = 0.0, y = 0.0, rowHeight = 0.0, usedWidth = 0.0
        var positions = [Int: (Double, Double)]()
        for i in order {
            let size = dropped[i].boundingBox.size
            if x > 0 && x + size.x > bedSize {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions[i] = (x + size.x / 2, y + size.y / 2)
            x += size.x + spacing
            usedWidth = max(usedWidth, x - spacing)
            rowHeight = max(rowHeight, size.y)
        }
        let usedHeight = y + rowHeight
        guard usedWidth <= bedSize + 0.01, usedHeight <= bedSize + 0.01 else { return nil }
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
    }

    public func run(isCancelled: @escaping () -> Bool = { false },
                    progress: @escaping (SliceProgress) -> Void = { _ in }) throws -> Output {
        let layers = try Slicer(settings: settings, isCancelled: isCancelled).slice(objects, progress: progress)
        let result = GCodeWriter(settings: settings).write(layers: layers, jobName: name)
        return Output(layers: layers, gcode: result.gcode, estimate: result.estimate)
    }
}
