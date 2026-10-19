import Foundation

public enum ExtrusionRole: String, CaseIterable, Codable, Sendable {
    case outerWall, innerWall, topSurface, bottomSurface, solidInfill, sparseInfill
    case bridge, ironing, primeTower
    case support, supportInterface, skirt, brim

    /// Label used in ";TYPE:" comments (Orca-compatible, so G-code viewers understand it).
    public var gcodeLabel: String {
        switch self {
        case .outerWall: return "Outer wall"
        case .innerWall: return "Inner wall"
        case .topSurface: return "Top surface"
        case .bottomSurface: return "Bottom surface"
        case .solidInfill: return "Internal solid infill"
        case .sparseInfill: return "Sparse infill"
        case .support: return "Support"
        case .supportInterface: return "Support interface"
        case .skirt: return "Skirt"
        case .brim: return "Brim"
        case .bridge: return "Bridge"
        case .ironing: return "Ironing"
        case .primeTower: return "Prime tower"
        }
    }

    public var displayName: String {
        switch self {
        case .outerWall: return "Außenwand"
        case .innerWall: return "Innenwand"
        case .topSurface: return "Oberfläche"
        case .bottomSurface: return "Unterseite"
        case .solidInfill: return "Massive Füllung"
        case .sparseInfill: return "Füllung"
        case .support: return "Stütze"
        case .supportInterface: return "Stützen-Kontakt"
        case .skirt: return "Skirt"
        case .brim: return "Brim"
        case .bridge: return "Brücke"
        case .ironing: return "Glätten"
        case .primeTower: return "Reinigungsturm"
        }
    }
}

/// One continuous extrusion.
public struct Extrusion: Sendable {
    public var role: ExtrusionRole
    public var points: Path
    public var closed: Bool
    /// Line width in mm.
    public var width: Double
    /// Target speed in mm/s before cooling slow-down and flow limits.
    public var speed: Double
    /// Extrusion multiplier on top of the filament's flow ratio (ironing ≈ 0.1, bridges ≈ 0.9).
    public var flow: Double

    public init(role: ExtrusionRole, points: Path, closed: Bool, width: Double, speed: Double, flow: Double = 1) {
        self.role = role
        self.points = points
        self.closed = closed
        self.width = width
        self.speed = speed
        self.flow = flow
    }

    public var lengthMM: Double {
        guard points.count >= 2 else { return 0 }
        var length = 0.0
        for i in 1..<points.count { length += points[i - 1].distance(to: points[i]) }
        if closed { length += points[points.count - 1].distance(to: points[0]) }
        return length / Units.perMM
    }
}

/// Everything one tool prints within a layer.
public struct ToolIsland: Sendable {
    public var tool: Int
    public var extrusions: [Extrusion]

    public init(tool: Int, extrusions: [Extrusion]) {
        self.tool = tool
        self.extrusions = extrusions
    }
}

public struct SlicedLayer: Sendable {
    public var index: Int
    /// Top of the layer in mm.
    public var z: Double
    public var height: Double
    public var islands: [ToolIsland]
    /// Outline of the printed part (all tools) – handy for previews.
    public var outline: Polygons
}
