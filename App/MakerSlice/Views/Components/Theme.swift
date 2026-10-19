import SwiftUI

/// Small design system: calm, macOS-like surfaces with clear hierarchy.
enum Theme {
    static let corner: CGFloat = 12
    static let spacing: CGFloat = 12
}

/// A grouped surface like a macOS settings pane.
struct Panel<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label {
                    Text(title)
                } icon: {
                    if let systemImage { Image(systemName: systemImage) }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

/// Compact value with a caption, used in dashboards.
struct Metric: View {
    var value: String
    var caption: String
    var systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary).font(.caption) }
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A coloured filament swatch with a slot label.
struct Swatch: View {
    var color: String
    var label: String
    var selected = false
    var size: CGFloat = 28

    var body: some View {
        let fill = Color(hex: color)
        ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            if selected { Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).padding(-3) }
            Text(label).font(.system(size: size * 0.38, weight: .bold, design: .rounded)).foregroundStyle(fill.contrastingText)
        }
        .frame(width: size, height: size)
    }
}

/// Pill-shaped status label.
struct StatusBadge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
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
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    var hexString: String {
        let components = UIColor(self).rgba
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(components.r), byte(components.g), byte(components.b))
    }

    /// Black or white, whichever reads better on this colour.
    var contrastingText: Color {
        let c = UIColor(self).rgba
        let luminance = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
        return luminance > 0.6 ? .black : .white
    }

    /// RGB 0…255 for printer APIs.
    var rgbBytes: [Int] {
        let c = UIColor(self).rgba
        return [c.r, c.g, c.b].map { Int((min(max($0, 0), 1) * 255).rounded()) }
    }
}

extension UIColor {
    var rgba: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }
}

enum Format {
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(max(m, 0)) min"
    }

    static func temp(_ value: Double) -> String { "\(Int(value.rounded())) °C" }
}
