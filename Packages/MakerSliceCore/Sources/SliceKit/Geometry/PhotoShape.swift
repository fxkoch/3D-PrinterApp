import Foundation

/// A photo as brightness values (0 = black … 1 = white), row 0 on top, optionally with a mask of the subject (1 = subject).
public struct GrayImage: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [Float]
    public var subject: [Float]?

    public init(width: Int, height: Int, pixels: [Float], subject: [Float]? = nil) {
        self.width = width; self.height = height; self.pixels = pixels; self.subject = subject
    }
}

/// Turns a photo into a printable shape within seconds: the outline of the object, extruded (key ring, template, stamp),
/// or the brightness as relief. The mesh is built straight from a smoothed mask (marching squares) – always watertight.
public enum PhotoShape {
    public enum Mode: Sendable, Equatable {
        /// Outline of the subject, extruded to `thickness`.
        case silhouette
        /// Rectangle whose height follows the brightness: base `thickness`, up to `depth` more. Dark = high if `darkIsHigh`.
        case relief(depth: Double, darkIsHigh: Bool)
    }

    public struct Options: Sendable, Equatable {
        public var mode: Mode = .silhouette
        /// Length of the longest side in mm.
        public var size = 60.0
        public var thickness = 3.0
        /// Smoothing of the outline in pixels of the working resolution (0 = jagged, 2–4 = round).
        public var smoothing = 2.0
        /// Brightness threshold 0…1; nil = chosen automatically (Otsu).
        public var threshold: Float?
        /// Object is brighter than the background; nil = detected (the border of the photo is background).
        public var subjectIsBright: Bool?
        /// A ring with a hole at the top to hang it.
        public var keyRingHole = false
        public var holeDiameter = 4.0
        /// Holes inside the subject smaller than this share of its area are filled (dust, reflections).
        public var fillHolesBelow = 0.01
        public init() {}
    }

    public enum Failure: LocalizedError {
        case nothingFound
        public var errorDescription: String? { "Im Foto wurde kein Objekt gefunden. Ein einfarbiger, kontrastreicher Hintergrund hilft." }
    }

    /// The working resolution: the longest side of the photo is brought to this many pixels.
    static let working = 180

    // MARK: Mask

    /// Subject mask (1 = subject) at working resolution, with its size.
    public static func mask(_ image: GrayImage, options: Options = Options()) -> (values: [Float], width: Int, height: Int) {
        let (small, w, h, subject) = downscale(image)
        var mask = [Float](repeating: 0, count: w * h)
        if let subject {
            for i in 0..<mask.count { mask[i] = subject[i] > 0.5 ? 1 : 0 }
        } else {
            let t = options.threshold ?? otsu(small)
            var bright = options.subjectIsBright
            if bright == nil {
                // The photo's border is background: if it is brighter than the threshold, the subject is the dark part.
                var border = 0.0, count = 0.0
                for x in 0..<w { border += Double(small[x] + small[(h - 1) * w + x]); count += 2 }
                for y in 0..<h { border += Double(small[y * w] + small[y * w + w - 1]); count += 2 }
                bright = Float(border / count) < t
            }
            for i in 0..<mask.count { mask[i] = (small[i] >= t) == (bright ?? false) ? 1 : 0 }
        }
        mask = largestComponent(mask, w, h)
        mask = fillSmallHoles(mask, w, h, below: options.fillHolesBelow)
        return (mask, w, h)
    }

    // MARK: Mesh

    public static func mesh(_ image: GrayImage, options: Options = Options()) throws -> TriangleMesh {
        let (small, w0, h0, _) = downscale(image)
        let (mask0, mw, mh) = mask(image, options: options)
        var field: [Float]
        var heights: [Float]?
        switch options.mode {
        case .silhouette:
            field = mask0
            guard field.contains(where: { $0 > 0 }) else { throw Failure.nothingFound }
        case .relief(let depth, let darkIsHigh):
            field = [Float](repeating: 1, count: mw * mh)
            heights = small.map { Float(options.thickness) + Float(depth) * (darkIsHigh ? 1 - $0 : $0) }
            _ = (w0, h0)
        }
        // Pad with empty cells so the outline closes, then smooth.
        let pad = 3
        let w = mw + 2 * pad, h = mh + 2 * pad
        var padded = [Float](repeating: 0, count: w * h)
        var paddedHeights = [Float](repeating: Float(options.thickness), count: w * h)
        for y in 0..<mh { for x in 0..<mw {
            padded[(y + pad) * w + x + pad] = field[y * mw + x]
            if let heights { paddedHeights[(y + pad) * w + x + pad] = heights[y * mw + x] }
        } }
        if options.smoothing > 0.1 { padded = blur(padded, w, h, radius: Int(options.smoothing.rounded(.up)), passes: 2) }
        if heights != nil { paddedHeights = blur(paddedHeights, w, h, radius: 1, passes: 1) }

        // Scale: the longest side of the subject (bounding box of the field) gets `size` mm.
        var minX = w, maxX = 0, minY = h, maxY = 0
        for y in 0..<h { for x in 0..<w where padded[y * w + x] >= 0.5 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard minX <= maxX, minY <= maxY else { throw Failure.nothingFound }
        let extent = Double(max(maxX - minX, maxY - minY) + 1)
        let cell = options.size / extent
        // Millimetres: x right, y up (row 0 on top of the photo), origin at the subject's lower left.
        func position(_ gx: Double, _ gy: Double) -> (Double, Double) { ((gx - Double(minX)) * cell, (Double(maxY + 1) - gy) * cell) }

        if options.keyRingHole {
            let r = options.holeDiameter / 2, boss = r + 2.5
            // The hole sits at the top of the subject, centred on its widest part near the top.
            var topRow = minY
            while topRow < maxY, (0..<w).filter({ padded[topRow * w + $0] >= 0.5 }).count < 3 { topRow += 1 }
            let rows = (topRow...min(maxY, topRow + max(2, Int(boss / cell)))).map { $0 }
            var sum = 0.0, n = 0.0
            for y in rows { for x in 0..<w where padded[y * w + x] >= 0.5 { sum += Double(x); n += 1 } }
            let (cx, cy) = position(n > 0 ? sum / n + 0.5 : Double(minX), Double(topRow) + boss / cell * 0.35)
            for y in 0..<h { for x in 0..<w {
                let (px, py) = position(Double(x) + 0.5, Double(y) + 0.5)
                let d = ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot()
                let ramp = 2 * cell
                let bossField = Float(max(0, min(1, 0.5 + (boss - d) / ramp)))
                let holeField = Float(max(0, min(1, 0.5 + (d - r) / ramp)))
                padded[y * w + x] = min(max(padded[y * w + x], bossField), holeField)
            } }
        }

        return build(field: padded, heights: heights == nil ? nil : paddedHeights, thickness: options.thickness, w: w, h: h,
                     position: position, cell: cell)
    }

    // MARK: Marching squares extrusion

    private static func build(field f: [Float], heights: [Float]?, thickness: Double, w: Int, h: Int,
                              position: (Double, Double) -> (Double, Double), cell: Double) -> TriangleMesh {
        let iso: Float = 0.5
        func height(_ gx: Double, _ gy: Double) -> Double {
            guard let heights else { return thickness }
            let x = max(0, min(Double(w - 1), gx - 0.5)), y = max(0, min(Double(h - 1), gy - 0.5))
            let x0 = Int(x), y0 = Int(y), x1 = min(w - 1, x0 + 1), y1 = min(h - 1, y0 + 1)
            let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
            let top = heights[y0 * w + x0] * (1 - fx) + heights[y0 * w + x1] * fx
            let bottom = heights[y1 * w + x0] * (1 - fx) + heights[y1 * w + x1] * fx
            return Double(top * (1 - fy) + bottom * fy)
        }
        var soup: [(Vec3, Vec3, Vec3)] = []
        // Grid corner (x, y) sits at the centre of pixel (x, y): coordinates + 0.5 in pixel space.
        struct Corner { var gx: Double; var gy: Double; var v: Float; var inside: Bool; var key: Int }
        for cy in 0..<(h - 1) { for cx in 0..<(w - 1) {
            let idx = [(cx, cy), (cx + 1, cy), (cx + 1, cy + 1), (cx, cy + 1)]   // x right, y down in pixels
            let corners = idx.map { Corner(gx: Double($0.0) + 0.5, gy: Double($0.1) + 0.5, v: f[$0.1 * w + $0.0], inside: f[$0.1 * w + $0.0] >= iso, key: $0.1 * w + $0.0) }
            if !corners.contains(where: { $0.inside }) { continue }
            // Polygon in walking order; flags mark vertices that lie on the outline (crossings).
            var polygon: [(gx: Double, gy: Double, crossing: Bool)] = []
            for i in 0..<4 {
                let a = corners[i], b = corners[(i + 1) % 4]
                if a.inside { polygon.append((a.gx, a.gy, false)) }
                if a.inside != b.inside {
                    // Canonical order so both cells compute the identical point.
                    let (p, q) = a.key < b.key ? (a, b) : (b, a)
                    let t = Double((iso - p.v) / (q.v - p.v))
                    polygon.append((p.gx + (q.gx - p.gx) * t, p.gy + (q.gy - p.gy) * t, true))
                }
            }
            guard polygon.count >= 3 else { continue }
            // Pixel y grows downwards, millimetre y upwards: reverse the walk so the polygon is counter-clockwise in mm.
            let pts = polygon.reversed().map { v -> (Vec3, Vec3, Bool) in
                let (x, y) = position(v.gx, v.gy)
                let z = height(v.gx, v.gy)
                return (Vec3(x, y, 0), Vec3(x, y, z), v.crossing)
            }
            for i in 1..<(pts.count - 1) {
                soup.append((pts[0].1, pts[i].1, pts[i + 1].1))          // top
                soup.append((pts[0].0, pts[i + 1].0, pts[i].0))          // bottom
            }
            // Walls on the outline: edges between two crossings (interior on the left, wall faces right).
            for i in 0..<pts.count {
                let a = pts[i], b = pts[(i + 1) % pts.count]
                guard a.2, b.2 else { continue }
                soup.append((a.0, b.0, b.1))
                soup.append((a.0, b.1, a.1))
            }
        } }
        return TriangleMesh(soup: soup)
    }

    // MARK: Image helpers

    private static func downscale(_ image: GrayImage) -> (pixels: [Float], width: Int, height: Int, subject: [Float]?) {
        let scale = min(1, Double(working) / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        if w == image.width && h == image.height { return (image.pixels, w, h, image.subject) }
        func resample(_ src: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: w * h)
            for y in 0..<h {
                let y0 = Int(Double(y) / scale), y1 = max(y0 + 1, min(image.height, Int(Double(y + 1) / scale)))
                for x in 0..<w {
                    let x0 = Int(Double(x) / scale), x1 = max(x0 + 1, min(image.width, Int(Double(x + 1) / scale)))
                    var sum: Float = 0, n: Float = 0
                    for yy in y0..<min(y1, image.height) { for xx in x0..<min(x1, image.width) { sum += src[yy * image.width + xx]; n += 1 } }
                    out[y * w + x] = n > 0 ? sum / n : 0
                }
            }
            return out
        }
        return (resample(image.pixels), w, h, image.subject.map(resample))
    }

    static func otsu(_ pixels: [Float]) -> Float {
        var histogram = [Double](repeating: 0, count: 256)
        for p in pixels { histogram[Int(max(0, min(255, p * 255)))] += 1 }
        let total = Double(pixels.count)
        var sum = 0.0
        for i in 0..<256 { sum += Double(i) * histogram[i] }
        var sumB = 0.0, wB = 0.0, best = 0.0, threshold = 128.0
        for i in 0..<256 {
            wB += histogram[i]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(i) * histogram[i]
            let mB = sumB / wB, mF = (sum - sumB) / wF
            let between = wB * wF * (mB - mF) * (mB - mF)
            // Halfway between the two class means is a safer split than a bin edge (two-tone images).
            if between > best { best = between; threshold = (mB + mF) / 2 }
        }
        return Float(threshold) / 255
    }

    static func blur(_ f: [Float], _ w: Int, _ h: Int, radius: Int, passes: Int) -> [Float] {
        var src = f
        let r = max(1, radius)
        for _ in 0..<passes {
            var tmp = [Float](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w {
                var s: Float = 0, n: Float = 0
                for dx in -r...r { let xx = x + dx; if xx >= 0 && xx < w { s += src[y * w + xx]; n += 1 } }
                tmp[y * w + x] = s / n
            } }
            for y in 0..<h { for x in 0..<w {
                var s: Float = 0, n: Float = 0
                for dy in -r...r { let yy = y + dy; if yy >= 0 && yy < h { s += tmp[yy * w + x]; n += 1 } }
                src[y * w + x] = s / n
            } }
        }
        return src
    }

    /// Keeps the biggest connected region of the mask (the subject), drops specks.
    static func largestComponent(_ mask: [Float], _ w: Int, _ h: Int) -> [Float] {
        var label = [Int](repeating: -1, count: w * h)
        var sizes: [Int] = []
        for start in 0..<(w * h) where mask[start] > 0 && label[start] < 0 {
            var stack = [start], count = 0
            label[start] = sizes.count
            while let p = stack.popLast() {
                count += 1
                let x = p % w, y = p / w
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    let q = ny * w + nx
                    if mask[q] > 0, label[q] < 0 { label[q] = sizes.count; stack.append(q) }
                }
            }
            sizes.append(count)
        }
        guard let best = sizes.indices.max(by: { sizes[$0] < sizes[$1] }) else { return mask }
        return label.map { $0 == best ? 1 : 0 }
    }

    /// Fills enclosed background regions smaller than `below` of the subject's area.
    static func fillSmallHoles(_ mask: [Float], _ w: Int, _ h: Int, below: Double) -> [Float] {
        var out = mask
        let area = Double(mask.reduce(0) { $0 + ($1 > 0 ? 1 : 0) })
        var seen = [Bool](repeating: false, count: w * h)
        for start in 0..<(w * h) where mask[start] == 0 && !seen[start] {
            var stack = [start], region: [Int] = [], touchesBorder = false
            seen[start] = true
            while let p = stack.popLast() {
                region.append(p)
                let x = p % w, y = p / w
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touchesBorder = true }
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    let q = ny * w + nx
                    if mask[q] == 0, !seen[q] { seen[q] = true; stack.append(q) }
                }
            }
            if !touchesBorder, Double(region.count) < area * below { for p in region { out[p] = 1 } }
        }
        return out
    }
}
