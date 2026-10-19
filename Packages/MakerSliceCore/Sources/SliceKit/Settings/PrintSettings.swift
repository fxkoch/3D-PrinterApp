import Foundation

public enum InfillPattern: String, Codable, CaseIterable, Sendable, Identifiable {
    case lines, grid, triangles, cubic
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .lines: return "Linien"
        case .grid: return "Gitter"
        case .triangles: return "Dreiecke"
        case .cubic: return "Kubisch"
        }
    }
}

public enum SupportMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, buildPlateOnly, everywhere
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .off: return "Aus"
        case .buildPlateOnly: return "Nur vom Druckbett"
        case .everywhere: return "Überall"
        }
    }
}

public enum PlateType: String, Codable, CaseIterable, Sendable, Identifiable {
    case texturedPEI = "Textured PEI Plate"
    case highTemp = "High Temp Plate"
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .texturedPEI: return "Strukturierte PEI-Platte"
        case .highTemp: return "Glatte PEI-Platte (High Temp)"
        }
    }
}

/// Material preset. Values follow the Snapmaker U1 Orca profiles.
public struct Filament: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var type: String
    public var nozzleTemp: Int
    public var firstLayerNozzleTemp: Int
    public var bedTemp: Int
    public var firstLayerBedTemp: Int
    /// Part cooling fan speed in 0...1.
    public var fanSpeed: Double
    /// Layers printed without part cooling at the start.
    public var fanOffLayers: Int
    /// Maximum volumetric flow in mm³/s.
    public var maxVolumetricSpeed: Double
    public var retractLength: Double
    public var flowRatio: Double
    /// Glass transition temperature – drives the U1 chamber purifier mode.
    public var vitrificationTemp: Int
    /// g/cm³, for weight estimates.
    public var density: Double
    /// Hex colour "#RRGGBB" for previews.
    public var color: String

    public init(name: String, type: String, nozzleTemp: Int, firstLayerNozzleTemp: Int? = nil,
                bedTemp: Int, firstLayerBedTemp: Int? = nil, fanSpeed: Double, fanOffLayers: Int = 1,
                maxVolumetricSpeed: Double, retractLength: Double = 0.8, flowRatio: Double = 0.98,
                vitrificationTemp: Int, density: Double, color: String = "#FCE94F") {
        self.name = name
        self.type = type
        self.nozzleTemp = nozzleTemp
        self.firstLayerNozzleTemp = firstLayerNozzleTemp ?? nozzleTemp
        self.bedTemp = bedTemp
        self.firstLayerBedTemp = firstLayerBedTemp ?? bedTemp
        self.fanSpeed = fanSpeed
        self.fanOffLayers = fanOffLayers
        self.maxVolumetricSpeed = maxVolumetricSpeed
        self.retractLength = retractLength
        self.flowRatio = flowRatio
        self.vitrificationTemp = vitrificationTemp
        self.density = density
        self.color = color
    }

    public static let pla = Filament(name: "Generic PLA", type: "PLA", nozzleTemp: 220, bedTemp: 60, firstLayerBedTemp: 65,
                                     fanSpeed: 1, maxVolumetricSpeed: 12, vitrificationTemp: 45, density: 1.24)
    public static let plaHighSpeed = Filament(name: "Generic PLA High Speed", type: "PLA", nozzleTemp: 230, bedTemp: 60, firstLayerBedTemp: 65,
                                              fanSpeed: 1, maxVolumetricSpeed: 21, vitrificationTemp: 45, density: 1.24)
    public static let plaCF = Filament(name: "Generic PLA-CF", type: "PLA-CF", nozzleTemp: 230, bedTemp: 60,
                                       fanSpeed: 1, maxVolumetricSpeed: 12, vitrificationTemp: 45, density: 1.21)
    public static let petg = Filament(name: "Generic PETG", type: "PETG", nozzleTemp: 250, firstLayerNozzleTemp: 245, bedTemp: 70,
                                      fanSpeed: 0.4, fanOffLayers: 3, maxVolumetricSpeed: 10, retractLength: 1.0,
                                      vitrificationTemp: 64, density: 1.27)
    public static let tpu = Filament(name: "Generic TPU", type: "TPU", nozzleTemp: 230, bedTemp: 40,
                                     fanSpeed: 0.7, maxVolumetricSpeed: 3.6, retractLength: 0.4, flowRatio: 1.0,
                                     vitrificationTemp: 30, density: 1.21)
    public static let abs = Filament(name: "Generic ABS", type: "ABS", nozzleTemp: 260, bedTemp: 100,
                                     fanSpeed: 0.3, fanOffLayers: 3, maxVolumetricSpeed: 16, vitrificationTemp: 94, density: 1.05)
    public static let asa = Filament(name: "Generic ASA", type: "ASA", nozzleTemp: 260, bedTemp: 100,
                                     fanSpeed: 0.3, fanOffLayers: 3, maxVolumetricSpeed: 16, vitrificationTemp: 100, density: 1.07)

    public static let presets: [Filament] = [.pla, .plaHighSpeed, .plaCF, .petg, .tpu, .abs, .asa]
}

/// Everything the slicer needs. Defaults mirror "0.20 Standard @Snapmaker U1 (0.4 nozzle)".
public struct PrintSettings: Codable, Equatable, Sendable {
    // Quality
    public var layerHeight: Double = 0.2
    public var firstLayerHeight: Double = 0.25
    public var nozzleDiameter: Double = 0.4
    public var lineWidth: Double = 0.45
    public var outerWallLineWidth: Double = 0.42
    public var firstLayerLineWidth: Double = 0.5

    // Strength
    public var wallLoops: Int = 2
    public var topLayers: Int = 5
    public var bottomLayers: Int = 3
    public var infillDensity: Double = 0.15
    public var infillPattern: InfillPattern = .grid
    /// Infill/wall overlap as a fraction of the line width.
    public var infillOverlap: Double = 0.15

    // Speed (mm/s)
    public var outerWallSpeed: Double = 200
    public var innerWallSpeed: Double = 300
    public var infillSpeed: Double = 270
    public var solidInfillSpeed: Double = 250
    public var topSurfaceSpeed: Double = 200
    public var firstLayerSpeed: Double = 50
    public var firstLayerInfillSpeed: Double = 105
    public var supportSpeed: Double = 150
    public var travelSpeed: Double = 500
    public var acceleration: Double = 10000
    public var outerWallAcceleration: Double = 5000
    /// Layers faster than this (seconds) get slowed down for cooling.
    public var minLayerTime: Double = 4

    // Support & adhesion
    public var support: SupportMode = .off
    public var supportAngle: Double = 30
    public var supportTopZDistance: Double = 0.2
    public var supportXYDistance: Double = 0.35
    public var supportSpacing: Double = 2.5
    public var brimWidth: Double = 0
    public var skirtLoops: Int = 1
    public var skirtDistance: Double = 3

    // Travel
    public var retractSpeed: Double = 30
    public var retractMinTravel: Double = 1
    public var zHop: Double = 0.4

    // Machine
    public var plateType: PlateType = .texturedPEI
    public var bedSize: Double = 270
    public var maxHeight: Double = 270
    /// Material loaded in each of the four U1 tool heads.
    public var filaments: [Filament] = [.pla, .pla, .pla, .pla]
    public var enableTimelapse: Bool = true
    public var enableBedLeveling: Bool = true

    public init() {}

    public func filament(for tool: Int) -> Filament {
        filaments.indices.contains(tool) ? filaments[tool] : filaments.first ?? .pla
    }

    /// Applies values from a Bambu/Orca project file, keeping U1 machine settings.
    public mutating func apply(_ project: ProjectSettings) {
        if let v = project.layerHeight, (0.05...0.4).contains(v) { layerHeight = v }
        if let v = project.firstLayerHeight, (0.1...0.4).contains(v) { firstLayerHeight = v }
        if let v = project.wallLoops, (1...10).contains(v) { wallLoops = v }
        if let v = project.topLayers, (0...20).contains(v) { topLayers = v }
        if let v = project.bottomLayers, (0...20).contains(v) { bottomLayers = v }
        if let v = project.infillDensity, (0...1).contains(v) { infillDensity = v }
        if let v = project.supportEnabled { support = v ? .buildPlateOnly : .off }
        for (i, type) in project.filamentTypes.prefix(4).enumerated() {
            if let preset = Filament.presets.first(where: { $0.type.caseInsensitiveCompare(type) == .orderedSame }) {
                filaments[i] = preset
            }
        }
        for (i, color) in project.filamentColors.prefix(4).enumerated() where color.hasPrefix("#") {
            filaments[i].color = String(color.prefix(7))
        }
    }

    /// Quick presets shown in the simple slicer UI.
    public enum Quality: String, CaseIterable, Identifiable, Sendable {
        case draft, standard, fine
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .draft: return "Schnell (0,28 mm)"
            case .standard: return "Standard (0,20 mm)"
            case .fine: return "Fein (0,12 mm)"
            }
        }
        public var layerHeight: Double {
            switch self {
            case .draft: return 0.28
            case .standard: return 0.2
            case .fine: return 0.12
            }
        }
    }

    public mutating func apply(_ quality: Quality) {
        layerHeight = quality.layerHeight
        firstLayerHeight = quality == .fine ? 0.2 : 0.25
        topLayers = Int((1.0 / quality.layerHeight).rounded(.up))
        bottomLayers = Int((0.6 / quality.layerHeight).rounded(.up))
    }
}
