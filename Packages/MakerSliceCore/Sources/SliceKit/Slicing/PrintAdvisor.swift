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
        /// Ironing on with values that suit the material (speed mm/s, flow 0…1, line spacing mm).
        case ironingTuned(speed: Double, flow: Double, spacing: Double)
        case infill(InfillPattern, Double)
        case layerHeight(Double)
        case walls(Int)
        case plate(PlateType)
        case primeTower(Bool)
        case autoSplit(objectID: UUID)
        case useLoadedFilament(slot: Int, type: String)
        case retraction(slot: Int, length: Double)
        case elephantFoot(Double)
        case supportTopZ(Double)
        case supportDistances(z: Double, xy: Double)
        case outerWallSpeed(Double)
        case zHop(Double)
        case filamentFan(slot: Int, speed: Double)
        case primeTowerTuning(width: Double, volume: Double)
        case spiralVase(Bool)
        case leveling(Bool)
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
    /// - Parameter dryerHumidity: relative humidity (%) reported by the ACE Pro, if known.
    public static func recommendations(objects: [ModelObject], settings s: PrintSettings,
                                       loadedTypes: [String?] = [], dryerHumidity: Double? = nil,
                                       hoursSinceLeveling: Double? = nil) -> [Recommendation] {
        var result: [Recommendation] = []
        let analyses = objects.map { analyze($0, supportAngle: s.supportAngle) }
        let usedTools = Set(objects.map(\.tool))
        let materials = usedTools.map { s.filament(for: $0) }

        // Too big for the printer.
        for (object, a) in zip(objects, analyses)
        where a.size.x > s.bedSize - 2 || a.size.y > s.bedSize - 2 || a.size.z > s.maxHeight {
            // Often turning the object (diagonally or onto its side) is enough.
            var fitsTurned = false
            if !object.isMultiColor, let turn = BestOrientation.best(for: object, bedSize: s.bedSize, maxHeight: s.maxHeight,
                                                                     limitXY: s.bedSize - 2, limitZ: s.maxHeight - 1) {
                let size = object.transformed(turn).boundingBox.size
                fitsTurned = BestOrientation.pieces(size: size, limitXY: s.bedSize - 2, limitZ: s.maxHeight - 1) == 1
            }
            result.append(Recommendation(
                id: "split-\(object.id)", title: fitsTurned ? "„\(object.name)“ passt nur gedreht" : "„\(object.name)“ ist zu groß",
                detail: fitsTurned
                    ? String(format: "%.0f × %.0f × %.0f mm passt nicht – gedreht (schräg auf dem Druckbett oder auf der Seite) aber ohne Schnitt in den %@. Die App dreht es für dich.",
                             a.size.x, a.size.y, a.size.z, s.printer.displayName)
                    : String(format: "%.0f × %.0f × %.0f mm passt nicht in den %@. Automatisch in möglichst wenige Teile schneiden (das Teil wird dafür gedreht) – mit Dübeln zum Zusammenstecken.",
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
        } else if overhang > 30, s.support == .buildPlateOnly, analyses.contains(where: \.overhangOverModel) {
            result.append(Recommendation(
                id: "support-everywhere", title: "Stützen „Überall“ nötig",
                detail: "Einige Überhänge liegen über dem Modell selbst. Mit „Nur vom Druckbett“ entstehen dort keine Stützen und die Stellen hängen durch.",
                icon: "building.columns", severity: .warning, action: .support(.everywhere)))
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
                // Snapmaker forum (U1 "model does not stick"): 2 mm is too narrow, 10 mm or more for tall / small parts.
                let width: Double = slender || a.footprintArea < 150 ? 10 : 5
                result.append(Recommendation(
                    id: "brim", title: "Brim für bessere Haftung",
                    detail: reason + String(format: " Ein %.0f-mm-Rand verhindert Ablösen und lässt sich danach leicht abziehen. Hilft es nicht: Filament trocknen, Platte mit warmem Wasser und Spülmittel reinigen (kein Aceton), Betttemperatur 5 °C höher, Z-Hop an.", width),
                    icon: "square.dashed", severity: .suggestion, action: .brim(width)))
                break
            }
        }
        // Orca leaves a gap between brim and part when the elephant-foot compensation is set (Snapmaker forum: set it to 0).
        if s.brimWidth > 0, s.elephantFootCompensation > 0 {
            result.append(Recommendation(
                id: "brim-gap", title: "Brim ohne Abstand zum Teil",
                detail: "Mit Elefantenfuß-Ausgleich lässt der Slicer einen kleinen Spalt zwischen Brim und Teil – dann hält der Brim das Teil nicht. Im Snapmaker-Forum behob 0 mm Ausgleich das. Der Ausgleich ist nur ohne Brim sinnvoll.",
                icon: "square.dashed.inset.filled", severity: .suggestion, action: .elephantFoot(0)))
        }
        // Supports: Snapmaker forum users print organic supports with Z distance = layer height + 0.05 mm
        // (0.25 mm at 0.2 mm layers); with a different material as interface 0 mm works and leaves a clean surface.
        if s.support != .off {
            if s.supportInterfaceSlot != nil, s.supportTopZDistance > 0 {
                result.append(Recommendation(
                    id: "support-z0", title: "Stützen: Abstand 0 mm bei anderem Material",
                    detail: "Die Kontaktschicht der Stützen besteht aus einem anderen Material (z. B. PETG unter PLA). Dann haftet sie kaum, und Nutzer im Snapmaker-Forum stellen den oberen Abstand auf 0 mm – die Unterseite wird so glatter. Erst mit einem kleinen Teil testen; verschmilzt es, wieder 0,2 mm.",
                    icon: "building.columns", severity: .info, action: .supportTopZ(0)))
            } else if s.supportInterfaceSlot == nil, s.supportTopZDistance < s.layerHeight + 0.04 {
                let value = ((s.layerHeight + 0.05) * 100).rounded() / 100
                result.append(Recommendation(
                    id: "support-z", title: "Stützen lassen sich leichter lösen",
                    detail: String(format: "Bei %.2f mm Schichten nutzen Snapmaker-Anwender %.2f mm Abstand zwischen Stütze und Teil: Die Stützen gehen \"wie Butter\" ab. Für sehr hohe Stützen zusätzlich die Erweiterung der ersten Schicht auf 5–7 mm stellen.",
                                   s.layerHeight, value),
                    icon: "building.columns", severity: .suggestion, action: .supportTopZ(value)))
            }
        }

        // Support from PETG sticks to itself: more distance keeps it from welding to the part (0.28–0.30 mm Z, 0.6 mm XY).
        if s.support != .off, materials.contains(where: { $0.type.hasPrefix("PETG") }),
           s.supportTopZDistance < 0.28 || s.supportXYDistance < 0.6 {
            result.append(Recommendation(
                id: "support-petg", title: "PETG-Stützen: mehr Abstand",
                detail: "PETG verschweißt mit sich selbst. Mit 0,28 mm Abstand oben und 0,6 mm zur Seite lassen sich die Stützen sauber abbrechen und die Unterseite bleibt glatt.",
                icon: "building.columns", severity: .suggestion,
                action: .supportDistances(z: max(0.28, s.supportTopZDistance), xy: max(0.6, s.supportXYDistance))))
        }
        // Clean surface on fine prints: a fast outer wall shows ringing and wobble; 100 mm/s (inner walls stay fast).
        if s.layerHeight <= 0.16, s.outerWallSpeed > 120, !s.spiralVase {
            result.append(Recommendation(
                id: "surface-speed", title: "Glattere Außenwand",
                detail: String(format: "Bei feinen Schichten zeigt eine schnelle Außenwand Wellen und Ringe. Mit %.0f mm/s außen (innen darf es schnell bleiben) wird die sichtbare Fläche sauberer. Das kostet nur wenig Zeit.", 100),
                icon: "sparkles", severity: .suggestion, action: .outerWallSpeed(100)))
        }

        // Ironing for flat tops.
        let flatTop = analyses.map(\.flatTopArea).reduce(0, +)
        if flatTop > 400, !s.ironing, !materials.contains(where: \.isFlexible) {
            // Common starting point of the OrcaSlicer guides (Printago, Sovol, community): about 10 % flow and 0.1 mm line spacing,
            // 15–30 mm/s. PETG is sticky and smears at the nozzle: slower, and only as a hint to test first.
            if materials.contains(where: { $0.type.hasPrefix("PETG") }) {
                result.append(Recommendation(
                    id: "ironing-petg", title: "Glätten (Ironing) bei PETG nur mit Vorsicht",
                    detail: String(format: "%.0f cm² flache Oberseite. PETG klebt an der Düse, Glätten kann Schlieren oder Klümpchen geben. Mit 15 mm/s, 10 %% Fluss und 0,1 mm Linienabstand klappt es oft. Am besten erst an einem kleinen Teil testen.", flatTop / 100),
                    icon: "sparkles", severity: .info, action: .ironingTuned(speed: 15, flow: 0.10, spacing: 0.1)))
            } else {
                result.append(Recommendation(
                    id: "ironing", title: "Oberseite glätten (Ironing)",
                    detail: String(format: "%.0f cm² flache Oberseite. Glätten macht sie spiegelglatt (Druck dauert etwas länger). Eingestellt werden 20 mm/s, 10 %% Fluss und 0,1 mm Linienabstand.", flatTop / 100),
                    icon: "sparkles", severity: .suggestion, action: .ironingTuned(speed: 20, flow: 0.10, spacing: 0.1)))
            }
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

        // The bed was levelled a short while ago with the same plate: leveling again costs minutes for nothing.
        if s.enableBedLeveling, let hours = hoursSinceLeveling, hours < 12 {
            let saved = s.printer == .kobraS1 ? "ca. 4" : "2–3"
            result.append(Recommendation(
                id: "skip-leveling", title: "Nivellierung überspringen",
                detail: "Das Bett wurde vor \(hours < 1 ? "weniger als einer Stunde" : "\(Int(hours.rounded())) Stunden") nivelliert, Platte und Drucker sind unverändert. Das Überspringen spart \(saved) Minuten. Bei Plattenwechsel oder schlechter Haftung der ersten Schicht wieder einschalten.",
                icon: "timer", severity: .suggestion, action: .leveling(false)))
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
        if usedTools.count > 1, s.machine.multiMaterial == .filamentSwitcher, !s.usesPrimeTower {
            result.append(Recommendation(
                id: "tower", title: "Reinigungsturm einschalten",
                detail: "Beim Farbwechsel über die ACE bleibt Restmaterial in der Düse. Der Turm verhindert vermischte Farben am Modell.",
                icon: "square.stack.3d.up", severity: .warning, action: .primeTower(true)))
        }

        // A tower of materials that do not weld splits apart and falls over.
        if s.usesPrimeTower, PrimeTower.mixesMaterials(Set(usedTools), settings: s) {
            result.append(Recommendation(
                id: "tower-mixed", title: "Reinigungsturm aus zwei Materialien",
                detail: "\(Set(materials.map(\.type)).sorted().joined(separator: " und ")) haften nicht aneinander. Der Turm bekommt deshalb einen durchgehenden Rahmen aus dem Material, das auf den meisten Schichten druckt, dazu eine breitere Basis und einen Rand auf der ersten Schicht. Das andere Material spült nur innen.",
                icon: "square.stack.3d.up", severity: .info))
        }

        // Snapmaker U1 forum: the tower stays on (without it: strings and blobs), but a narrow tower with a small purge volume
        // saves most of the waste ("minimal purge" 10–15 mm³ instead of 60).
        if usedTools.count > 1, s.printer == .snapmakerU1 {
            if !s.usesPrimeTower {
                result.append(Recommendation(
                    id: "u1-tower", title: "Reinigungsturm nicht ganz weglassen",
                    detail: "Beim U1 hat jeder Farbe einen eigenen Druckkopf, der Turm ist klein. Ohne ihn berichten Nutzer im Snapmaker-Forum von Fäden und Klümpchen am Modell.",
                    icon: "square.stack.3d.up", severity: .suggestion, action: .primeTower(true)))
            } else if s.purgeVolume == 0 || s.purgeVolume > 40 || s.primeTowerWidth > 30 {
                result.append(Recommendation(
                    id: "u1-tower-waste", title: "Weniger Abfall am Reinigungsturm",
                    detail: "Nutzer im Snapmaker-Forum kommen mit 15 mm³ Spülmenge und etwa 25 mm Turmbreite aus. Das spart Filament und Zeit. Je dünner die Schichten, desto mehr Spülmenge braucht der Turm.",
                    icon: "square.stack.3d.up", severity: .suggestion, action: .primeTowerTuning(width: 25, volume: 15)))
            }
        }
        // PETG strings when the nozzle lifts: Z-hop pulls the soft strand up (Snapmaker PETG guide, community checklists).
        if materials.contains(where: { $0.type.hasPrefix("PETG") }), s.zHop > 0 {
            result.append(Recommendation(
                id: "petg-zhop", title: "PETG: Z-Hop aus",
                detail: "Beim Anheben der Düse zieht PETG Fäden. Ohne Z-Hop (0 mm) gibt es weniger Fäden und Klümpchen. Zuerst Filament trocknen (65 °C, 6 Stunden), dann Düse in 5-°C-Schritten kühler.",
                icon: "scribble", severity: .suggestion, action: .zHop(0)))
        }
        // Cooling (OrcaSlicer wiki and community): PETG 30–50 % (more weakens layer bonding and makes it brittle),
        // ABS/ASA 0–30 % (more warps and splits layers).
        for tool in usedTools.sorted() where tool < s.filaments.count {
            let f = s.filaments[tool]
            if f.type.hasPrefix("PETG"), f.fanSpeed > 0.6 {
                result.append(Recommendation(
                    id: "fan-petg-\(tool)", title: "PETG: Lüfter zu stark",
                    detail: String(format: "Slot %d kühlt mit %.0f %%. PETG hält bei 30–50 %% besser zwischen den Schichten zusammen und bricht nicht so leicht. Nur bei hängenden Überhängen etwas mehr.", tool + 1, f.fanSpeed * 100),
                    icon: "fan", severity: .suggestion, action: .filamentFan(slot: tool, speed: 0.4)))
            } else if f.type.hasPrefix("ABS") || f.type.hasPrefix("ASA"), f.fanSpeed > 0.3 {
                result.append(Recommendation(
                    id: "fan-abs-\(tool)", title: "\(f.type): Lüfter niedriger",
                    detail: String(format: "Slot %d kühlt mit %.0f %%. ABS/ASA verzieht und reißt zwischen den Schichten bei starker Kühlung; 0–30 %% in geschlossenem Raum sind üblich.", tool + 1, f.fanSpeed * 100),
                    icon: "fan", severity: .suggestion, action: .filamentFan(slot: tool, speed: 0.2)))
            }
        }
        // Kobra S1: the camera's spaghetti detection sometimes pauses a good print.
        if s.printer == .kobraS1 {
            result.append(Recommendation(
                id: "kobra-spaghetti", title: "Kobra S1: Fehlalarm der Spaghetti-Erkennung",
                detail: "Die KI-Erkennung pausiert gelegentlich gute Drucke, besonders bei dunklem, durchscheinendem oder glänzendem Filament, mit Resten auf dem Bett oder mit sich lösender erster Schicht. Bett freiräumen, einen Skirt drucken, die Empfindlichkeit im Display senken und die Firmware aktuell halten. Mit „Fortsetzen“ läuft der Druck weiter.",
                icon: "camera.metering.unknown", severity: .info))
        }

        result += materialAdvice(objects: objects, settings: s, usedTools: usedTools, dryerHumidity: dryerHumidity)

        // Compare with what is loaded in the printer.
        for tool in usedTools.sorted() where tool < loadedTypes.count {
            let configured = s.filament(for: tool)
            let label = "\(s.machine.slotLabel)\(tool + 1)"
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
        case .ironingTuned(let speed, let flow, let spacing):
            s.ironing = true; s.ironingSpeed = speed; s.ironingFlow = flow; s.ironingSpacing = spacing
        case .infill(let pattern, let density):
            s.infillPattern = pattern
            s.infillDensity = density
        case .layerHeight(let h):
            if let q = PrintSettings.Quality.allCases.first(where: { $0.layerHeight == h }) { s.apply(q) } else { s.layerHeight = h }
        case .walls(let n): s.wallLoops = n
        case .plate(let p): s.plateType = p
        case .primeTower(let on): s.primeTower = on; s.primeTowerAuto = on
        case .leveling(let on): s.enableBedLeveling = on
        case .retraction(let slot, let length):
            if slot < s.filaments.count { s.filaments[slot].retractLength = length }
        case .elephantFoot(let value): s.elephantFootCompensation = value
        case .supportTopZ(let value): s.supportTopZDistance = value
        case .supportDistances(let z, let xy): s.supportTopZDistance = z; s.supportXYDistance = xy
        case .outerWallSpeed(let v): s.outerWallSpeed = v
        case .zHop(let v): s.zHop = v
        case .filamentFan(let slot, let speed):
            if slot < s.filaments.count { s.filaments[slot].fanSpeed = speed; s.filaments[slot].fanMinSpeed = min(s.filaments[slot].fanMinSpeed, speed) }
        case .primeTowerTuning(let width, let volume): s.primeTowerWidth = width; s.purgeVolume = volume
        case .spiralVase(let on): s.spiralVase = on
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

    /// Printer- and material-specific advice collected from manufacturer notes and community experience.
    static func materialAdvice(objects: [ModelObject], settings s: PrintSettings, usedTools: Set<Int>,
                               dryerHumidity: Double?) -> [Recommendation] {
        var result: [Recommendation] = []
        let tools = usedTools.sorted()
        let label = { (tool: Int) in "\(s.machine.slotLabel)\(tool + 1)" }
        let flexTools = tools.filter { s.filament(for: $0).isFlexible }
        let types = Set(tools.map { s.filament(for: $0).type.uppercased() })

        // TPU.
        if !flexTools.isEmpty {
            switch s.printer {
            case .kobraS1:
                result.append(Recommendation(
                    id: "kobra-tpu", title: "TPU nicht über die ACE Pro",
                    detail: "Die ACE Pro kann weiches TPU nicht zuverlässig fördern und es kann sich im Schlauch verklemmen. TPU über den externen Spulenhalter direkt in den Druckkopf führen" + (tools.count > 1 ? " – und nicht mit Farbwechseln kombinieren." : "."),
                    icon: "exclamationmark.triangle", severity: .warning))
            case .bambuP1S:
                result.append(Recommendation(
                    id: "p1s-tpu", title: "TPU am P1S",
                    detail: "Weiches TPU nicht über das AMS führen, sondern vom externen Spulenhalter direkt zum Druckkopf. Langsam drucken (max. ca. 3,5 mm³/s), Trockenbox empfohlen." + (tools.count > 1 ? " Nicht mit Farbwechseln kombinieren." : ""),
                    icon: "exclamationmark.triangle", severity: .warning))
            case .snapmakerU1:
                result.append(Recommendation(
                    id: "u1-tpu", title: "TPU am U1",
                    detail: "Langsam drucken (max. ca. 3,5 mm³/s) und kurz zurückziehen. Ein langer Rückzug beim Werkzeugwechsel (Standard 10 mm) verursacht bei TPU oft Staus – MakerSlice zieht nur um den Filament-Rückzug zurück.",
                    icon: "info.circle", severity: .info))
            }
            for tool in flexTools where s.filament(for: tool).retractLength > 1.0 {
                result.append(Recommendation(
                    id: "tpu-retract-\(tool)", title: "\(label(tool)): Rückzug für TPU kürzen",
                    detail: String(format: "%.1f mm Rückzug ist für TPU zu viel – das weiche Filament staucht sich und verstopft. 0,8 mm empfohlen.",
                                   s.filament(for: tool).retractLength),
                    icon: "arrow.uturn.backward", severity: .suggestion, action: .retraction(slot: tool, length: 0.8)))
            }
        }

        // Moisture-sensitive materials.
        let hygroscopic = types.filter { t in ["PETG", "TPU", "TPE", "PA", "PC", "PVA", "PET"].contains { t.hasPrefix($0) } }
        if let humidity = dryerHumidity, s.printer == .kobraS1, humidity > 40, !hygroscopic.isEmpty {
            result.append(Recommendation(
                id: "ace-humid", title: "Filament ist feucht (ACE: \(Int(humidity)) %)",
                detail: "\(hygroscopic.sorted().joined(separator: ", ")) zieht Feuchtigkeit und druckt dann mit Fäden, Blasen und schwachen Schichten. Vor dem Druck in der ACE Pro trocknen (Drucker → Trocknen, 50 °C für 6–8 h).",
                icon: "humidity", severity: .warning))
        } else if !hygroscopic.isEmpty {
            result.append(Recommendation(
                id: "dry", title: "\(hygroscopic.sorted().joined(separator: ", ")) trocken verarbeiten",
                detail: "Feuchtes Filament knistert, zieht Fäden und wird spröde. PETG 6–8 h bei 60–65 °C trocknen, TPU 50–55 °C, PA/PC 70–80 °C." + (s.printer == .kobraS1 ? " Die ACE Pro trocknet bis 55 °C direkt im Drucker." : ""),
                icon: "drop.triangle", severity: .info))
        }

        // PETG.
        if types.contains(where: { $0.hasPrefix("PETG") }) {
            result.append(Recommendation(
                id: "petg-tips", title: "PETG: Fäden vermeiden",
                detail: "Bei Fäden die Düse in 5-°C-Schritten kühler stellen (230–240 °C), Rückzug 0,8–2 mm, Lüfter 30–50 %. Stützen mit 0,25 mm Abstand – PETG klebt sonst fest.",
                icon: "scribble", severity: .info))
            // Not with a brim: there the compensation opens a gap between brim and part (see "brim-gap"), the two tips would alternate.
            if s.elephantFootCompensation < 0.15, s.brimWidth == 0 {
                result.append(Recommendation(
                    id: "petg-foot", title: "Elefantenfuß ausgleichen",
                    detail: "PETG läuft auf der heißen ersten Schicht breiter. 0,2 mm Ausgleich hält die Unterkante maßhaltig.",
                    icon: "arrow.down.right.and.arrow.up.left", severity: .suggestion, action: .elephantFoot(0.2)))
            }
        }

        // Connectors need an accurate first layer.
        if objects.contains(where: { !$0.volumes.isEmpty }), s.elephantFootCompensation < 0.1, s.brimWidth == 0 {
            result.append(Recommendation(
                id: "connector-foot", title: "Passgenaue Steckverbindungen",
                detail: "Geteilte Teile mit Zapfen/Dübeln passen nur, wenn die erste Schicht nicht ausbeult. Elefantenfuß-Ausgleich auf 0,15 mm setzen.",
                icon: "puzzlepiece", severity: .suggestion, action: .elephantFoot(0.15)))
        }

        // Kobra S1 nozzle wiper.
        if s.printer == .kobraS1 {
            result.append(Recommendation(
                id: "kobra-wiper", title: "Düsenspitze prüfen",
                detail: "Der Abstreifer des Kobra S1 hinterlässt manchmal Filamentreste an der Düse, die beim Start über die erste Schicht schleifen. Spitze vor dem Druck kurz kontrollieren.",
                icon: "eye", severity: .info))
        }

        // Community experience (forums and user profiles). Shown as hints only – nothing is changed without asking.
        if s.printer == .kobraS1 {
            if types.contains(where: { $0.hasPrefix("ABS") }) {
                result.append(Recommendation(
                    id: "community-kobra-abs", title: "ABS am Kobra S1: Bett wärmer",
                    detail: "Im Drucktipps3D-Forum haftete ABS mit dem mitgelieferten Anycubic-Profil schlecht; mit 85 °C Betttemperatur (und einem Rand/Brim) funktionierte es. Die Temperaturen im Profil sind dort als zu niedrig aufgefallen.",
                    icon: "person.2", severity: .info))
            }
            if types.contains(where: { $0.hasPrefix("PETG") }) {
                result.append(Recommendation(
                    id: "community-kobra-petg", title: "PETG am Kobra S1: langsamer",
                    detail: "Nutzer berichten schlechte Schichthaftung über etwa 120 mm/s und raten zu weniger Lüfter und höherem Fluss (um 1,1). Die Werksprofile sind für PETG oft zu schnell.",
                    icon: "person.2", severity: .info))
            }
            if tools.count > 1 {
                result.append(Recommendation(
                    id: "community-kobra-purge", title: "Spülmenge am Kobra prüfen",
                    detail: "Beim Farbwechsel stellt der Drucker die Spülmenge am Display ein, nicht der Slicer – zu hohe Werte verschwenden viel Filament. Der Spül-Multiplikator sollte bei 1 stehen. Der Drucker nimmt außerdem die am Display eingestellten Farben.",
                    icon: "person.2", severity: .info))
            }
        }
        if s.printer == .bambuP1S {
            result.append(Recommendation(
                id: "community-p1s-start", title: "P1S: Startsequenz",
                detail: "MakerSlice nutzt die Original-Startsequenz von Bambu Lab. In der Community gibt es verkürzte Varianten (z. B. weniger Wischen an der Düsenbürste, Leveling nur bei Bedarf), die den Start von etwa 5 auf 2–4 Minuten kürzen. Sie ändern Bewegungen und Motorströme – deshalb nicht ungeprüft übernehmen.",
                icon: "person.2", severity: .info))
        }

        // Spiral vase sanity checks.
        if s.spiralVase {
            if objects.count > 1 || tools.count > 1 {
                result.append(Recommendation(
                    id: "vase-multi", title: "Vasenmodus nur für ein Objekt",
                    detail: "Der Vasenmodus druckt eine einzige ununterbrochene Wand. Mehrere Objekte oder Farben sind damit nicht möglich.",
                    icon: "exclamationmark.triangle", severity: .warning, action: .spiralVase(false)))
            }
            if s.support != .off {
                result.append(Recommendation(
                    id: "vase-support", title: "Stützen im Vasenmodus",
                    detail: "Stützen unterbrechen die Spirale. Vasenmodelle sollten ohne Überhänge auskommen.",
                    icon: "building.columns", severity: .suggestion, action: .support(.off)))
            }
        }
        return result
    }
}
