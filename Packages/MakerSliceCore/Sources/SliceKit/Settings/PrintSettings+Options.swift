import Foundation

extension PrintSettings {
    /// Sets a setting by its OrcaSlicer key. Settings the app has its own control for are stored in their field
    /// (the built-in slicer uses them); all others go to `extraOptions` (used when slicing in the cloud).
    public mutating func setOption(key: String, value: String) {
        func double() -> Double? { Double(value.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }
        func bool() -> Bool { value == "1" || value.lowercased() == "true" }
        func set(_ path: WritableKeyPath<PrintSettings, Double>, scale: Double = 1) -> Bool {
            guard let v = double() else { return false }
            self[keyPath: path] = v * scale
            return true
        }
        func setInt(_ path: WritableKeyPath<PrintSettings, Int>) -> Bool {
            guard let v = double() else { return false }
            self[keyPath: path] = Int(v)
            return true
        }
        let handled: Bool
        switch key {
        case "layer_height": handled = set(\.layerHeight)
        case "initial_layer_print_height": handled = set(\.firstLayerHeight)
        case "line_width": handled = set(\.lineWidth)
        case "outer_wall_line_width": handled = set(\.outerWallLineWidth)
        case "initial_layer_line_width": handled = set(\.firstLayerLineWidth)
        case "wall_loops": handled = setInt(\.wallLoops)
        case "top_shell_layers": handled = setInt(\.topLayers)
        case "bottom_shell_layers": handled = setInt(\.bottomLayers)
        case "sparse_infill_density": handled = set(\.infillDensity, scale: 0.01)
        case "infill_wall_overlap": handled = set(\.infillOverlap, scale: 0.01)
        case "outer_wall_speed": handled = set(\.outerWallSpeed)
        case "inner_wall_speed": handled = set(\.innerWallSpeed)
        case "sparse_infill_speed": handled = set(\.infillSpeed)
        case "internal_solid_infill_speed": handled = set(\.solidInfillSpeed)
        case "top_surface_speed": handled = set(\.topSurfaceSpeed)
        case "initial_layer_speed": handled = set(\.firstLayerSpeed)
        case "initial_layer_infill_speed": handled = set(\.firstLayerInfillSpeed)
        case "support_speed": handled = set(\.supportSpeed)
        case "travel_speed": handled = set(\.travelSpeed)
        case "default_acceleration": handled = set(\.acceleration)
        case "outer_wall_acceleration": handled = set(\.outerWallAcceleration)
        case "ironing_speed": handled = set(\.ironingSpeed)
        case "ironing_flow": handled = set(\.ironingFlow, scale: 0.01)
        case "ironing_spacing": handled = set(\.ironingSpacing)
        case "bridge_speed": handled = set(\.bridgeSpeed)
        case "bridge_flow": handled = set(\.bridgeFlow)
        case "elefant_foot_compensation": handled = set(\.elephantFootCompensation)
        case "fuzzy_skin_thickness": handled = set(\.fuzzySkinThickness)
        case "fuzzy_skin_point_distance": handled = set(\.fuzzySkinPointDistance)
        case "support_threshold_angle": handled = set(\.supportAngle)
        case "support_top_z_distance": handled = set(\.supportTopZDistance)
        case "support_object_xy_distance": handled = set(\.supportXYDistance)
        case "support_base_pattern_spacing": handled = set(\.supportSpacing)
        case "skirt_distance": handled = set(\.skirtDistance)
        case "skirt_loops": handled = setInt(\.skirtLoops)
        case "prime_tower_width": handled = set(\.primeTowerWidth)
        case "prime_volume": handled = set(\.purgeVolume)
        case "spiral_mode": spiralVase = bool(); handled = true
        case "enable_prime_tower": primeTower = bool(); handled = true
        case "ironing_type": ironing = value != "no ironing"; handled = true
        case "fuzzy_skin": fuzzySkin = value != "none"; handled = true
        case "detect_overhang_wall": handled = false
        case "brim_width": handled = set(\.brimWidth)
        case "brim_type":
            if value == "no_brim" { brimWidth = 0; handled = true } else { handled = false }
        case "enable_support":
            if !bool() { support = .off } else if support == .off { support = .buildPlateOnly }
            handled = true
        case "support_on_build_plate_only":
            if support != .off { support = bool() ? .buildPlateOnly : .everywhere }
            handled = true
        case "sparse_infill_pattern":
            switch value {
            case "gyroid": infillPattern = .gyroid; handled = true
            case "cubic", "adaptivecubic", "supportcubic": infillPattern = .cubic; handled = true
            case "triangles", "tri-hexagon", "stars": infillPattern = .triangles; handled = true
            case "grid", "rectilinear": infillPattern = .grid; handled = true
            case "line", "zig-zag": infillPattern = .lines; handled = true
            default: handled = false
            }
        case "seam_position":
            switch value {
            case "aligned": seamPosition = .aligned; handled = true
            case "nearest": seamPosition = .corner; handled = true
            case "random": seamPosition = .random; handled = true
            default: handled = false
            }
        case "wall_sequence":
            wallOrder = value == "outer wall/inner wall" ? .outerInner : .innerOuter
            handled = value == "outer wall/inner wall" || value == "inner wall/outer wall"
        default: handled = false
        }
        if handled {
            extraOptions[key] = nil
        } else {
            extraOptions[key] = value
        }
    }
}
