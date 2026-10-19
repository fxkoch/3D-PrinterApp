import Foundation

/// A suggestion for a better print, optionally with a one-tap fix.
public struct Recommendation: Identifiable, Sendable, Equatable {
    public enum Severity: Int, Sendable, Comparable {
        case info, suggestion, warning
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Action: Sendable, Equatable {
        case support(SupportMode)
        case brim(Double)
        case ironing(Bool)
        case infill(InfillPattern, Double)
        case layerHeight(Double)
        case walls(Int)
        case plate(PlateType)
        case primeTower(Bool)
        case autoSplit(objectID: UUID)
        case useLoadedFilament(slot: Int, type: String)
    }

    public var id: String
    public var title: String
    public var detail: String
    /// SF Symbol name.
    public var icon: String
    public var severity: Severity
    public var action: Action?

    public init(id: String, title: String, detail: String, icon: String, severity: Severity, action: Action? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.icon = icon
        self.severity = severity
        self.action = action
    }
}

/// Looks at the models and settings and suggests what makes the print succeed:
/// supports, brim, ironing, infill, layer height, splitting, material checks.
public enum PrintAdvisor {
    /// Geometric facts about one object.
    public struct ObjectAnalysis: Sendable {
        public var overhangArea: Double       // mm², faces needing support
        public var overhangOverModel: Bool    // some overhangs sit above the model itself
        public var flatTopArea: Double        // mm², horizontal upward faces above the bed
        public var footprintArea: Double      // mm², faces touching the bed
        public var size: Vec3
        public var volume: Double             // mm³
    }

    public static func analyze(_ object: ModelObject, supportAngle: Double = 30) -> ObjectAnalysis {
        let mesh = object.mesh
        let box = mesh.boundingBox
        let threshold = cos(max(5, min(85, supportAngle)) * .pi / 180)
        var overhang = 0.0, flatTop = 0.0, footprint = 0.0
        var overhangPoints: [Vec3] = []
        for t in 0..<mesh.triangleCount {
            let a = mesh.vertices[Int(mesh.indices[t * 3])]
            let b = mesh.vertices[Int(mesh.indices[t * 3 + 1])]
            let c = mesh.vertices[Int(mesh.indices[t * 3 + 2])]
            let cross = (b - a).cross(c - a)
            let area = cross.length / 2
            guard area > 1e-9 else { continue }
            let nz = cross.z / (2 * area)
            let zMin = min(a.z, b.z, c.z)
            if nz < -0.99, zMin < box.min.z + 0.05 {
                footprint += area
            } else if -nz > threshold, zMin > box.min.z + 0.3 {
                overhang += area * -nz
                if overhangPoints.count < 400 { overhangPoints.append((a + b + c) * (1.0 / 3)) }
            } else if nz > 0.995, zMin > box.min.z + 0.5 {
                flatTop += area
            }
        }
        // Is there model material below the overhangs (→ supports would stand on the model)?
        var overModel = false
        if !overhangPoints.isEmpty {
            let heights = stride(from: box.min.z + 0.5, through: box.max.z, by: max(1, box.size.z / 40)).map { $0 }
            let slices = MeshSlicer.slice(mesh, at: heights)
            outer: for p in overhangPoints {
                let ip = IntPoint(mmX: p.x, mmY: p.y)
                for (i, z) in heights.enumerated() where z < p.z - 1 && slices[i].contains(ip) {
                    overModel = true
                    break outer
                }
            }
        }
        return ObjectAnalysis(overhangArea: overhang, overhangOverModel: overModel, flatTopArea: flatTop,
                              footprintArea: footprint, size: box.size, volume: mesh.volume)
    }

    /// - Parameter loadedTypes: material reported by the printer per slot (nil = unknown/empty).
    public static func recommendations(objects: [ModelObject], settings s: PrintSettings,
                                       loadedTypes: [String?] = []) -> [Recommendation] {
        var result: [Recommendation] = []
        let analyses = objects.map { analyze($0, supportAngle: s.supportAngle) }
        let usedTools = Set(objects.map(\.tool))
        let materials = usedTools.map { s.filament(for: $0) }

        // Too big for the printer.
        for (object, a) in zip(objects, analyses)
        where a.size.x > s.bedSize - 2 || a.size.y > s.bedSize - 2 || a.size.z > s.maxHeight {
            result.append(Recommendation(
                id: "split-\(object.id)", title: "„\(object.name)“ ist zu groß",
                detail: String(format: "%.0f × %.0f × %.0f mm passt nicht in den %@. Automatisch in Teile schneiden – mit Dübeln zum Zusammenstecken.",
                               a.size.x, a.size.y, a.size.z, s.printer.displayName),
                icon: "scissors", severity: .warning, action: .autoSplit(objectID: object.id)))
        }

        // Supports.
        let overhang = analyses.map(\.overhangArea).reduce(0, +)
        if overhang > 30, s.support == .off {
            let mode: SupportMode = analyses.contains(where: \.overhangOverModel) ? .everywhere : .buildPlateOnly
            result.append(Recommendation(
                id: "support", title: "Stützen einschalten",
                detail: String(format: "Etwa %.0f mm² hängen frei in der Luft (flacher als %.0f°). Ohne Stützen hängen diese Stellen durch.",
                               overhang, s.supportAngle) + (mode == .everywhere ? " Einige Überhänge liegen über dem Modell – Stützen „Überall“." : ""),
                icon: "building.columns", severity: .warning, action: .support(mode)))
        } else if overhang < 5, s.support != .off {
            result.append(Recommendation(
                id: "support-off", title: "Stützen sind unnötig",
                detail: "Das Modell hat keine nennenswerten Überhänge. Ohne Stützen geht es schneller und die Oberfläche bleibt sauber.",
                icon: "building.columns", severity: .suggestion, action: .support(.off)))
        }
        if s.detectBridges {
            result.append(Recommendation(
                id: "bridges", title: "Brücken werden erkannt",
                detail: "Frei gespannte Flächen werden in der besten Richtung, langsamer und mit voller Kühlung gedruckt.",
                icon: "point.topleft.down.to.point.bottomright.curvepath", severity: .info))
        }

        // Bed adhesion.
        let warpProne = materials.contains { $0.needsEnclosure }
        for (object, a) in zip(objects, analyses) where s.brimWidth == 0 {
            let slender = a.footprintArea > 0 && a.size.z / max(a.footprintArea.squareRoot(), 1) > 3.5
            if a.footprintArea < 150 || slender || (warpProne && a.footprintArea > 2500) {
                let reason = warpProne ? "\(materials.first { $0.needsEnclosure }!.type) neigt zum Verziehen."
                    : slender ? "„\(object.name)“ ist hoch und steht auf kleiner Fläche."
                    : "„\(object.name)“ hat wenig Kontaktfläche zum Bett."
                result.append(Recommendation(
                    id: "brim", title: "Brim für bessere Haftung",
                    detail: reason + " Ein 5-mm-Rand verhindert Ablösen und lässt sich danach leicht abziehen.",
                    icon: "square.dashed", severity: .suggestion, action: .brim(5)))
                break
            }
        }

        // Ironing for flat tops.
        let flatTop = analyses.map(\.flatTopArea).reduce(0, +)
        if flatTop > 400, !s.ironing, !materials.contains(where: \.isFlexible) {
            result.append(Recommendation(
                id: "ironing", title: "Oberseite glätten (Ironing)",
                detail: String(format: "%.0f cm² flache Oberseite. Glätten macht sie spiegelglatt (Druck dauert etwas länger).", flatTop / 100),
                icon: "sparkles", severity: .suggestion, action: .ironing(true)))
        }

        // Infill pattern and density.
        if materials.contains(where: \.isFlexible), s.infillPattern != .gyroid {
            result.append(Recommendation(
                id: "infill-flex", title: "Gyroid-Füllung für flexibles Material",
                detail: "Bei TPU federt Gyroid gleichmäßig in alle Richtungen und verhindert Knicke.",
                icon: "waveform.path", severity: .suggestion, action: .infill(.gyroid, max(s.infillDensity, 0.15))))
        } else if let tall = zip(objects, analyses).first(where: { $0.1.size.z > 2.5 * min($0.1.size.x, $0.1.size.y) && $0.1.size.z > 60 }),
                  s.infillPattern == .lines || s.infillPattern == .grid {
            result.append(Recommendation(
                id: "infill-tall", title: "Stabilere Füllung für hohe Teile",
                detail: "„\(tall.0.name)“ ist hoch und schlank. Kubische Füllung mit 20 % hält seitlichen Kräften besser stand.",
                icon: "cube", severity: .suggestion, action: .infill(.cubic, max(s.infillDensity, 0.2))))
        } else if analyses.map(\.volume).reduce(0, +) > 150_000, s.infillDensity > 0.2 {
            result.append(Recommendation(
                id: "infill-save", title: "Material sparen",
                detail: "Bei großen Teilen reichen meist 12 % Gyroid – spart Zeit und Filament bei guter Stabilität.",
                icon: "leaf", severity: .info, action: .infill(.gyroid, 0.12)))
        }

        // Layer height.
        let smallest = analyses.map { min($0.size.x, $0.size.y, $0.size.z) }.min() ?? 0
        if smallest > 0, smallest < 12, s.layerHeight >= 0.2 {
            result.append(Recommendation(
                id: "fine", title: "Feinere Schichten für kleine Details",
                detail: "Das Modell ist klein. 0,12 mm Schichthöhe bildet Details deutlich schärfer ab.",
                icon: "textformat.size.smaller", severity: .suggestion, action: .layerHeight(0.12)))
        } else if (analyses.map(\.size.z).max() ?? 0) > 150, s.layerHeight < 0.24, !materials.contains(where: \.isFlexible) {
            result.append(Recommendation(
                id: "draft", title: "Schneller drucken",
                detail: "Bei großen Modellen spart 0,28 mm Schichthöhe viele Stunden bei kaum sichtbarem Unterschied.",
                icon: "hare", severity: .info, action: .layerHeight(0.28)))
        }

        // Material vs plate.
        if materials.contains(where: { $0.type.uppercased().hasPrefix("PETG") }), s.plateType == .highTemp {
            result.append(Recommendation(
                id: "petg-plate", title: "PETG auf glatter Platte",
                detail: "PETG haftet auf glattem PEI so stark, dass es die Beschichtung beschädigen kann. Strukturierte Platte verwenden.",
                icon: "exclamationmark.triangle", severity: .warning, action: .plate(.texturedPEI)))
        }
        if warpProne, s.printer == .snapmakerU1 {
            result.append(Recommendation(
                id: "enclosure", title: "Temperaturempfindliches Material",
                detail: "ABS/ASA/PC/PA verziehen sich bei Zugluft. Abdeckung geschlossen halten und Raum nicht lüften.",
                icon: "thermometer.medium", severity: .info))
        }

        // Multi-material on the Kobra.
        if usedTools.count > 1, s.machine.multiMaterial == .filamentSwitcher, !s.primeTower {
            result.append(Recommendation(
                id: "tower", title: "Reinigungsturm einschalten",
                detail: "Beim Farbwechsel über die ACE bleibt Restmaterial in der Düse. Der Turm verhindert vermischte Farben am Modell.",
                icon: "square.stack.3d.up", severity: .warning, action: .primeTower(true)))
        }

        // Compare with what is loaded in the printer.
        for tool in usedTools.sorted() where tool < loadedTypes.count {
            let configured = s.filament(for: tool)
            let label = s.printer == .kobraS1 ? "Slot \(tool + 1)" : "T\(tool + 1)"
            guard let loaded = loadedTypes[tool], !loaded.isEmpty, loaded.uppercased() != "NONE" else {
                result.append(Recommendation(
                    id: "empty-\(tool)", title: "\(label) ist leer",
                    detail: "Für den Druck wird \(label) benötigt, aber der Drucker meldet dort kein Filament.",
                    icon: "exclamationmark.circle", severity: .warning))
                continue
            }
            let loadedBase = loaded.uppercased().split(separator: " ").first.map(String.init) ?? loaded
            if !configured.type.uppercased().hasPrefix(loadedBase) && !loadedBase.hasPrefix(configured.type.uppercased()) {
                result.append(Recommendation(
                    id: "mismatch-\(tool)", title: "\(label): \(loaded) eingelegt",
                    detail: "Eingestellt ist \(configured.name). Temperaturen und Kühlung an das eingelegte Material anpassen.",
                    icon: "arrow.triangle.2.circlepath", severity: .warning,
                    action: .useLoadedFilament(slot: tool, type: loaded)))
            }
        }
        return result.sorted { $0.severity > $1.severity }
    }

    /// Applies a recommendation. Splitting replaces the object with its parts and re-arranges the plate.
    public static func apply(_ action: Recommendation.Action, settings s: inout PrintSettings, objects: inout [ModelObject]) throws {
        switch action {
        case .support(let mode): s.support = mode
        case .brim(let width): s.brimWidth = width
        case .ironing(let on): s.ironing = on
        case .infill(let pattern, let density):
            s.infillPattern = pattern
            s.infillDensity = density
        case .layerHeight(let h):
            if let q = PrintSettings.Quality.allCases.first(where: { $0.layerHeight == h }) { s.apply(q) } else { s.layerHeight = h }
        case .walls(let n): s.wallLoops = n
        case .plate(let p): s.plateType = p
        case .primeTower(let on): s.primeTower = on
        case .useLoadedFilament(let slot, let type):
            if slot < s.filaments.count, var f = FilamentLibrary.bestMatch(type: type, printer: s.printer) {
                f.color = s.filaments[slot].color
                s.filaments[slot] = f
            }
        case .autoSplit(let id):
            guard let index = objects.firstIndex(where: { $0.id == id }) else { return }
            let parts = try MeshCutter.autoSplit(objects[index], bedSize: s.bedSize, maxHeight: s.maxHeight)
            objects.remove(at: index)
            objects.insert(contentsOf: parts, at: index)
            if let arranged = PlateArranger.arrange(objects, bedSize: s.bedSize) { objects = arranged }
        }
    }
}
