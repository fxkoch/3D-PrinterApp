import Foundation

/// Simple vertical (grid-style) supports below overhangs.
struct SupportGenerator {
    let settings: PrintSettings

    struct Result {
        var areas: [Polygons]
        /// Dense contact layers directly below the model.
        var interfaces: [Polygons]
    }

    func generate(layers: [Polygons], tops: [Double]) -> Result {
        let s = settings
        let n = layers.count
        var areas = [Polygons](repeating: Polygons(), count: n)
        var interfaces = [Polygons](repeating: Polygons(), count: n)
        guard n > 2 else { return Result(areas: areas, interfaces: interfaces) }

        // Overhang of layer i+1 relative to layer i: parts sticking out further than
        // the threshold angle allows.
        let angle = max(5, min(85, s.supportAngle)) * .pi / 180
        let allowed = s.layerHeight / tan(angle)
        var overhang = [Polygons](repeating: Polygons(), count: n)
        overhang.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: n - 1) { i in
                let upper = layers[i + 1]
                guard !upper.isEmpty else { return }
                let o = upper.difference(layers[i].offset(allowed)).offset(-0.2).offset(0.4)
                out[i + 1] = o.intersection(upper.offset(0.4)).filterSmall(minArea: 0.5)
            }
        }

        // Leave a gap of whole layers between support and model.
        let gap = max(1, Int((s.supportTopZDistance / s.layerHeight).rounded()))

        // Shadow of the model as seen from below – used for "build plate only".
        var shadow = [Polygons](repeating: Polygons(), count: n)
        if s.support == .buildPlateOnly {
            var acc = Polygons()
            for i in 0..<n {
                acc = layers[i].isEmpty ? acc : (acc + layers[i]).union()
                shadow[i] = acc
            }
        }

        var carry = Polygons()
        var recent: [Polygons] = [] // overhangs of the last two interface layers
        for i in stride(from: n - 1, through: 0, by: -1) {
            let source = i + 1 + gap < n ? overhang[i + 1 + gap] : Polygons()
            if !source.isEmpty { carry = (carry + source).union() }
            recent.insert(source, at: 0)
            if recent.count > 2 { recent.removeLast() }
            guard !carry.isEmpty else { continue }

            // Columns end where they land on the model.
            carry = carry.difference(layers[i])
            var area = carry.difference(layers[i].offset(s.supportXYDistance))
            if s.support == .buildPlateOnly {
                // Anything above the model's footprint would have to stand on the model.
                carry = carry.difference(shadow[i])
                area = area.difference(shadow[i].offset(s.supportXYDistance))
            }
            area = area.filterSmall(minArea: 1)
            areas[i] = area
            let contact = Polygons(recent.flatMap(\.paths)).union()
            interfaces[i] = area.intersection(contact)
        }
        return Result(areas: areas, interfaces: interfaces)
    }
}

extension Polygons {
    /// Removes islands smaller than `minArea` mm² (holes are kept).
    func filterSmall(minArea: Double) -> Polygons {
        let limit = minArea * Units.perMM * Units.perMM
        return Polygons(paths.filter { Polygons.signedArea($0) < 0 || Polygons.signedArea($0) >= limit })
    }
}
