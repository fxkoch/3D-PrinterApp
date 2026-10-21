import CZip
import Foundation

/// Renders a small shaded view of the plate's objects as PNG, for the preview the printer shows
/// on its screen (embedded in the G-code like OrcaSlicer does).
public enum Thumbnail {
    /// - Returns: PNG data with a transparent background.
    public static func render(_ objects: [ModelObject], filaments: [Filament], width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, !objects.isEmpty else { return nil }
        // Isometric-ish view: turn 35° around Z, tilt 30° towards the viewer.
        let yaw = -35.0 * .pi / 180, pitch = 55.0 * .pi / 180
        let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        func project(_ v: Vec3) -> (x: Double, y: Double, depth: Double) {
            let x1 = v.x * cy - v.y * sy
            let y1 = v.x * sy + v.y * cy
            return (x1, y1 * cp + v.z * sp, -y1 * sp + v.z * cp)
        }
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for object in objects {
            for v in object.mesh.vertices {
                let p = project(v)
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        guard minX.isFinite, maxX > minX || maxY > minY else { return nil }

        // Render at 2× and downsample for smooth edges.
        let ss = 2, w = width * ss, h = height * ss
        let margin = 0.08
        let scale = min(Double(w) * (1 - 2 * margin) / max(maxX - minX, 1e-6),
                        Double(h) * (1 - 2 * margin) / max(maxY - minY, 1e-6))
        let ox = (Double(w) - (maxX - minX) * scale) / 2 - minX * scale
        let oy = (Double(h) - (maxY - minY) * scale) / 2 - minY * scale
        var depth = [Double](repeating: -.infinity, count: w * h)
        var color = [UInt8](repeating: 0, count: w * h * 4)
        let light = Vec3(-0.35, -0.55, 0.76)
        let lightLength = light.length

        for object in objects {
            let rgb = rgbBytes(object.tool < filaments.count ? filaments[object.tool].color : "#9AA0A6")
            let mesh = object.mesh
            var t = 0
            while t + 2 < mesh.indices.count {
                let a = mesh.vertices[Int(mesh.indices[t])], b = mesh.vertices[Int(mesh.indices[t + 1])]
                let c = mesh.vertices[Int(mesh.indices[t + 2])]
                t += 3
                let n = (b - a).cross(c - a)
                let len = n.length
                guard len > 1e-12 else { continue }
                let shade = 0.35 + 0.65 * max(0, (n.x * light.x + n.y * light.y + n.z * light.z) / (len * lightLength))
                let pa = project(a), pb = project(b), pc = project(c)
                let p = [(pa.x * scale + ox, Double(h) - (pa.y * scale + oy), pa.depth),
                         (pb.x * scale + ox, Double(h) - (pb.y * scale + oy), pb.depth),
                         (pc.x * scale + ox, Double(h) - (pc.y * scale + oy), pc.depth)]
                let area = (p[1].0 - p[0].0) * (p[2].1 - p[0].1) - (p[2].0 - p[0].0) * (p[1].1 - p[0].1)
                guard abs(area) > 1e-9 else { continue }
                let x0 = max(0, Int(floor(min(p[0].0, p[1].0, p[2].0)))), x1 = min(w - 1, Int(ceil(max(p[0].0, p[1].0, p[2].0))))
                let y0 = max(0, Int(floor(min(p[0].1, p[1].1, p[2].1)))), y1 = min(h - 1, Int(ceil(max(p[0].1, p[1].1, p[2].1))))
                guard x0 <= x1, y0 <= y1 else { continue }
                let r = UInt8(min(255, Double(rgb.0) * shade)), g = UInt8(min(255, Double(rgb.1) * shade)),
                    bl = UInt8(min(255, Double(rgb.2) * shade))
                for py in y0...y1 {
                    let fy = Double(py) + 0.5
                    for px in x0...x1 {
                        let fx = Double(px) + 0.5
                        let w0 = ((p[1].0 - fx) * (p[2].1 - fy) - (p[2].0 - fx) * (p[1].1 - fy)) / area
                        let w1 = ((p[2].0 - fx) * (p[0].1 - fy) - (p[0].0 - fx) * (p[2].1 - fy)) / area
                        let w2 = 1 - w0 - w1
                        guard w0 >= -1e-9, w1 >= -1e-9, w2 >= -1e-9 else { continue }
                        let d = w0 * p[0].2 + w1 * p[1].2 + w2 * p[2].2
                        let i = py * w + px
                        guard d > depth[i] else { continue }
                        depth[i] = d
                        color[i * 4] = r; color[i * 4 + 1] = g; color[i * 4 + 2] = bl; color[i * 4 + 3] = 255
                    }
                }
            }
        }
        // Downsample 2×2 → 1 (premultiplied average keeps edges clean on transparency).
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var acc = (0, 0, 0, 0)
                for dy in 0..<ss {
                    for dx in 0..<ss {
                        let i = ((y * ss + dy) * w + x * ss + dx) * 4
                        let a = Int(color[i + 3])
                        acc.0 += Int(color[i]) * a; acc.1 += Int(color[i + 1]) * a; acc.2 += Int(color[i + 2]) * a; acc.3 += a
                    }
                }
                let o = (y * width + x) * 4
                if acc.3 > 0 {
                    pixels[o] = UInt8(acc.0 / acc.3); pixels[o + 1] = UInt8(acc.1 / acc.3); pixels[o + 2] = UInt8(acc.2 / acc.3)
                    pixels[o + 3] = UInt8(acc.3 / (ss * ss))
                }
            }
        }
        return png(rgba: pixels, width: width, height: height)
    }

    /// Minimal PNG encoder (8-bit RGBA, no filtering).
    static func png(rgba: [UInt8], width: Int, height: Int) -> Data {
        var raw = Data(capacity: (width * 4 + 1) * height)
        for y in 0..<height {
            raw.append(0)
            raw.append(contentsOf: rgba[(y * width * 4)..<((y + 1) * width * 4)])
        }
        var deflated = Data(count: czip_deflate_bound(raw.count))
        let size = raw.withUnsafeBytes { src in
            deflated.withUnsafeMutableBytes { dst in
                czip_deflate_raw(src.bindMemory(to: UInt8.self).baseAddress, raw.count,
                                 dst.bindMemory(to: UInt8.self).baseAddress, dst.count)
            }
        }
        deflated.count = max(0, size)
        var zlib = Data([0x78, 0x01])
        zlib.append(deflated)
        zlib.appendBE(adler32(raw))

        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func chunk(_ type: String, _ body: Data) {
            out.appendBE(UInt32(body.count))
            var typed = Data(type.utf8)
            typed.append(body)
            out.append(typed)
            out.appendBE(typed.withUnsafeBytes { czip_crc32($0.bindMemory(to: UInt8.self).baseAddress, typed.count) })
        }
        var header = Data()
        header.appendBE(UInt32(width)); header.appendBE(UInt32(height))
        header.append(contentsOf: [8, 6, 0, 0, 0]) // 8 bit, RGBA, deflate, no filter, no interlace
        chunk("IHDR", header)
        chunk("IDAT", zlib)
        chunk("IEND", Data())
        return out
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    static func rgbBytes(_ hex: String) -> (UInt8, UInt8, UInt8) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count >= 6, let v = UInt32(s.prefix(6), radix: 16) else { return (154, 160, 166) }
        var rgb = (UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
        // Very dark filament would vanish on the printer's dark screen; lift it a little.
        if Int(rgb.0) + Int(rgb.1) + Int(rgb.2) < 120 { rgb = (70, 70, 74) }
        return rgb
    }

    /// G-code comment block with base64 PNGs, as OrcaSlicer writes it (Moonraker and the printers read this).
    public static func gcodeBlock(_ images: [(width: Int, height: Int, png: Data)]) -> [String] {
        guard !images.isEmpty else { return [] }
        var lines = ["; THUMBNAIL_BLOCK_START"]
        for image in images {
            let b64 = image.png.base64EncodedString()
            lines.append(";")
            lines.append("; thumbnail begin \(image.width)x\(image.height) \(b64.count)")
            var index = b64.startIndex
            while index < b64.endIndex {
                let end = b64.index(index, offsetBy: 78, limitedBy: b64.endIndex) ?? b64.endIndex
                lines.append("; " + b64[index..<end])
                index = end
            }
            lines.append("; thumbnail end")
        }
        lines.append("; THUMBNAIL_BLOCK_END")
        return lines
    }
}

private extension Data {
    mutating func appendBE(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }
}
