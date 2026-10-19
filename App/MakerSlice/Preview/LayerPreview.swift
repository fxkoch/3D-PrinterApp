import SliceKit
import SwiftUI

/// Top-down view of one sliced layer, coloured by line type.
struct LayerPreview: View {
    let layers: [SlicedLayer]
    let upTo: Int
    let filaments: [Filament]

    var body: some View {
        let index = min(max(upTo, 0), layers.count - 1)
        let layer = layers[index]
        let previous = index > 0 ? layers[index - 1] : nil
        let bounds = Self.bounds(of: layers)

        VStack(spacing: 4) {
            Canvas { context, size in
                let scale = min(size.width / bounds.width, size.height / bounds.height) * 0.92
                let offset = CGPoint(x: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
                                     y: (size.height + bounds.height * scale) / 2 + bounds.minY * scale)
                func point(_ p: IntPoint) -> CGPoint {
                    CGPoint(x: p.mmX * scale + offset.x, y: offset.y - p.mmY * scale)
                }
                // Previous layer as a faint outline for context.
                if let previous {
                    var outline = Path()
                    for poly in previous.outline.paths {
                        outline.addLines(poly.map(point))
                        outline.closeSubpath()
                    }
                    context.stroke(outline, with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)
                }
                for island in layer.islands {
                    for e in island.extrusions {
                        var path = Path()
                        path.addLines(e.points.map(point))
                        if e.closed { path.closeSubpath() }
                        let color = Self.color(for: e.role, tool: island.tool, filaments: filaments)
                        context.stroke(path, with: .color(color),
                                       style: StrokeStyle(lineWidth: max(0.6, e.width * scale), lineCap: .round, lineJoin: .round))
                    }
                }
            }
            legend(for: layer)
        }
    }

    private func legend(for layer: SlicedLayer) -> some View {
        let roles = Set(layer.islands.flatMap { $0.extrusions.map(\.role) })
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ExtrusionRole.allCases.filter(roles.contains), id: \.self) { role in
                    HStack(spacing: 4) {
                        Circle().fill(Self.color(for: role, tool: 0, filaments: filaments)).frame(width: 8, height: 8)
                        Text(role.displayName).font(.caption2)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    static func color(for role: ExtrusionRole, tool: Int, filaments: [Filament]) -> Color {
        switch role {
        case .outerWall: return Color(hex: filaments[min(tool, filaments.count - 1)].color)
        case .innerWall: return .orange
        case .topSurface: return .red
        case .bottomSurface: return .purple
        case .solidInfill: return .indigo
        case .sparseInfill: return .green.opacity(0.8)
        case .support: return .gray
        case .supportInterface: return Color(white: 0.35)
        case .skirt, .brim: return .teal
        }
    }

    /// Area covered by the print, in mm.
    static func bounds(of layers: [SlicedLayer]) -> CGRect {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for layer in layers.prefix(1) + layers.dropFirst().filter({ $0.index % 10 == 0 }) {
            for island in layer.islands {
                for e in island.extrusions {
                    for p in e.points {
                        minX = min(minX, p.mmX); maxX = max(maxX, p.mmX)
                        minY = min(minY, p.mmY); maxY = max(maxY, p.mmY)
                    }
                }
            }
        }
        guard minX.isFinite else { return CGRect(x: 0, y: 0, width: 270, height: 270) }
        let pad = 3.0
        return CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad)
    }
}

extension Color {
    /// "#RRGGBB" → Color (falls back to gray).
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count >= 6, let value = UInt32(cleaned.prefix(6), radix: 16) else {
            self = .gray
            return
        }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    /// Black or white, whichever reads better on this colour.
    var contrastingText: Color {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.6 ? .black : .white
    }
}
