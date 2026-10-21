import Foundation

/// Turns painted surface triangles into per-layer areas of each colour.
///
/// A painted triangle colours the part of the object near it, not just its outer line:
/// - on side walls the colour reaches `depth` mm into the object (the wall thickness),
/// - on top and bottom surfaces the colour covers the painted area for the shell layers below/above the surface.
/// The areas are later cut to the object's outline, so they never print outside the model.
enum PaintedRegions {
    /// For every colour (slot) the painted area of each layer.
    static func regions(facets: [PaintedFacet], mids: [Double], layerHeight: Double, depth: Double = 1.2) -> [Int: [Polygons]] {
        guard !facets.isEmpty, !mids.isEmpty else { return [:] }
        var paths: [Int: [[Path]]] = [:]
        let shellDepth = max(depth, layerHeight * 4)

        func layers(from lo: Double, to hi: Double) -> Range<Int> {
            // First layer whose middle is >= lo, up to the last whose middle is <= hi.
            var a = 0, b = mids.count
            while a < b { let m = (a + b) / 2; if mids[m] < lo { a = m + 1 } else { b = m } }
            let first = a
            a = first; b = mids.count
            while a < b { let m = (a + b) / 2; if mids[m] <= hi { a = m + 1 } else { b = m } }
            return first..<max(a, first)
        }

        func add(_ polygon: Path, tool: Int, layer: Int) {
            var list = paths[tool] ?? [[Path]](repeating: [], count: mids.count)
            list[layer].append(polygon)
            paths[tool] = list
        }

        func orient(_ path: Path) -> Path { Polygons.signedArea(path) < 0 ? path.reversed() : path }
        func point(_ x: Double, _ y: Double) -> IntPoint { IntPoint(mmX: x, mmY: y) }

        for f in facets {
            let e1 = f.b - f.a, e2 = f.c - f.a
            let n = e1.cross(e2)
            let length = n.length
            guard length > 1e-9 else { continue }
            let nz = n.z / length
            let zMin = min(f.a.z, f.b.z, f.c.z), zMax = max(f.a.z, f.b.z, f.c.z)

            if abs(nz) >= 0.75 {
                // Nearly horizontal: the painted area itself, for the shell layers beneath (top) or above (bottom).
                let triangle = orient([point(f.a.x, f.a.y), point(f.b.x, f.b.y), point(f.c.x, f.c.y)])
                let range = nz > 0 ? layers(from: zMax - shellDepth, to: zMax + 1e-6) : layers(from: zMin - 1e-6, to: zMin + shellDepth)
                for i in range { add(triangle, tool: f.tool, layer: i) }
            } else {
                // Side wall: cut the triangle with every layer's plane and push the segment into the object.
                let outward = (x: n.x, y: n.y)
                let outLength = (outward.x * outward.x + outward.y * outward.y).squareRoot()
                guard outLength > 1e-9 else { continue }
                let nx = outward.x / outLength, ny = outward.y / outLength
                for i in layers(from: zMin, to: zMax) {
                    let z = mids[i]
                    var hits: [(Double, Double)] = []
                    for (p, q) in [(f.a, f.b), (f.b, f.c), (f.c, f.a)] where (p.z - z) * (q.z - z) < 0 {
                        let t = (z - p.z) / (q.z - p.z)
                        hits.append((p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t))
                    }
                    guard hits.count == 2 else { continue }
                    let (x1, y1) = hits[0], (x2, y2) = hits[1]
                    // Inward = against the outward normal; a thin margin outward keeps the segment itself inside.
                    let quad = orient([point(x1 + nx * 0.15, y1 + ny * 0.15), point(x2 + nx * 0.15, y2 + ny * 0.15),
                                       point(x2 - nx * depth, y2 - ny * depth), point(x1 - nx * depth, y1 - ny * depth)])
                    add(quad, tool: f.tool, layer: i)
                }
            }
        }

        var result: [Int: [Polygons]] = [:]
        for (tool, perLayer) in paths {
            result[tool] = perLayer.map { list in
                list.isEmpty ? Polygons() : Polygons(list.flatMap { $0 }).union().offset(0.03, join: .miter).union()
            }
        }
        return result
    }
}
