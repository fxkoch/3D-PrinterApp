import Foundation

/// What the print should be good at. Each goal sets layer height, walls, shells and infill – adapted to the filament
/// (TPU always prints gyroid, PETG and ABS get less part cooling when the part must hold together).
public enum PrintPurpose: String, Codable, CaseIterable, Identifiable, Sendable {
    case balanced, robust, strong, light, saving, fast, fastStrong, fine

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .balanced: return "Ausgewogen"
        case .robust: return "Robust"
        case .strong: return "Stabil"
        case .light: return "Leicht"
        case .saving: return "Filament sparen"
        case .fast: return "Schnell"
        case .fastStrong: return "Schnell & stabil"
        case .fine: return "Schön"
        }
    }

    public var symbol: String {
        switch self {
        case .balanced: return "dial.medium"
        case .robust: return "shield"
        case .strong: return "cube.fill"
        case .light: return "feather"
        case .saving: return "leaf"
        case .fast: return "hare"
        case .fastStrong: return "bolt.shield"
        case .fine: return "sparkles"
        }
    }

    /// One line for the menu.
    public var summary: String {
        switch self {
        case .balanced: return "Guter Standard für fast alles."
        case .robust: return "Zäh und bruchfest: viele Wände, für Halter, Clips, Werkzeug."
        case .strong: return "Steif und tragfähig: fünf Wände, für Teile unter Last."
        case .light: return "Möglichst leicht: wenig Füllung, für Deko, Lampen, Modellbau."
        case .saving: return "Wenig Filament und Abfall bei brauchbarer Festigkeit."
        case .fast: return "Kürzeste Druckzeit: dicke Schichten, wenig Füllung."
        case .fastStrong: return "Zügig, aber belastbar: dicke Schichten, drei Wände, kubische Füllung."
        case .fine: return "Sichtteile: feine Schichten, ruhige Außenwand, Naht in Ecken."
        }
    }

    /// What this goal means for one filament (shown under the menu).
    public func note(for filament: Filament) -> String? {
        let type = filament.type.uppercased()
        if filament.isFlexible {
            switch self {
            case .fast, .fastStrong: return "\(filament.type) bleibt langsam (max. \(formatDecimal(filament.maxVolumetricSpeed, digits: 1)) mm³/s) – dicke Schichten sparen trotzdem Zeit."
            default: return "\(filament.type) druckt immer mit Gyroid-Füllung, die gleichmäßig federt."
            }
        }
        if (type.hasPrefix("PETG") || type.hasPrefix("PCTG") || filament.needsEnclosure), self == .robust || self == .strong || self == .fastStrong {
            return "\(filament.type): Bauteillüfter höchstens \(Int(Self.bondingFan(for: filament) * 100)) %, damit die Schichten fest verbinden."
        }
        if self == .fast { return "Das Tempo begrenzt der maximale Fluss von \(filament.name): \(formatDecimal(filament.maxVolumetricSpeed, digits: 1)) mm³/s." }
        return nil
    }

    /// Part cooling for goals where the layers must hold together.
    static func bondingFan(for f: Filament) -> Double { f.needsEnclosure ? 0.2 : 0.3 }

    /// Layer height, shells and infill of the goal (0.4 mm nozzle; thicker layers are limited by the nozzle).
    struct Values {
        var layerHeight: Double
        var walls: Int
        var topMM: Double
        var bottomMM: Double
        var infill: Double
        var pattern: InfillPattern
    }

    var values: Values {
        switch self {
        case .balanced: return Values(layerHeight: 0.2, walls: 2, topMM: 1.0, bottomMM: 0.6, infill: 0.15, pattern: .grid)
        case .robust: return Values(layerHeight: 0.2, walls: 4, topMM: 1.2, bottomMM: 1.0, infill: 0.25, pattern: .gyroid)
        // Walls carry load better than infill (CNC Kitchen: 2 → 4 walls about +65 %; above 40 % infill adds little);
        // Bambu's and the U1's "Strength" profiles use 6 walls and 25 %.
        case .strong: return Values(layerHeight: 0.2, walls: 5, topMM: 1.2, bottomMM: 1.0, infill: 0.3, pattern: .gyroid)
        case .light: return Values(layerHeight: 0.2, walls: 2, topMM: 0.8, bottomMM: 0.6, infill: 0.06, pattern: .gyroid)
        case .saving: return Values(layerHeight: 0.24, walls: 2, topMM: 0.8, bottomMM: 0.6, infill: 0.1, pattern: .gyroid)
        case .fast: return Values(layerHeight: 0.28, walls: 2, topMM: 0.84, bottomMM: 0.56, infill: 0.1, pattern: .grid)
        case .fastStrong: return Values(layerHeight: 0.24, walls: 3, topMM: 1.0, bottomMM: 0.72, infill: 0.2, pattern: .cubic)
        case .fine: return Values(layerHeight: 0.12, walls: 3, topMM: 1.0, bottomMM: 0.6, infill: 0.15, pattern: .gyroid)
        }
    }
}

extension PrintSettings {
    /// Sets the values of a print goal. The same goal twice gives the same settings: everything the goal touches starts
    /// from the printer's defaults, so switching goals back and forth never piles up.
    /// - Parameter usedTools: slots the print uses (material adjustments only for them); nil = slot 1.
    public mutating func apply(_ purpose: PrintPurpose, usedTools: [Int]? = nil) {
        let base = PrintSettings(printer: printer)
        let v = purpose.values
        // Never thicker than 70 % of the nozzle.
        layerHeight = min(v.layerHeight, (nozzleDiameter * 0.7 * 100).rounded(.down) / 100)
        firstLayerHeight = printer == .snapmakerU1 && layerHeight >= 0.2 ? 0.25 : 0.2
        wallLoops = v.walls
        topLayers = max(3, Int((v.topMM / layerHeight).rounded(.up)))
        bottomLayers = max(2, Int((v.bottomMM / layerHeight).rounded(.up)))
        infillDensity = v.infill
        infillPattern = v.pattern
        outerWallSpeed = purpose == .fine ? min(base.outerWallSpeed, 100) : base.outerWallSpeed
        seamPosition = purpose == .fine ? .corner : base.seamPosition
        skirtLoops = purpose == .saving ? 0 : base.skirtLoops
        purgeVolume = purpose == .saving && base.purgeVolume > 0 ? max(10, (base.purgeVolume * 0.7).rounded()) : base.purgeVolume
        for i in (usedTools ?? [0]) where filaments.indices.contains(i) {
            let f = filaments[i]
            if f.isFlexible { infillPattern = .gyroid }
            if [.robust, .strong, .fastStrong].contains(purpose),
               f.needsEnclosure || f.type.uppercased().hasPrefix("PETG") || f.type.uppercased().hasPrefix("PCTG") {
                filaments[i].fanSpeed = min(f.fanSpeed, PrintPurpose.bondingFan(for: f))
                filaments[i].fanMinSpeed = min(f.fanMinSpeed, filaments[i].fanSpeed)
            }
        }
        self.purpose = purpose
    }
}
