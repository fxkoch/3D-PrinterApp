import Foundation

/// A job for slicing in the cloud with the real OrcaSlicer (see tools/cloudslice/orca_slice.py).
/// The app's settings are translated into Orca keys on top of the official printer profiles.
public struct OrcaJob: Sendable {
    public var id: String
    /// job.json contents.
    public var manifest: Data
    /// 3MF with the arranged objects.
    public var model: Data

    public static let modelFileName = "model.3mf"

    /// - Parameter usedTools: filaments that must be sent (by slot); defaults to all slots in use.
    public init(objects: [ModelObject], settings: PrintSettings, name: String, now: Date = Date()) throws {
        guard !objects.isEmpty else { throw SliceError.nothingToPrint }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let slug = name.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }
        let short = String(String(slug).split(separator: "-").joined(separator: "-").prefix(24))
        id = "\(f.string(from: now))-\(short.isEmpty ? "job" : short)-\(UUID().uuidString.prefix(6).lowercased())"

        let maxTool = objects.map(\.tool).max() ?? 0
        let filaments = (0...maxTool).map { settings.filament(for: $0) }
        let manifest: [String: Any] = [
            "printer": settings.printer.rawValue,
            "name": name,
            "model": Self.modelFileName,
            "plate": 1,
            "process": Self.processOverrides(settings),
            "machine": Self.machineOverrides(settings),
            "filaments": filaments.map { f in
                ["preset": f.orcaPresetName ?? "", "type": f.type, "overrides": Self.filamentOverrides(f, settings: settings)]
            },
        ]
        self.manifest = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        model = ThreeMFWriter.write(objects)
    }

    // MARK: - Mapping to Orca keys

    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    static func num(_ v: Double) -> String { formatDecimal(v, digits: 3) }

    public static func processOverrides(_ s: PrintSettings) -> [String: String] {
        let infill: String
        switch s.infillPattern {
        case .lines: infill = "line"
        case .grid: infill = "grid"
        case .triangles: infill = "triangles"
        case .cubic: infill = "cubic"
        case .gyroid: infill = "gyroid"
        }
        func surface(_ p: SurfacePattern, top: Bool) -> String {
            switch p {
            case .monotonic: return top ? "monotonicline" : "monotonic"
            case .lines: return "zig-zag"
            case .concentric: return "concentric"
            }
        }
        let seam: String
        switch s.seamPosition {
        case .aligned: seam = "aligned"
        case .corner: seam = "nearest"
        case .random: seam = "random"
        }
        var o: [String: String] = [
            "layer_height": num(s.layerHeight),
            "initial_layer_print_height": num(s.firstLayerHeight),
            "line_width": num(s.lineWidth),
            "inner_wall_line_width": num(s.lineWidth),
            "sparse_infill_line_width": num(s.lineWidth),
            "internal_solid_infill_line_width": num(s.lineWidth),
            "outer_wall_line_width": num(s.outerWallLineWidth),
            "initial_layer_line_width": num(s.firstLayerLineWidth),
            "wall_loops": "\(s.wallLoops)",
            "top_shell_layers": "\(s.topLayers)",
            "bottom_shell_layers": "\(s.bottomLayers)",
            "sparse_infill_density": percent(s.infillDensity),
            "sparse_infill_pattern": infill,
            "infill_wall_overlap": percent(s.infillOverlap),
            "top_surface_pattern": surface(s.topSurfacePattern, top: true),
            "bottom_surface_pattern": surface(s.bottomSurfacePattern, top: false),
            "seam_position": seam,
            "wall_sequence": s.wallOrder == .innerOuter ? "inner wall/outer wall" : "outer wall/inner wall",
            "elefant_foot_compensation": num(s.elephantFootCompensation),
            "spiral_mode": s.spiralVase ? "1" : "0",
            "fuzzy_skin": s.fuzzySkin ? "external" : "none",
            "fuzzy_skin_thickness": num(s.fuzzySkinThickness),
            "fuzzy_skin_point_distance": num(s.fuzzySkinPointDistance),
            "ironing_type": s.ironing ? "top" : "no ironing",
            "ironing_speed": num(s.ironingSpeed),
            "ironing_flow": percent(s.ironingFlow),
            "ironing_spacing": num(s.ironingSpacing),
            "bridge_speed": num(s.bridgeSpeed),
            "bridge_flow": num(s.bridgeFlow),
            "outer_wall_speed": num(s.outerWallSpeed),
            "inner_wall_speed": num(s.innerWallSpeed),
            "sparse_infill_speed": num(s.infillSpeed),
            "internal_solid_infill_speed": num(s.solidInfillSpeed),
            "top_surface_speed": num(s.topSurfaceSpeed),
            "initial_layer_speed": num(s.firstLayerSpeed),
            "initial_layer_infill_speed": num(s.firstLayerInfillSpeed),
            "support_speed": num(s.supportSpeed),
            "travel_speed": num(s.travelSpeed),
            "default_acceleration": num(s.acceleration),
            "outer_wall_acceleration": num(s.outerWallAcceleration),
            "enable_support": s.support == .off ? "0" : "1",
            "support_on_build_plate_only": s.support == .buildPlateOnly ? "1" : "0",
            "support_threshold_angle": num(s.supportAngle),
            "support_top_z_distance": num(s.supportTopZDistance),
            "support_object_xy_distance": num(s.supportXYDistance),
            "support_base_pattern_spacing": num(s.supportSpacing),
            "brim_type": s.brimWidth > 0 ? "outer_only" : "no_brim",
            "brim_width": num(s.brimWidth),
            "skirt_loops": "\(s.skirtLoops)",
            "skirt_distance": num(s.skirtDistance),
            "enable_prime_tower": s.primeTower ? "1" : "0",
            "prime_tower_width": num(s.primeTowerWidth),
            "curr_bed_type": s.plateType.rawValue,
        ]
        if s.support != .off { o["support_type"] = "normal(auto)" }
        if !s.detectBridges { o["bridge_speed"] = num(s.solidInfillSpeed) }
        return o
    }

    public static func machineOverrides(_ s: PrintSettings) -> [String: String] {
        [
            "z_hop": num(s.zHop),
            "retraction_speed": num(s.retractSpeed),
            "retraction_minimum_travel": num(s.retractMinTravel),
        ]
    }

    public static func filamentOverrides(_ f: Filament, settings s: PrintSettings) -> [String: String] {
        var o: [String: String] = [
            "filament_type": f.type,
            "filament_colour": f.color,
            "nozzle_temperature": "\(f.nozzleTemp)",
            "nozzle_temperature_initial_layer": "\(f.firstLayerNozzleTemp)",
            "textured_plate_temp": "\(f.bedTemp)",
            "textured_plate_temp_initial_layer": "\(f.firstLayerBedTemp)",
            "hot_plate_temp": "\(f.smoothPlateBedTemp)",
            "hot_plate_temp_initial_layer": "\(f.smoothPlateBedTemp)",
            "fan_max_speed": "\(Int((f.fanSpeed * 100).rounded()))",
            "fan_min_speed": "\(Int((f.fanMinSpeed * 100).rounded()))",
            "overhang_fan_speed": "\(Int((f.overhangFanSpeed * 100).rounded()))",
            "close_fan_the_first_x_layers": "\(f.fanOffLayers)",
            "filament_max_volumetric_speed": num(f.maxVolumetricSpeed),
            "filament_flow_ratio": num(f.flowRatio),
            "filament_retraction_length": num(f.retractLength),
            "slow_down_layer_time": num(s.minLayerTime > 0 ? s.minLayerTime : f.minLayerTime),
            "filament_density": num(f.density),
        ]
        if let pa = f.pressureAdvance {
            o["enable_pressure_advance"] = "1"
            o["pressure_advance"] = formatDecimal(pa, digits: 4)
        }
        return o
    }
}

extension Filament {
    /// Name of the matching OrcaSlicer preset, when this profile came from Orca.
    public var orcaPresetName: String? {
        let prefix = "OrcaSlicer: "
        guard source.hasPrefix(prefix) else { return nil }
        return String(source.dropFirst(prefix.count))
    }
}
