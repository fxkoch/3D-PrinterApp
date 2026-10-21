import Foundation

/// Suggests which printer slot prints each colour of a multi-colour project.
public enum ColorMapper {
    /// - Parameters:
    ///   - colors: colours the project uses.
    ///   - slotColors: current colour of every printer slot ("#RRGGBB").
    /// - Returns: file colour (extruder index) → slot. Keeps the file's numbering when every colour has a slot;
    ///   with more colours than slots the nearest slot colour is used.
    public static func suggest(colors: [ModelColor], slotColors: [String]) -> [Int: Int] {
        let slots = max(slotColors.count, 1)
        if colors.allSatisfy({ $0.tool < slots }) { return Dictionary(uniqueKeysWithValues: colors.map { ($0.tool, $0.tool) }) }
        var map: [Int: Int] = [:]
        var free = Set(0..<slots)
        // Colours that already fit keep their slot, the others take the nearest free one.
        for color in colors where color.tool < slots {
            map[color.tool] = color.tool
            free.remove(color.tool)
        }
        for color in colors where color.tool >= slots {
            let candidates = free.isEmpty ? Set(0..<slots) : free
            let best = candidates.min { distance(color.colorHex, slotColors[$0]) < distance(color.colorHex, slotColors[$1]) } ?? 0
            map[color.tool] = best
            free.remove(best)
        }
        return map
    }

    static func rgb(_ hex: String) -> (Double, Double, Double) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count >= 6, let v = Int(h.prefix(6), radix: 16) else { return (0.5, 0.5, 0.5) }
        return (Double(v >> 16 & 255), Double(v >> 8 & 255), Double(v & 255))
    }

    static func distance(_ a: String, _ b: String) -> Double {
        let (x, y) = (rgb(a), rgb(b))
        return (x.0 - y.0) * (x.0 - y.0) + (x.1 - y.1) * (x.1 - y.1) + (x.2 - y.2) * (x.2 - y.2)
    }
}
