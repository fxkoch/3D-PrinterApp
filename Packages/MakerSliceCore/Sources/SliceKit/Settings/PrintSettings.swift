import Foundation

public enum InfillPattern: String, Codable, CaseIterable, Sendable, Identifiable {
    case lines, grid, triangles, cubic, gyroid
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .lines: return "Linien"
        case .grid: return "Gitter"
        case .triangles: return "Dreiecke"
        case .cubic: return "Kubisch"
        case .gyroid: return "Gyroid"
        }
    }

    public var explanation: String {
        switch self {
        case .lines: return "Am schnellsten, aber nur in einer Richtung je Schicht stabil."
        case .grid: return "Schnell und solide – guter Standard."
        case .triangles: return "Sehr steif in der Ebene, gut für flache Teile."
        case .cubic: return "Stabil in alle Richtungen bei wenig Material."
        case .gyroid: return "Gleichmäßig fest in alle Richtungen, ideal für Funktionsteile und flexible Materialien."
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
        case .highTemp: return "Glatte PEI-Platte"
        }
    }
}

/// Where each wall loop starts and ends (the visible "seam").
public enum SeamPosition: String, Codable, CaseIterable, Sendable, Identifiable {
    case aligned, corner, random
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .aligned: return "Hinten ausgerichtet"
        case .corner: return "In Ecken versteckt"
        case .random: return "Zufällig verteilt"
        }
    }
}

/// Order of the wall loops within a layer.
public enum WallOrder: String, Codable, CaseIterable, Sendable, Identifiable {
    case innerOuter, outerInner
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .innerOuter: return "Innen → außen"
        case .outerInner: return "Außen → innen"
        }
    }
}

/// Line pattern for visible top and bottom surfaces.
public enum SurfacePattern: String, Codable, CaseIterable, Sendable, Identifiable {
    case monotonic, lines, concentric
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .monotonic: return "Monoton"
        case .lines: return "Linien"
        case .concentric: return "Konzentrisch"
        }
    }
}

/// Everything the slicer needs. Defaults mirror the "0.20mm Standard" Orca profiles.
public struct PrintSettings: Codable, Equatable, Sendable {
    public var printer: PrinterModel = .snapmakerU1

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
    /// Layers faster than this (seconds) get slowed down for cooling (0 = filament default).
    public var minLayerTime: Double = 0

    // Surfaces
    public var ironing: Bool = false
    public var ironingSpeed: Double = 30
    /// Ironing flow as a fraction of a normal line.
    public var ironingFlow: Double = 0.1
    public var ironingSpacing: Double = 0.15
    public var detectBridges: Bool = true
    public var bridgeSpeed: Double = 50
    public var bridgeFlow: Double = 0.9
    public var topSurfacePattern: SurfacePattern = .monotonic
    public var bottomSurfacePattern: SurfacePattern = .monotonic

    // Walls & special modes
    public var seamPosition: SeamPosition = .aligned
    public var wallOrder: WallOrder = .innerOuter
    /// Shrinks the first layer inwards (mm) so the squished line doesn't bulge out.
    public var elephantFootCompensation: Double = 0.15
    /// Spiral vase: one continuous outer wall, rising steadily, no top and no infill.
    public var spiralVase: Bool = false
    /// Random jitter on the outer wall for a textured, grippy surface.
    public var fuzzySkin: Bool = false
    public var fuzzySkinThickness: Double = 0.3
    public var fuzzySkinPointDistance: Double = 0.8

    // Support & adhesion
    public var support: SupportMode = .off
    public var supportAngle: Double = 30
    public var supportTopZDistance: Double = 0.2
    public var supportXYDistance: Double = 0.35
    public var supportSpacing: Double = 2.5
    public var brimWidth: Double = 0
    public var skirtLoops: Int = 1
    public var skirtDistance: Double = 3

    // Multi-material
    /// Purge tower for single-nozzle multi-material (Kobra S1 + ACE).
    public var primeTower: Bool = false
    public var primeTowerWidth: Double = 30

    // Travel
    public var retractSpeed: Double = 30
    public var retractMinTravel: Double = 1
    public var zHop: Double = 0.4

    // Machine
    public var plateType: PlateType = .texturedPEI
    /// Material loaded in each of the four tool heads / ACE slots.
    public var filaments: [Filament] = [.pla, .pla, .pla, .pla]
    public var enableTimelapse: Bool = true
    public var enableBedLeveling: Bool = true

    public init() {}

    /// Settings with the machine's defaults and its default material.
    public init(printer: PrinterModel) {
        self.printer = printer
        printer.machine.applyDefaults(to: &self)
        let filament = FilamentLibrary.defaultFilament(for: printer)
        filaments = (0..<printer.machine.toolCount).map { i in
            var f = filament
            f.color = PrintSettings.slotColors[i % PrintSettings.slotColors.count]
            return f
        }
    }

    /// Distinct default colours so slots are easy to tell apart before the printer reports its spools.
    public static let slotColors = ["#F5F5F0", "#2B2B2E", "#E5483C", "#2F7DE1"]

    public var machine: MachineProfile { printer.machine }

    /// Settings as the slicer uses them: special modes override conflicting values.
    public var effective: PrintSettings {
        var s = self
        if spiralVase {
            s.wallLoops = 1
            s.topLayers = 0
            s.infillDensity = 0
            s.ironing = false
            s.bottomLayers = max(bottomLayers, 1)
        }
        return s
    }
    public var bedSize: Double { machine.bedSize }
    public var maxHeight: Double { machine.maxHeight }

    public func filament(for tool: Int) -> Filament {
        filaments.indices.contains(tool) ? filaments[tool] : filaments.first ?? .pla
    }

    /// Effective minimum layer time: explicit setting or the strictest used filament.
    public func minLayerTime(for tools: [Int]) -> Double {
        if minLayerTime > 0 { return minLayerTime }
        return tools.map { filament(for: $0).minLayerTime }.max() ?? 4
    }

    /// Switches to another printer, keeping the user's process choices where sensible.
    public mutating func switchPrinter(to model: PrinterModel) {
        guard model != printer else { return }
        let keep = (layerHeight, wallLoops, topLayers, bottomLayers, infillDensity, infillPattern, support, brimWidth, ironing)
        let colors = filaments.map(\.color)
        let types = filaments.map(\.type)
        self = PrintSettings(printer: model)
        (layerHeight, wallLoops, topLayers, bottomLayers, infillDensity, infillPattern, support, brimWidth, ironing) = keep
        for i in filaments.indices {
            if i < types.count, let f = FilamentLibrary.bestMatch(type: types[i], printer: model) { filaments[i] = f }
            if i < colors.count { filaments[i].color = colors[i] }
        }
    }

    /// Applies values from a Bambu/Orca project file, keeping this printer's machine settings.
    public mutating func apply(_ project: ProjectSettings) {
        if let v = project.layerHeight, (0.05...0.4).contains(v) { layerHeight = v }
        if let v = project.firstLayerHeight, (0.1...0.4).contains(v) { firstLayerHeight = v }
        if let v = project.wallLoops, (1...10).contains(v) { wallLoops = v }
        if let v = project.topLayers, (0...20).contains(v) { topLayers = v }
        if let v = project.bottomLayers, (0...20).contains(v) { bottomLayers = v }
        if let v = project.infillDensity, (0...1).contains(v) { infillDensity = v }
        if let p = project.infillPattern { infillPattern = p }
        if let v = project.supportEnabled { support = v ? (project.supportOnBuildPlateOnly == false ? .everywhere : .buildPlateOnly) : .off }
        if let v = project.brimWidth, (0...20).contains(v) { brimWidth = v }
        if let v = project.ironing { ironing = v }
        for (i, type) in project.filamentTypes.prefix(filaments.count).enumerated() {
            let vendor = i < project.filamentVendors.count ? project.filamentVendors[i] : nil
            if let preset = FilamentLibrary.bestMatch(type: type, vendor: vendor, printer: printer) {
                filaments[i] = preset
            }
        }
        for (i, color) in project.filamentColors.prefix(filaments.count).enumerated() where color.hasPrefix("#") {
            filaments[i].color = String(color.prefix(7))
        }
    }

    /// Quick presets shown in the simple slicer UI.
    public enum Quality: String, CaseIterable, Identifiable, Sendable {
        case draft, standard, fine
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .draft: return "Schnell"
            case .standard: return "Standard"
            case .fine: return "Fein"
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
        firstLayerHeight = printer == .kobraS1 ? 0.2 : (quality == .fine ? 0.2 : 0.25)
        topLayers = Int((1.0 / quality.layerHeight).rounded(.up))
        bottomLayers = Int((0.6 / quality.layerHeight).rounded(.up))
    }

    // Tolerant decoding so settings saved by older versions still load.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let v = try? c.decodeIfPresent(T.self, forKey: key) { value = v }
        }
        d(.printer, &printer)
        d(.layerHeight, &layerHeight); d(.firstLayerHeight, &firstLayerHeight); d(.nozzleDiameter, &nozzleDiameter)
        d(.lineWidth, &lineWidth); d(.outerWallLineWidth, &outerWallLineWidth); d(.firstLayerLineWidth, &firstLayerLineWidth)
        d(.wallLoops, &wallLoops); d(.topLayers, &topLayers); d(.bottomLayers, &bottomLayers)
        d(.infillDensity, &infillDensity); d(.infillPattern, &infillPattern); d(.infillOverlap, &infillOverlap)
        d(.outerWallSpeed, &outerWallSpeed); d(.innerWallSpeed, &innerWallSpeed); d(.infillSpeed, &infillSpeed)
        d(.solidInfillSpeed, &solidInfillSpeed); d(.topSurfaceSpeed, &topSurfaceSpeed); d(.firstLayerSpeed, &firstLayerSpeed)
        d(.firstLayerInfillSpeed, &firstLayerInfillSpeed); d(.supportSpeed, &supportSpeed); d(.travelSpeed, &travelSpeed)
        d(.acceleration, &acceleration); d(.outerWallAcceleration, &outerWallAcceleration); d(.minLayerTime, &minLayerTime)
        d(.ironing, &ironing); d(.ironingSpeed, &ironingSpeed); d(.ironingFlow, &ironingFlow); d(.ironingSpacing, &ironingSpacing)
        d(.detectBridges, &detectBridges); d(.bridgeSpeed, &bridgeSpeed); d(.bridgeFlow, &bridgeFlow)
        d(.support, &support); d(.supportAngle, &supportAngle); d(.supportTopZDistance, &supportTopZDistance)
        d(.supportXYDistance, &supportXYDistance); d(.supportSpacing, &supportSpacing)
        d(.brimWidth, &brimWidth); d(.skirtLoops, &skirtLoops); d(.skirtDistance, &skirtDistance)
        d(.primeTower, &primeTower); d(.primeTowerWidth, &primeTowerWidth)
        d(.retractSpeed, &retractSpeed); d(.retractMinTravel, &retractMinTravel); d(.zHop, &zHop)
        d(.topSurfacePattern, &topSurfacePattern); d(.bottomSurfacePattern, &bottomSurfacePattern)
        d(.seamPosition, &seamPosition); d(.wallOrder, &wallOrder); d(.elephantFootCompensation, &elephantFootCompensation)
        d(.spiralVase, &spiralVase); d(.fuzzySkin, &fuzzySkin)
        d(.fuzzySkinThickness, &fuzzySkinThickness); d(.fuzzySkinPointDistance, &fuzzySkinPointDistance)
        d(.plateType, &plateType); d(.filaments, &filaments)
        d(.enableTimelapse, &enableTimelapse); d(.enableBedLeveling, &enableBedLeveling)
        while filaments.count < machine.toolCount { filaments.append(filaments.last ?? .pla) }
    }
}
