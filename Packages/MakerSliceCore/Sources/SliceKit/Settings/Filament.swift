import Foundation

/// Material preset. Values come from the OrcaSlicer profiles bundled in `filaments.json`.
public struct Filament: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var vendor: String
    public var type: String
    public var nozzleTemp: Int
    public var firstLayerNozzleTemp: Int
    public var nozzleTempMin: Int
    public var nozzleTempMax: Int
    /// Textured PEI plate temperatures.
    public var bedTemp: Int
    public var firstLayerBedTemp: Int
    /// Smooth (high temp) plate temperature.
    public var smoothPlateBedTemp: Int
    /// Part cooling fan speed in 0...1.
    public var fanSpeed: Double
    public var fanMinSpeed: Double
    /// Fan used on bridges and overhangs, 0...1.
    public var overhangFanSpeed: Double
    /// Layers printed without part cooling at the start.
    public var fanOffLayers: Int
    /// Maximum volumetric flow in mm³/s.
    public var maxVolumetricSpeed: Double
    public var retractLength: Double
    public var flowRatio: Double
    /// Klipper pressure advance; nil = keep the printer's value.
    public var pressureAdvance: Double?
    /// Glass transition temperature – drives the U1 chamber purifier mode.
    public var vitrificationTemp: Int
    /// g/cm³, for weight estimates.
    public var density: Double
    /// Minimum layer time in seconds for cooling.
    public var minLayerTime: Double
    /// Hex colour "#RRGGBB".
    public var color: String
    /// Where the values come from.
    public var source: String

    public init(name: String, vendor: String = "Generic", type: String, nozzleTemp: Int, firstLayerNozzleTemp: Int? = nil,
                nozzleTempMin: Int? = nil, nozzleTempMax: Int? = nil,
                bedTemp: Int, firstLayerBedTemp: Int? = nil, smoothPlateBedTemp: Int? = nil,
                fanSpeed: Double, fanMinSpeed: Double? = nil, overhangFanSpeed: Double = 1, fanOffLayers: Int = 1,
                maxVolumetricSpeed: Double, retractLength: Double = 0.8, flowRatio: Double = 0.98,
                pressureAdvance: Double? = nil, vitrificationTemp: Int, density: Double, minLayerTime: Double = 4,
                color: String = "#FCE94F", source: String = "MakerSlice") {
        self.name = name
        self.vendor = vendor
        self.type = type
        self.nozzleTemp = nozzleTemp
        self.firstLayerNozzleTemp = firstLayerNozzleTemp ?? nozzleTemp
        self.nozzleTempMin = nozzleTempMin ?? nozzleTemp - 20
        self.nozzleTempMax = nozzleTempMax ?? nozzleTemp + 20
        self.bedTemp = bedTemp
        self.firstLayerBedTemp = firstLayerBedTemp ?? bedTemp
        self.smoothPlateBedTemp = smoothPlateBedTemp ?? bedTemp
        self.fanSpeed = fanSpeed
        self.fanMinSpeed = fanMinSpeed ?? fanSpeed
        self.overhangFanSpeed = overhangFanSpeed
        self.fanOffLayers = fanOffLayers
        self.maxVolumetricSpeed = maxVolumetricSpeed
        self.retractLength = retractLength
        self.flowRatio = flowRatio
        self.pressureAdvance = pressureAdvance
        self.vitrificationTemp = vitrificationTemp
        self.density = density
        self.minLayerTime = minLayerTime
        self.color = color
        self.source = source
    }

    /// Bed temperature for the given plate.
    public func bedTemp(for plate: PlateType, firstLayer: Bool) -> Int {
        switch plate {
        case .texturedPEI: return firstLayer ? firstLayerBedTemp : bedTemp
        case .highTemp: return smoothPlateBedTemp
        }
    }

    public var isFlexible: Bool { type.uppercased().hasPrefix("TPU") || type.uppercased().hasPrefix("TPE") || type.uppercased() == "PEBA" }
    public var needsEnclosure: Bool {
        ["ABS", "ASA", "PC", "PA", "PA6", "PAHT", "PPS"].contains { type.uppercased().hasPrefix($0) }
    }

    public static let pla = Filament(name: "Generic PLA", type: "PLA", nozzleTemp: 220, bedTemp: 60, firstLayerBedTemp: 65,
                                     fanSpeed: 1, maxVolumetricSpeed: 12, vitrificationTemp: 45, density: 1.24)
    public static let plaHighSpeed = Filament(name: "Generic PLA High Speed", type: "PLA", nozzleTemp: 230, bedTemp: 60,
                                              firstLayerBedTemp: 65, fanSpeed: 1, maxVolumetricSpeed: 21,
                                              vitrificationTemp: 45, density: 1.24)
    public static let plaCF = Filament(name: "Generic PLA-CF", type: "PLA-CF", nozzleTemp: 230, bedTemp: 60,
                                       fanSpeed: 1, maxVolumetricSpeed: 12, vitrificationTemp: 45, density: 1.21)
    public static let petg = Filament(name: "Generic PETG", type: "PETG", nozzleTemp: 250, firstLayerNozzleTemp: 245, bedTemp: 70,
                                      fanSpeed: 0.4, fanMinSpeed: 0.1, fanOffLayers: 3, maxVolumetricSpeed: 10,
                                      retractLength: 1.0, vitrificationTemp: 64, density: 1.27, minLayerTime: 8)
    public static let tpu = Filament(name: "Generic TPU", type: "TPU", nozzleTemp: 230, bedTemp: 40,
                                     fanSpeed: 0.7, maxVolumetricSpeed: 3.6, retractLength: 0.4, flowRatio: 1.0,
                                     vitrificationTemp: 30, density: 1.21, minLayerTime: 8)
    public static let abs = Filament(name: "Generic ABS", type: "ABS", nozzleTemp: 260, bedTemp: 100,
                                     fanSpeed: 0.3, fanMinSpeed: 0.1, fanOffLayers: 3, maxVolumetricSpeed: 16,
                                     vitrificationTemp: 94, density: 1.05)
    public static let asa = Filament(name: "Generic ASA", type: "ASA", nozzleTemp: 260, bedTemp: 100,
                                     fanSpeed: 0.3, fanMinSpeed: 0.1, fanOffLayers: 3, maxVolumetricSpeed: 16,
                                     vitrificationTemp: 100, density: 1.07)

    /// Built-in fallbacks when the library is unavailable.
    public static let presets: [Filament] = [.pla, .plaHighSpeed, .plaCF, .petg, .tpu, .abs, .asa]

    // Tolerant decoding: older saved settings may lack newer keys.
    enum CodingKeys: String, CodingKey {
        case name, vendor, type, nozzleTemp, firstLayerNozzleTemp, nozzleTempMin, nozzleTempMax, bedTemp, firstLayerBedTemp
        case smoothPlateBedTemp, fanSpeed, fanMinSpeed, overhangFanSpeed, fanOffLayers, maxVolumetricSpeed, retractLength
        case flowRatio, pressureAdvance, vitrificationTemp, density, minLayerTime, color, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type)
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor) ?? "Generic"
        nozzleTemp = try c.decode(Int.self, forKey: .nozzleTemp)
        firstLayerNozzleTemp = try c.decodeIfPresent(Int.self, forKey: .firstLayerNozzleTemp) ?? nozzleTemp
        nozzleTempMin = try c.decodeIfPresent(Int.self, forKey: .nozzleTempMin) ?? nozzleTemp - 20
        nozzleTempMax = try c.decodeIfPresent(Int.self, forKey: .nozzleTempMax) ?? nozzleTemp + 20
        bedTemp = try c.decode(Int.self, forKey: .bedTemp)
        firstLayerBedTemp = try c.decodeIfPresent(Int.self, forKey: .firstLayerBedTemp) ?? bedTemp
        smoothPlateBedTemp = try c.decodeIfPresent(Int.self, forKey: .smoothPlateBedTemp) ?? bedTemp
        fanSpeed = try c.decodeIfPresent(Double.self, forKey: .fanSpeed) ?? 1
        fanMinSpeed = try c.decodeIfPresent(Double.self, forKey: .fanMinSpeed) ?? fanSpeed
        overhangFanSpeed = try c.decodeIfPresent(Double.self, forKey: .overhangFanSpeed) ?? 1
        fanOffLayers = try c.decodeIfPresent(Int.self, forKey: .fanOffLayers) ?? 1
        maxVolumetricSpeed = try c.decodeIfPresent(Double.self, forKey: .maxVolumetricSpeed) ?? 12
        retractLength = try c.decodeIfPresent(Double.self, forKey: .retractLength) ?? 0.8
        flowRatio = try c.decodeIfPresent(Double.self, forKey: .flowRatio) ?? 0.98
        pressureAdvance = try c.decodeIfPresent(Double.self, forKey: .pressureAdvance)
        vitrificationTemp = try c.decodeIfPresent(Int.self, forKey: .vitrificationTemp) ?? 60
        density = try c.decodeIfPresent(Double.self, forKey: .density) ?? 1.24
        minLayerTime = try c.decodeIfPresent(Double.self, forKey: .minLayerTime) ?? 4
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#FCE94F"
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "MakerSlice"
    }
}

/// The bundled library of material profiles (OrcaSlicer system profiles for the
/// U1 and Kobra S1 plus brand filaments from the Orca filament library).
public enum FilamentLibrary {
    struct Record: Decodable {
        var name: String
        var vendor: String?
        var type: String
        var printer: String
        var nozzleTemp: Int
        var firstLayerNozzleTemp: Int?
        var nozzleTempMin: Int?
        var nozzleTempMax: Int?
        var bedTemp: Int
        var firstLayerBedTemp: Int?
        var smoothPlateBedTemp: Int?
        var fanMax: Double?
        var fanMin: Double?
        var fanOffLayers: Int?
        var overhangFan: Double?
        var maxVolumetricSpeed: Double?
        var retractLength: Double?
        var flowRatio: Double?
        var pressureAdvance: Double?
        var vitrificationTemp: Int?
        var density: Double?
        var minLayerTime: Double?
        var color: String?
        var source: String?
    }

    public struct Entry: Identifiable, Hashable, Sendable {
        public var id: String { "\(scope)/\(filament.name)" }
        public var filament: Filament
        /// "u1", "kobraS1" or "any".
        public var scope: String
    }

    public static let all: [Entry] = load()

    /// Profiles for a printer: its own profiles first, then brand filaments.
    public static func entries(for printer: PrinterModel) -> [Entry] {
        let scope = printer.machine.filamentScope
        return all.filter { $0.scope == scope } + all.filter { $0.scope == "any" }
    }

    public static var vendors: [String] {
        Array(Set(all.map(\.filament.vendor))).sorted()
    }

    /// Best profile for a material type reported by the printer (e.g. RFID "PLA" / "PETG HF").
    public static func bestMatch(type: String, vendor: String? = nil, printer: PrinterModel) -> Filament? {
        let candidates = entries(for: printer).map(\.filament)
        let t = type.uppercased().trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != "NONE" else { return nil }
        if let vendor, let v = candidates.first(where: {
            $0.vendor.caseInsensitiveCompare(vendor) == .orderedSame && $0.name.uppercased().hasSuffix(" " + t)
        }) {
            return v
        }
        let own = entries(for: printer).filter { $0.scope != "any" }.map(\.filament)
        if let exact = own.first(where: { $0.name.uppercased().hasSuffix(" " + t) && $0.name.hasPrefix("Generic") })
            ?? own.first(where: { $0.name.uppercased().hasSuffix(" " + t) })
            ?? own.first(where: { $0.type.uppercased() == t }) {
            return exact
        }
        let base = t.split(whereSeparator: { $0 == " " || $0 == "-" }).first.map(String.init) ?? t
        return own.first(where: { $0.type.uppercased() == base })
            ?? candidates.first(where: { $0.type.uppercased() == base })
            ?? Filament.presets.first(where: { $0.type.uppercased() == base })
    }

    /// Recommended (library) values for a filament with this name, if known.
    public static func recommended(named name: String, printer: PrinterModel) -> Filament? {
        entries(for: printer).first { $0.filament.name == name }?.filament
    }

    /// Default material for a printer.
    public static func defaultFilament(for printer: PrinterModel) -> Filament {
        let own = entries(for: printer).filter { $0.scope != "any" }.map(\.filament)
        return own.first { $0.name == "Generic PLA" } ?? own.first { $0.name == "Anycubic PLA" } ?? .pla
    }

    private static func load() -> [Entry] {
        guard let url = Bundle.module.url(forResource: "filaments", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([Record].self, from: data) else {
            return Filament.presets.map { Entry(filament: $0, scope: "any") }
        }
        return records.map { r in
            let nozzle = r.nozzleTemp
            let filament = Filament(
                name: r.name, vendor: r.vendor ?? "Generic", type: r.type, nozzleTemp: nozzle,
                firstLayerNozzleTemp: r.firstLayerNozzleTemp, nozzleTempMin: r.nozzleTempMin, nozzleTempMax: r.nozzleTempMax,
                bedTemp: r.bedTemp, firstLayerBedTemp: r.firstLayerBedTemp, smoothPlateBedTemp: r.smoothPlateBedTemp,
                fanSpeed: r.fanMax ?? 1, fanMinSpeed: r.fanMin, overhangFanSpeed: r.overhangFan ?? 1,
                fanOffLayers: r.fanOffLayers ?? 1, maxVolumetricSpeed: r.maxVolumetricSpeed ?? 12,
                retractLength: r.retractLength ?? 0.8, flowRatio: r.flowRatio ?? 0.98, pressureAdvance: r.pressureAdvance,
                vitrificationTemp: r.vitrificationTemp ?? 60, density: r.density ?? 1.24, minLayerTime: r.minLayerTime ?? 4,
                color: r.color.flatMap { $0.hasPrefix("#") ? String($0.prefix(7)) : nil } ?? "#FCE94F",
                source: r.source ?? "OrcaSlicer"
            )
            return Entry(filament: filament, scope: r.printer)
        }
    }
}
