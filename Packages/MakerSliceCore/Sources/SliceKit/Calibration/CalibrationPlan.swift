import Foundation

/// One step of a calibration print: a value that is printed at a height range.
public struct CalibrationStep: Equatable, Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int
    /// The value to store when this step is the best one (already in its final unit).
    public var value: Double
    public var label: String
    public var zFrom: Double
    public var zTo: Double
}

/// A ready-to-slice calibration print: test model, settings and the commands that change the value per height.
public struct CalibrationPlan: Sendable {
    public var kind: CalibrationKind
    public var steps: [CalibrationStep]
    public var object: ModelObject
    public var settings: PrintSettings
    public var name: String
    /// Short note shown above the print ("Flow-Treppe: 9 Stufen …").
    public var note: String

    /// Step to the printed height (mm).
    public func step(atHeight z: Double) -> CalibrationStep? { steps.last { $0.zFrom <= z + 1e-6 } }
}

/// Builds the calibration prints from the filament profile and the printer.
public enum CalibrationFactory {
    public static func plan(_ kind: CalibrationKind, filament: Filament, base: PrintSettings) -> CalibrationPlan {
        var s = base
        s.filaments = [filament] + Array(base.filaments.dropFirst())
        s.support = .off
        s.primeTower = false
        s.ironing = false
        s.spiralVase = false
        s.brimWidth = 4
        s.layerGCodes = []
        s.retractLengthSteps = []
        s.footerGCode = []
        s.extraOptions = [:]

        switch kind {
        case .temperature: return temperature(filament, s)
        case .flow: return flow(filament, s)
        case .pressureAdvance: return pressureAdvance(filament, s)
        case .retraction: return retraction(filament, s)
        case .maxFlow: return maxFlow(filament, s)
        }
    }

    // MARK: Temperature tower

    static func temperature(_ f: Filament, _ settings: PrintSettings) -> CalibrationPlan {
        var s = settings
        let maxAllowed = 300
        let low = f.nozzleTempMin > 150 ? f.nozzleTempMin - 5 : f.nozzleTemp - 25
        var top = f.nozzleTemp + 15
        top = min(max(top, low + 30), maxAllowed)
        let temps = (0..<7).map { top - 5 * $0 }
        let segment = 8.0
        let steps = temps.enumerated().map { i, t in
            CalibrationStep(index: i, value: Double(t), label: "\(t) °C", zFrom: Double(i) * segment, zTo: Double(i + 1) * segment)
        }
        // The first segment prints with the profile temperature set to its value; later ones change it one layer early.
        s.filaments[0].nozzleTemp = temps[0]
        s.filaments[0].firstLayerNozzleTemp = temps[0]
        s.layerGCodes = steps.dropFirst().map { LayerGCode(z: $0.zFrom - s.layerHeight, lines: ["M104 S\(Int($0.value))"]) }
        s.footerGCode = ["M104 S0"]
        let object = pillarTower(segments: steps.count, segment: segment)
        return CalibrationPlan(kind: .temperature, steps: steps, object: object, settings: s, name: "Temperaturturm",
                               note: "7 Stufen von \(temps[0]) °C (unten) bis \(temps[6]) °C (oben), alle 8 mm.")
    }

    // MARK: Flow staircase

    static func flow(_ f: Filament, _ settings: PrintSettings) -> CalibrationPlan {
        var s = settings
        let deltas = [-0.08, -0.06, -0.04, -0.02, 0, 0.02, 0.04, 0.06, 0.08]
        let tier = 3.0
        let steps = deltas.enumerated().map { i, d in
            CalibrationStep(index: i, value: (f.flowRatio * (1 + d) * 1000).rounded() / 1000,
                            label: String(format: "%+.0f %%", d * 100), zFrom: Double(i) * tier, zTo: Double(i + 1) * tier)
        }
        s.topLayers = 6
        s.bottomLayers = 4
        s.infillDensity = 0.15
        s.wallLoops = 2
        // M221 scales the flow the G-code already contains; the first tier starts at 92 %.
        s.layerGCodes = steps.enumerated().map { i, st in
            LayerGCode(z: i == 0 ? 0 : st.zFrom - s.layerHeight, lines: ["M221 S\(Int((100 * (1 + deltas[i])).rounded()))"])
        }
        s.footerGCode = ["M221 S100"]
        let object = staircase(tiers: steps.count, height: tier)
        return CalibrationPlan(kind: .flow, steps: steps, object: object, settings: s, name: "Fluss-Treppe",
                               note: "9 Stufen von −8 % (unten) bis +8 % (oben) um den Flussfaktor \(String(format: "%.3f", f.flowRatio)).")
    }

    // MARK: Pressure advance tower

    static func pressureAdvance(_ f: Filament, _ settings: PrintSettings) -> CalibrationPlan {
        var s = settings
        let values = (0...12).map { Double($0) * 0.005 }
        let segment = 2.0
        let steps = values.enumerated().map { i, v in
            CalibrationStep(index: i, value: v, label: String(format: "%.3f", v), zFrom: Double(i) * segment, zTo: Double(i + 1) * segment)
        }
        s.filaments[0].pressureAdvance = nil
        s.wallLoops = 2
        s.topLayers = 0
        s.bottomLayers = 3
        s.infillDensity = 0
        s.outerWallSpeed = max(s.outerWallSpeed, 120)
        s.innerWallSpeed = max(s.innerWallSpeed, 120)
        s.layerGCodes = steps.enumerated().map { i, st in
            LayerGCode(z: i == 0 ? 0 : st.zFrom - s.layerHeight, lines: ["SET_PRESSURE_ADVANCE ADVANCE=\(String(format: "%.3f", st.value))"])
        }
        s.footerGCode = ["SET_PRESSURE_ADVANCE ADVANCE=\(String(format: "%.3f", f.pressureAdvance ?? 0.02))"]
        let object = hollowTower(size: 36, wall: 0.9, height: segment * Double(steps.count))
        return CalibrationPlan(kind: .pressureAdvance, steps: steps, object: object, settings: s, name: "Pressure-Advance-Turm",
                               note: "13 Stufen von 0,000 bis 0,060, alle 2 mm Höhe.")
    }

    // MARK: Retraction tower

    static func retraction(_ f: Filament, _ settings: PrintSettings) -> CalibrationPlan {
        var s = settings
        let values: [Double] = f.type.uppercased().contains("TPU") ? [0, 0.2, 0.4, 0.6, 0.8, 1.0] : [0.2, 0.4, 0.6, 0.8, 1.0, 1.2, 1.4, 1.6]
        let segment = 8.0
        let steps = values.enumerated().map { i, v in
            CalibrationStep(index: i, value: v, label: String(format: "%.1f mm", v), zFrom: Double(i) * segment, zTo: Double(i + 1) * segment)
        }
        s.retractLengthSteps = steps.map { HeightValue(z: $0.zFrom, value: $0.value) }
        s.zHop = 0
        let object = pillarTower(segments: steps.count, segment: segment)
        return CalibrationPlan(kind: .retraction, steps: steps, object: object, settings: s, name: "Rückzug-Turm",
                               note: "\(steps.count) Stufen von \(String(format: "%.1f", values.first!)) mm (unten) bis \(String(format: "%.1f", values.last!)) mm (oben).")
    }

    // MARK: Max volumetric speed

    static func maxFlow(_ f: Filament, _ settings: PrintSettings) -> CalibrationPlan {
        var s = settings
        let targets = stride(from: 6.0, through: 26.0, by: 2.0).map { $0 }
        let segment = 3.0
        let width = s.outerWallLineWidth, height = s.layerHeight
        let baseSpeed = targets[0] / (width * height)
        s.spiralVase = true
        s.bottomLayers = 4
        s.outerWallSpeed = baseSpeed
        s.innerWallSpeed = baseSpeed
        s.minLayerTime = 0
        // M220 scales the speed; the safety margin is applied to the stored result.
        let steps = targets.enumerated().map { i, t in
            CalibrationStep(index: i, value: (t * 0.85 * 10).rounded() / 10, label: String(format: "%.0f mm³/s", t),
                            zFrom: Double(i) * segment + 1.0, zTo: Double(i + 1) * segment + 1.0)
        }
        s.layerGCodes = [LayerGCode(z: 0, lines: ["M220 S100"])] + targets.enumerated().dropFirst().map { i, t in
            LayerGCode(z: Double(i) * segment + 1.0, lines: ["M220 S\(Int((t / targets[0] * 100).rounded()))"])
        }
        s.footerGCode = ["M220 S100"]
        let object = ModelObject(name: "Max-Fluss-Turm", mesh: MeshCutter.cylinder(center: (0, 0), radius: 15, z0: 0, z1: segment * Double(targets.count) + 1))
        return CalibrationPlan(kind: .maxFlow, steps: steps, object: object, settings: s, name: "Max-Fluss-Turm",
                               note: "11 Stufen von 6 bis 26 mm³/s, alle 3 mm Höhe (Vasenmodus). Gespeichert wird der gewählte Wert minus 15 %.")
    }

    // MARK: Shapes

    private static func box(_ x0: Double, _ y0: Double, _ z0: Double, _ x1: Double, _ y1: Double, _ z1: Double) -> TriangleMesh {
        let v = [Vec3(x0, y0, z0), Vec3(x1, y0, z0), Vec3(x1, y1, z0), Vec3(x0, y1, z0),
                 Vec3(x0, y0, z1), Vec3(x1, y0, z1), Vec3(x1, y1, z1), Vec3(x0, y1, z1)]
        let quads = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]
        var soup: [(Vec3, Vec3, Vec3)] = []
        for q in quads {
            soup.append((v[q[0]], v[q[1]], v[q[2]]))
            soup.append((v[q[0]], v[q[2]], v[q[3]]))
        }
        return TriangleMesh(soup: soup)
    }

    /// Two pillars with a bridge on top of every segment: shows stringing (gap) and bridging (span).
    static func pillarTower(segments: Int, segment: Double) -> ModelObject {
        var mesh = TriangleMesh()
        let gap = 20.0, pillar = 8.0, depth = 10.0
        for i in 0..<segments {
            let z0 = Double(i) * segment, z1 = z0 + segment
            mesh.append(box(0, 0, z0, pillar, depth, z1))
            mesh.append(box(pillar + gap, 0, z0, 2 * pillar + gap, depth, z1))
            mesh.append(box(pillar, 0, z1 - 1.6, pillar + gap, depth, z1))
        }
        return ModelObject(name: "Kalibrierturm", mesh: mesh)
    }

    /// Stacked tiers that get narrower: every tier leaves a ring of its top surface visible.
    static func staircase(tiers: Int, height: Double) -> ModelObject {
        var mesh = TriangleMesh()
        for i in 0..<tiers {
            let size = 44 - 4.0 * Double(i)
            let o = (44 - size) / 2
            mesh.append(box(o, o, Double(i) * height, o + size, o + size, Double(i + 1) * height))
        }
        return ModelObject(name: "Fluss-Treppe", mesh: mesh)
    }

    /// A square tube with thin walls and sharp corners.
    static func hollowTower(size: Double, wall t: Double, height: Double) -> ModelObject {
        var mesh = TriangleMesh()
        mesh.append(box(0, 0, 0, size, t, height))
        mesh.append(box(0, size - t, 0, size, size, height))
        mesh.append(box(0, t, 0, t, size - t, height))
        mesh.append(box(size - t, t, 0, size, size - t, height))
        return ModelObject(name: "Pressure-Advance-Turm", mesh: mesh)
    }
}
