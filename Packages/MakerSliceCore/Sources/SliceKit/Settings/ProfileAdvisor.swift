import Foundation

/// One difference between the profile stored in a downloaded project (3MF) and the app's current settings.
public struct ProfileChange: Identifiable, Sendable, Equatable {
    public enum Group: Sendable { case important, other }

    public enum Payload: Sendable, Equatable {
        case process(key: String, value: String)
        case filament(slot: Int, field: FilamentField, value: Double)
        case layerGCode(LayerGCode)
    }

    public enum FilamentField: String, Sendable {
        case nozzleTemp, firstLayerNozzleTemp, bedTemp, firstLayerBedTemp, smoothPlateBedTemp
        case fanSpeed, fanMinSpeed, overhangFanSpeed, fanOffLayers, maxVolumetricSpeed, flowRatio, retractLength, pressureAdvance
    }

    public var id: String
    public var group: Group
    public var title: String
    public var projectValue: String
    public var currentValue: String
    /// Plain-language explanation of what the setting does.
    public var explanation: String
    public var payload: Payload
}

public struct ProfileReport: Sendable, Equatable {
    public var profileName: String?
    public var printerName: String?
    /// The file was made for another printer than the one selected.
    public var foreignPrinter: Bool
    public var changes: [ProfileChange]
    /// What was adapted automatically because the selected material differs from the model's ("Slot 1: PLA → PETG …").
    public var materialNotes: [String] = []

    public var important: [ProfileChange] { changes.filter { $0.group == .important } }
    public var other: [ProfileChange] { changes.filter { $0.group == .other } }
    public var isEmpty: Bool { changes.isEmpty && materialNotes.isEmpty }
}

/// Finds out what is special in the profile a downloaded model brings along (temperature towers, flow tests, ironing …)
/// and applies the parts the user agrees to.
public enum ProfileAdvisor {
    /// Settings that make a model's profile special; everything else that differs is listed as "further differences".
    private static let importantKeys: Set<String> = [
        "layer_height", "initial_layer_print_height", "line_width", "outer_wall_line_width", "inner_wall_line_width",
        "wall_loops", "top_shell_layers", "bottom_shell_layers", "top_shell_thickness", "bottom_shell_thickness",
        "sparse_infill_density", "sparse_infill_pattern", "ironing_type", "ironing_flow", "ironing_spacing", "ironing_speed",
        "ironing_pattern", "seam_position", "seam_gap", "seam_slope_type", "spiral_mode", "fuzzy_skin", "fuzzy_skin_thickness",
        "fuzzy_skin_point_distance", "bridge_flow", "print_flow_ratio", "top_solid_infill_flow_ratio", "bottom_solid_infill_flow_ratio",
        "internal_bridge_flow", "enable_support", "support_type", "support_threshold_angle", "support_top_z_distance",
        "brim_type", "brim_width", "skirt_loops", "wall_generator", "detect_thin_wall", "elefant_foot_compensation",
        "xy_hole_compensation", "xy_contour_compensation", "enable_arc_fitting", "reduce_crossing_wall", "only_one_wall_top",
        "only_one_wall_first_layer", "thick_bridges", "overhang_reverse", "make_overhang_printable", "extra_perimeters_on_overhangs",
        "enable_prime_tower", "slicing_mode", "print_sequence", "precise_outer_wall", "enable_extra_bridge_layer",
    ]

    public static func analyze(project: ProjectSettings, settings: PrintSettings) -> ProfileReport {
        var changes: [ProfileChange] = []
        let model = settings.printer
        let current = OrcaJob.processOverrides(settings)

        for option in SlicerOptionCatalog.all where option.availableFor.contains(model) {
            guard let projectValue = project.raw[option.key] else { continue }
            let currentValue = current[option.key] ?? option.vendor[model]
            if let currentValue, sameValue(projectValue, currentValue) { continue }
            if currentValue == nil, option.kind == .text { continue }
            let important = importantKeys.contains(option.key)
            changes.append(ProfileChange(
                id: "p-\(option.key)", group: important ? .important : .other, title: option.title,
                projectValue: display(projectValue, option), currentValue: currentValue.map { display($0, option) } ?? "Standard",
                explanation: shortExplanation(option), payload: .process(key: option.key, value: projectValue)))
        }

        // The selected material wins: a PLA model printed in PETG keeps PETG's temperatures, fan and flow.
        var notes: [String] = []
        for slot in settings.filaments.indices {
            let projectType = slot < project.filamentTypes.count ? project.filamentTypes[slot] : nil
            if MaterialAdapter.mismatch(projectType: projectType, filament: settings.filaments[slot]) {
                let f = settings.filaments[slot]
                notes.append("Slot \(slot + 1): Das Modell ist für \(projectType ?? "?") eingestellt, gedruckt wird mit \(f.type). Es gelten die Werte von „\(f.name)“ (Düse \(f.nozzleTemp) °C, Bett \(f.bedTemp) °C, Lüfter und Fluss) – die Materialwerte des Modells werden nicht übernommen.")
            } else {
                changes += filamentChanges(project: project, settings: settings, slot: slot)
            }
        }

        let adapted = settings.filaments.indices.contains(0)
            && MaterialAdapter.mismatch(projectType: project.filamentTypes.first, filament: settings.filaments[0])
        for code in project.layerGCodes {
            var lines = code.lines.filter(LayerGCode.isAllowed)
            guard !lines.isEmpty else { continue }
            if adapted {
                lines = MaterialAdapter.translate(lines, projectNozzle: project.nozzleTemperature(slot: 0), projectBed: project.bedTemperature(slot: 0),
                                                  filament: settings.filaments[0], plate: settings.plateType)
                notes.append("Befehle ab \(formatDecimal(code.z, digits: 2)) mm (Temperaturstufen) wurden auf \(settings.filaments[0].type) umgerechnet: dieselben Abstände, aber um \(settings.filaments[0].name) herum.")
            }
            changes.append(ProfileChange(
                id: "g-\(code.z)", group: .important, title: "Befehl ab Höhe \(formatDecimal(code.z, digits: 2)) mm",
                projectValue: lines.joined(separator: "; "), currentValue: "keiner",
                explanation: "Das Modell fügt ab dieser Höhe einen Befehl ein – bei Temperatur-Türmen ändert er die Düsentemperatur in Stufen, damit man die beste Temperatur am Teil ablesen kann.",
                payload: .layerGCode(LayerGCode(z: code.z, lines: lines))))
        }

        let foreign = project.printerModel.map { !isSameModel($0, model) } ?? false
        var seen = Set<String>()
        return ProfileReport(profileName: project.profileName, printerName: project.printerModel, foreignPrinter: foreign, changes: changes,
                             materialNotes: notes.filter { seen.insert($0).inserted })
    }

    /// Applies the chosen changes. Returns the settings with them taken over.
    public static func apply(_ changes: [ProfileChange], to settings: PrintSettings) -> PrintSettings {
        var s = settings
        for change in changes {
            switch change.payload {
            case .process(let key, let value):
                s.setOption(key: key, value: value)
            case .filament(let slot, let field, let value):
                guard s.filaments.indices.contains(slot) else { continue }
                var f = s.filaments[slot]
                switch field {
                case .nozzleTemp: f.nozzleTemp = Int(value)
                case .firstLayerNozzleTemp: f.firstLayerNozzleTemp = Int(value)
                case .bedTemp: f.bedTemp = Int(value)
                case .firstLayerBedTemp: f.firstLayerBedTemp = Int(value)
                case .smoothPlateBedTemp: f.smoothPlateBedTemp = Int(value)
                case .fanSpeed: f.fanSpeed = value / 100
                case .fanMinSpeed: f.fanMinSpeed = value / 100
                case .overhangFanSpeed: f.overhangFanSpeed = value / 100
                case .fanOffLayers: f.fanOffLayers = Int(value)
                case .maxVolumetricSpeed: f.maxVolumetricSpeed = value
                case .flowRatio: f.flowRatio = value
                case .retractLength: f.retractLength = value
                case .pressureAdvance: f.pressureAdvance = value
                }
                s.filaments[slot] = f
            case .layerGCode(let code):
                s.layerGCodes.removeAll { $0.z == code.z }
                s.layerGCodes.append(code)
                s.layerGCodes.sort { $0.z < $1.z }
            }
        }
        return s
    }

    // MARK: - Filament

    private static let filamentKeys: [(key: String, field: ProfileChange.FilamentField, title: String, unit: String, explanation: String,
                                       get: (Filament) -> Double?)] = [
        ("nozzle_temperature", .nozzleTemp, "Düsentemperatur", "°C",
         "Temperatur der Düse. Höher fließt der Kunststoff besser und haftet zwischen den Schichten fester, zu heiß gibt Fäden und Qualitätsverlust.", { Double($0.nozzleTemp) }),
        ("nozzle_temperature_initial_layer", .firstLayerNozzleTemp, "Düsentemperatur erste Schicht", "°C",
         "Temperatur für die erste Schicht – etwas höher verbessert die Haftung auf dem Druckbett.", { Double($0.firstLayerNozzleTemp) }),
        ("textured_plate_temp", .bedTemp, "Betttemperatur (strukturiert)", "°C", "Temperatur des Druckbetts mit strukturierter Platte.", { Double($0.bedTemp) }),
        ("textured_plate_temp_initial_layer", .firstLayerBedTemp, "Betttemperatur erste Schicht", "°C", "Betttemperatur in der ersten Schicht.", { Double($0.firstLayerBedTemp) }),
        ("hot_plate_temp", .smoothPlateBedTemp, "Betttemperatur (glatt)", "°C", "Temperatur des Druckbetts mit glatter Platte.", { Double($0.smoothPlateBedTemp) }),
        ("fan_max_speed", .fanSpeed, "Lüfter maximal", "%", "Höchste Drehzahl des Bauteillüfters. Mehr kühlt besser (scharfe Details), weniger verbindet die Schichten fester.", { $0.fanSpeed * 100 }),
        ("fan_min_speed", .fanMinSpeed, "Lüfter minimal", "%", "Niedrigste Drehzahl des Bauteillüfters.", { $0.fanMinSpeed * 100 }),
        ("overhang_fan_speed", .overhangFanSpeed, "Lüfter bei Überhängen", "%", "Lüfter-Drehzahl an Brücken und Überhängen.", { $0.overhangFanSpeed * 100 }),
        ("close_fan_the_first_x_layers", .fanOffLayers, "Lüfter aus für erste Schichten", "", "Anzahl der ersten Schichten ohne Bauteillüfter – bessere Haftung am Bett.", { Double($0.fanOffLayers) }),
        ("filament_max_volumetric_speed", .maxVolumetricSpeed, "Max. Fluss", "mm³/s", "Wie viel Kunststoff pro Sekunde höchstens geschmolzen wird. Begrenzt die Druckgeschwindigkeit, damit die Düse nicht überfordert wird.", { $0.maxVolumetricSpeed }),
        ("filament_flow_ratio", .flowRatio, "Flussrate", "", "Korrekturfaktor für die Menge Kunststoff. Gleicht aus, wenn ein Filament etwas zu viel oder zu wenig fließt (Fluss-Kalibrierung).", { $0.flowRatio }),
        ("filament_retraction_length", .retractLength, "Rückzugslänge", "mm", "Wie weit das Filament vor Leerfahrten zurückgezogen wird. Länger gegen Fäden, zu lang verstopft die Düse.", { $0.retractLength }),
        ("pressure_advance", .pressureAdvance, "Pressure Advance", "", "Korrigiert den Druckaufbau in der Düse bei Geschwindigkeitswechseln – schärfere Ecken und gleichmäßigere Linien (Klipper).", { $0.pressureAdvance }),
    ]

    private static func filamentChanges(project: ProjectSettings, settings: PrintSettings, slot: Int) -> [ProfileChange] {
        guard slot < max(project.perFilament["filament_type"]?.count ?? 0, project.raw["filament_type"] != nil ? 1 : 0) else { return [] }
        let filament = settings.filaments[slot]
        var changes: [ProfileChange] = []
        for entry in filamentKeys {
            let values = project.perFilament[entry.key] ?? project.raw[entry.key].map { [$0] }
            guard let values, slot < values.count, let projectValue = Double(values[slot].replacingOccurrences(of: "%", with: "")) else { continue }
            let currentValue = entry.get(filament)
            if let currentValue, abs(currentValue - projectValue) < 0.0005 { continue }
            let unit = entry.unit.isEmpty ? "" : " \(entry.unit)"
            changes.append(ProfileChange(
                id: "f\(slot)-\(entry.key)", group: .important, title: "Slot \(slot + 1): \(entry.title)",
                projectValue: formatDecimal(projectValue, digits: 3) + unit,
                currentValue: currentValue.map { formatDecimal($0, digits: 3) + unit } ?? "Standard",
                explanation: entry.explanation, payload: .filament(slot: slot, field: entry.field, value: projectValue)))
        }
        return changes
    }

    // MARK: - Helpers

    static func sameValue(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "%", with: "") }
        let (x, y) = (norm(a), norm(b))
        if x == y { return true }
        if let dx = Double(x), let dy = Double(y) { return abs(dx - dy) < 0.0005 }
        let truthy: Set<String> = ["1", "true"], falsy: Set<String> = ["0", "false"]
        return (truthy.contains(x) && truthy.contains(y)) || (falsy.contains(x) && falsy.contains(y))
    }

    static func display(_ value: String, _ option: SlicerOption) -> String {
        switch option.kind {
        case .bool: return sameValue(value, "1") ? "an" : "aus"
        case .choice: return option.choices.first { $0.value == value }?.label ?? value
        default:
            let unit = option.unit.hasPrefix("mm oder") || option.unit.hasSuffix("oder %") ? "" : option.unit
            return unit.isEmpty ? value : "\(value) \(unit)"
        }
    }

    static func shortExplanation(_ option: SlicerOption) -> String {
        let text = SlicerOptionDetails.detail(for: option.key)?.meaning ?? option.summary
        let first = text.components(separatedBy: "\n").first ?? text
        if first.count <= 220 { return first }
        let cut = first.prefix(220)
        if let dot = cut.lastIndex(of: ".") { return String(cut[...dot]) }
        return String(cut) + " …"
    }

    private static func isSameModel(_ projectPrinter: String, _ model: PrinterModel) -> Bool {
        let name = projectPrinter.lowercased()
        switch model {
        case .snapmakerU1: return name.contains("snapmaker") && name.contains("u1")
        case .kobraS1: return name.contains("kobra s1")
        case .bambuP1S: return name.contains("p1s")
        }
    }
}
