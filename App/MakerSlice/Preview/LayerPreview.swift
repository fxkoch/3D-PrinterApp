import SliceKit
import SwiftUI

/// Top-down view of one sliced layer, coloured by line type.
struct LayerPreview: View {
    let layers: [SlicedLayer]
    let index: Int
    let filaments: [Filament]

    var body: some View {
        let layer = layers[index]
        let previous: SlicedLayer? = index > 0 ? layers[index - 1] : nil
        let bounds = LayerPreview.bounds(of: layers)
        VStack(spacing: 4) {
            Canvas { context, size in
                LayerPreview.draw(layer: layer, previous: previous, bounds: bounds, filaments: filaments,
                                  in: &context, size: size)
            }
            legend(for: layer)
        }
    }

    private static func draw(layer: SlicedLayer, previous: SlicedLayer?, bounds: CGRect, filaments: [Filament],
                             in context: inout GraphicsContext, size: CGSize) {
        let scale = min(size.width / bounds.width, size.height / bounds.height) * 0.92
        let offsetX = (size.width - bounds.width * scale) / 2 - bounds.minX * scale
        let offsetY = (size.height + bounds.height * scale) / 2 + bounds.minY * scale
        func point(_ p: IntPoint) -> CGPoint {
            CGPoint(x: p.mmX * scale + offsetX, y: offsetY - p.mmY * scale)
        }
        if let previous {
            var outline = SwiftUI.Path()
            for poly in previous.outline.paths {
                outline.addLines(poly.map(point))
                outline.closeSubpath()
            }
            context.stroke(outline, with: .color(Color.secondary.opacity(0.35)), lineWidth: 0.5)
        }
        for island in layer.islands {
            for e in island.extrusions {
                var path = SwiftUI.Path()
                path.addLines(e.points.map(point))
                if e.closed { path.closeSubpath() }
                let color = color(for: e.role, tool: island.tool, filaments: filaments)
                let style = StrokeStyle(lineWidth: max(0.6, e.width * scale), lineCap: .round, lineJoin: .round)
                context.stroke(path, with: .color(color), style: style)
            }
        }
    }

    private func legend(for layer: SlicedLayer) -> some View {
        let roles = Set(layer.islands.flatMap { $0.extrusions.map(\.role) })
        let visible = ExtrusionRole.allCases.filter { roles.contains($0) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(visible, id: \.self) { role in
                    HStack(spacing: 4) {
                        Circle().fill(LayerPreview.color(for: role, tool: 0, filaments: filaments)).frame(width: 8, height: 8)
                        Text(role.displayName).font(.caption2)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    static func color(for role: ExtrusionRole, tool: Int, filaments: [Filament]) -> Color {
        switch role {
        case .outerWall:
            let i = min(max(tool, 0), max(filaments.count - 1, 0))
            return filaments.isEmpty ? .blue : Color(hex: filaments[i].color)
        case .innerWall: return .orange
        case .topSurface: return .red
        case .bottomSurface: return .purple
        case .solidInfill: return .indigo
        case .sparseInfill: return Color.green.opacity(0.8)
        case .bridge: return .brown
        case .ironing: return .pink
        case .primeTower: return .mint
        case .support: return .gray
        case .supportInterface: return Color(white: 0.35)
        case .skirt, .brim: return .teal
        }
    }

    /// Area covered by the print, in mm.
    static func bounds(of layers: [SlicedLayer]) -> CGRect {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        let sample = layers.enumerated().filter { $0.offset == 0 || $0.offset % 10 == 0 }.map(\.element)
        for layer in sample {
            for island in layer.islands {
                for e in island.extrusions {
                    for p in e.points {
                        minX = min(minX, p.mmX)
                        maxX = max(maxX, p.mmX)
                        minY = min(minY, p.mmY)
                        maxY = max(maxY, p.mmY)
                    }
                }
            }
        }
        guard minX.isFinite else { return CGRect(x: 0, y: 0, width: 270, height: 270) }
        let pad = 3.0
        return CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad)
    }
}
