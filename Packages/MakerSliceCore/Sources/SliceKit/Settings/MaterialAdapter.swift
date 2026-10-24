import Foundation

/// Models from the internet bring the settings of the material their author used (mostly PLA). When another material is
/// selected – PETG, ABS … – the model's material values must not override it. This adapts what a model carries along.
public enum MaterialAdapter {
    /// "PLA" from "PLA Basic", "PLA+", "PLA-CF"; "PETG" from "PETG-HF"; "PA" from "PA6-CF" (a family, not the exact product).
    public static func family(_ type: String) -> String {
        let t = type.uppercased().trimmingCharacters(in: .whitespaces)
        for family in ["PETG", "PLA", "ABS", "ASA", "TPU", "TPE", "PVA", "PC", "PA", "PP", "PET"] where t.hasPrefix(family) {
            // PET alone is PETG for printing; PA vs PAHT stay PA.
            return family == "PET" ? "PETG" : family
        }
        return t
    }

    /// True when the project's material and the selected filament are different families.
    public static func mismatch(projectType: String?, filament: Filament) -> Bool {
        guard let projectType, !projectType.isEmpty else { return false }
        return family(projectType) != family(filament.type)
    }

    /// Temperature commands of a project (temperature tower, colour-change heat) turned to the selected filament: the steps
    /// stay as the author meant them (±N °C around the base temperature), only the base moves to this filament.
    public static func translate(_ lines: [String], projectNozzle: Double?, projectBed: Double?, filament: Filament, plate: PlateType = .texturedPEI) -> [String] {
        lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let upper = trimmed.uppercased()
            let isNozzle = upper.hasPrefix("M104 ") || upper.hasPrefix("M109 ")
            let isBed = upper.hasPrefix("M140 ") || upper.hasPrefix("M190 ")
            guard isNozzle || isBed, let range = upper.range(of: " S"), let value = Double(upper[range.upperBound...].prefix { $0.isNumber || $0 == "." }) else { return line }
            if value == 0 { return line }   // switching off stays off
            let base = isNozzle ? projectNozzle : projectBed
            let target = isNozzle ? Double(filament.nozzleTemp) : Double(filament.bedTemp(for: plate, firstLayer: false))
            guard let base else {
                // Without a reference the absolute value of another material is meaningless: use the filament's own.
                return replace(line, with: Int(target))
            }
            let translated = target + (value - base)
            let low = isNozzle ? Double(filament.nozzleTempMin) - 15 : 0
            let high = isNozzle ? Double(filament.nozzleTempMax) + 15 : 120
            return replace(line, with: Int(max(low, min(high, translated)).rounded()))
        }
    }

    private static func replace(_ line: String, with value: Int) -> String {
        guard let range = line.range(of: " S", options: .caseInsensitive) else { return line }
        let rest = line[range.upperBound...]
        let digits = rest.prefix { $0.isNumber || $0 == "." }
        return String(line[..<range.upperBound]) + "\(value)" + rest.dropFirst(digits.count)
    }
}

extension ProjectSettings {
    /// The base nozzle temperature the author printed with (slot `slot`).
    public func nozzleTemperature(slot: Int) -> Double? {
        let values = perFilament["nozzle_temperature"] ?? raw["nozzle_temperature"].map { [$0] }
        return values.flatMap { slot < $0.count ? Double($0[slot]) : nil }
    }

    /// The base bed temperature the author printed with (textured/smooth plate, whichever the file has).
    public func bedTemperature(slot: Int) -> Double? {
        for key in ["textured_plate_temp", "hot_plate_temp", "cool_plate_temp", "eng_plate_temp"] {
            let values = perFilament[key] ?? raw[key].map { [$0] }
            if let v = values.flatMap({ slot < $0.count ? Double($0[slot]) : nil }), v > 0 { return v }
        }
        return nil
    }
}

extension PrintSettings {
    /// The settings with the project's temperature commands adapted to the selected filament (nothing changes without a mismatch).
    public func adaptingMaterial(of project: ProjectSettings?) -> PrintSettings {
        guard let project, !layerGCodes.isEmpty else { return self }
        // The temperature steps of a project belong to its first material.
        guard filaments.indices.contains(0), MaterialAdapter.mismatch(projectType: project.filamentTypes.first, filament: filaments[0]) else { return self }
        var s = self
        s.layerGCodes = layerGCodes.map {
            LayerGCode(z: $0.z, lines: MaterialAdapter.translate($0.lines, projectNozzle: project.nozzleTemperature(slot: 0),
                                                                  projectBed: project.bedTemperature(slot: 0), filament: filaments[0], plate: plateType))
        }
        return s
    }
}
