import Foundation

/// A problem seen on a finished (or failed) print.
public enum PrintProblem: String, CaseIterable, Identifiable, Sendable {
    case stringing, blobs, warping, firstLayer, gaps, weakLayers, overhangs, elephantFoot, supportsStuck, supportsFall

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .stringing: return "Fäden"
        case .blobs: return "Pickel und Naht"
        case .warping: return "Ecken heben sich"
        case .firstLayer: return "Erste Schicht hält nicht"
        case .gaps: return "Lücken, dünne Wände"
        case .weakLayers: return "Schichten halten nicht"
        case .overhangs: return "Überhänge hängen durch"
        case .elephantFoot: return "Unterkante quillt"
        case .supportsStuck: return "Stützen gehen schwer ab"
        case .supportsFall: return "Stützen fallen um"
        }
    }

    /// What it looks like.
    public var symptom: String {
        switch self {
        case .stringing: return "Feine Fäden oder Härchen zwischen Stellen, die nicht verbunden sein sollen."
        case .blobs: return "Knubbel auf der Wand oder eine deutliche Linie, wo jede Schicht beginnt."
        case .warping: return "Ecken oder Ränder biegen sich während des Drucks vom Bett hoch."
        case .firstLayer: return "Linien der ersten Schicht lösen sich, verschieben sich oder kleben an der Düse."
        case .gaps: return "Löcher in Flächen, dünne oder raue Wände, Klackern am Extruder, zermahlenes Filament."
        case .weakLayers: return "Das Teil bricht leicht entlang der Schichten oder hat Risse."
        case .overhangs: return "Schräge oder frei hängende Kanten rollen sich ein oder hängen nach unten."
        case .elephantFoot: return "Die untersten Schichten sind breiter als der Rest (Elefantenfuß)."
        case .supportsStuck: return "Stützen kleben am Teil, die Unterseite reißt beim Lösen auf."
        case .supportsFall: return "Stützen lösen sich, kippen um oder brechen während des Drucks."
        }
    }

    public var symbol: String {
        switch self {
        case .stringing: return "scribble"
        case .blobs: return "circle.dotted"
        case .warping: return "arrow.up.to.line"
        case .firstLayer: return "square.3.layers.3d"
        case .gaps: return "circle.dashed"
        case .weakLayers: return "rectangle.split.3x1"
        case .overhangs: return "arrow.down.right"
        case .elephantFoot: return "arrow.down.right.and.arrow.up.left"
        case .supportsStuck: return "building.columns"
        case .supportsFall: return "building.columns.fill"
        }
    }
}

/// One step against a problem: a change to take over, a test print, or something to check at the printer.
public struct ProblemFix: Identifiable, Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        /// A filament value for this printer, kept like a calibration result: it applies to every later print of the
        /// filament (temperature, retraction, flow, maximum flow).
        case filament(CalibrationKind, Double)
        /// A print setting, for the open print and as the printer's default.
        case setting(Recommendation.Action)
    }

    public var id: String
    public var title: String
    public var detail: String
    public var change: Change?
    /// Test print that finds the right value.
    public var calibration: CalibrationKind?

    public init(id: String, title: String, detail: String, change: Change? = nil, calibration: CalibrationKind? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.change = change
        self.calibration = calibration
    }
}

/// What helps against a print problem, for the filament in one slot and the current settings. The order follows the
/// guides of Prusa, Bambu Lab, Creality and the OrcaSlicer wiki: cheap checks first, then one change at a time,
/// and a test print where a value has to be found.
public enum PrintTroubleshooter {
    public static func fixes(for problem: PrintProblem, settings s: PrintSettings, slot: Int) -> [ProblemFix] {
        let f = s.filament(for: slot)
        let type = f.type.uppercased()
        let petg = type.hasPrefix("PETG") || type.hasPrefix("PCTG")
        let label = "\(s.machine.slotLabel)\(slot + 1)"
        let cooler = f.nozzleTemp - 5 >= f.nozzleTempMin ? f.nozzleTemp - 5 : nil
        let hotter = f.nozzleTemp + 5 <= f.nozzleTempMax ? f.nozzleTemp + 5 : nil
        let dry = ProblemFix(id: "dry", title: "Filament trocknen",
                             detail: "Feuchtes \(f.type) knistert, zieht Fäden und wird spröde. \(dryingHint(type)) Erst danach Einstellungen ändern, sonst sucht man an der falschen Stelle.")
        func tempFix(_ t: Int, why: String) -> ProblemFix {
            ProblemFix(id: "temp-\(t)", title: "Düse \(t > f.nozzleTemp ? "wärmer" : "kühler"): \(f.nozzleTemp) → \(t) °C",
                       detail: why + " Gilt danach für \(f.name) an diesem Drucker (wie ein Kalibrierwert).",
                       change: .filament(.temperature, Double(t)))
        }
        let slower = (f.maxVolumetricSpeed * 0.8 * 10).rounded() / 10
        var fixes: [ProblemFix] = []

        switch problem {
        case .stringing:
            fixes.append(dry)
            fixes.append(ProblemFix(id: "retraction-test", title: "Rückzug-Test drucken",
                                    detail: String(format: "Eingestellt sind %.1f mm. Der Test zeigt die kleinste Länge ohne Fäden. Zu viel Rückzug zieht das weiche Filament in die heiße Zone und kann die Düse verstopfen.", f.retractLength),
                                    calibration: .retraction))
            if let t = cooler { fixes.append(tempFix(t, why: "Heißes Filament läuft während der Leerfahrten nach. In 5-°C-Schritten senken, bis die Fäden weniger werden – aber nicht so weit, dass die Schichten schlecht halten.")) }
            if petg, s.zHop > 0 {
                fixes.append(ProblemFix(id: "zhop", title: "Z-Hop aus", detail: "Beim Anheben der Düse zieht PETG den weichen Faden mit hoch. Ohne Z-Hop gibt es weniger Fäden.",
                                        change: .setting(.zHop(0))))
            }
            fixes.append(ProblemFix(id: "temp-test", title: "Temperaturturm drucken", detail: "Zeigt auf einen Blick, bei welcher Temperatur Fäden, Brücken und Oberfläche am besten sind.", calibration: .temperature))

        case .blobs:
            if s.seamPosition != .corner {
                fixes.append(ProblemFix(id: "seam", title: "Naht in Ecken verstecken", detail: "Bei eckigen Teilen verschwindet der Schichtbeginn in einer Ecke. Bei runden Teilen ist „Hinten ausgerichtet“ besser.",
                                        change: .setting(.seam(.corner))))
            }
            fixes.append(ProblemFix(id: "pa-test", title: "Pressure Advance testen", detail: "Knubbel an Ecken und am Nahtpunkt kommen vom Druck in der Düse. Pressure Advance baut ihn rechtzeitig ab.", calibration: .pressureAdvance))
            fixes.append(ProblemFix(id: "retraction-test", title: "Rückzug-Test drucken", detail: "Läuft vor dem Schichtbeginn Material nach, bleibt dort ein Knubbel.", calibration: .retraction))
            if let t = cooler { fixes.append(tempFix(t, why: "Zu heißes Filament quillt nach.")) }
            fixes.append(dry)

        case .warping:
            if s.brimWidth < 5 {
                fixes.append(ProblemFix(id: "brim", title: "Brim 8 mm", detail: "Ein Rand um das Teil hält Ecken und kleine Flächen fest und lässt sich danach abziehen.",
                                        change: .setting(.brim(8))))
            }
            fixes.append(cleanPlate)
            if f.needsEnclosure {
                fixes.append(ProblemFix(id: "enclosure", title: "Haube zu, keine Zugluft", detail: "\(f.type) schrumpft beim Abkühlen stark. Haube geschlossen halten, Raum nicht lüften, Teil erst im warmen Drucker abkühlen lassen."))
            }
            if (petg || f.needsEnclosure), f.fanSpeed > 0.35 {
                fixes.append(ProblemFix(id: "fan", title: "Lüfter schwächer (\(Int(f.fanSpeed * 100)) → 30 %)", detail: "Starke Kühlung lässt \(f.type) schneller schrumpfen und die Ecken hochziehen.",
                                        change: .setting(.filamentFan(slot: slot, speed: 0.3))))
            }
            fixes.append(ProblemFix(id: "bed-up", title: "Bett 5 °C wärmer", detail: "Ein wärmeres Bett hält die unteren Schichten weicher und haftender.",
                                    change: .setting(.filamentBedDelta(slot: slot, delta: 5))))

        case .firstLayer:
            fixes.append(cleanPlate)
            if !s.enableBedLeveling {
                fixes.append(ProblemFix(id: "leveling", title: "Bett vor dem Druck vermessen", detail: "Die Nivellierung ist aus. Nach Plattenwechsel oder Transport stimmt der Abstand nicht mehr überall.",
                                        change: .setting(.leveling(true))))
            }
            if s.firstLayerSpeed > 35 {
                fixes.append(ProblemFix(id: "first-speed", title: String(format: "Erste Schicht langsamer (%.0f → 30 mm/s)", s.firstLayerSpeed),
                                        detail: "Langsam hat die erste Schicht Zeit, sich auf die Platte zu legen.", change: .setting(.firstLayerSpeed(30))))
            }
            if petg, s.plateType == .highTemp {
                fixes.append(ProblemFix(id: "plate", title: "Strukturierte Platte für PETG", detail: "Auf glattem PEI haftet PETG zu stark und kann die Beschichtung herausreißen.",
                                        change: .setting(.plate(.texturedPEI))))
            }
            fixes.append(ProblemFix(id: "bed-up", title: "Bett 5 °C wärmer", detail: "Hilft, wenn die Linien sauber liegen, sich aber später lösen.",
                                    change: .setting(.filamentBedDelta(slot: slot, delta: 5))))
            fixes.append(ProblemFix(id: "z-offset", title: "Abstand Düse–Bett prüfen", detail: "Die erste Schicht soll leicht flachgedrückt sein, ohne Lücken zwischen den Linien. Rund und lose: Düse etwas näher (Z-Offset am Drucker in 0,02-mm-Schritten). Durchsichtig und rau: etwas weiter weg."))

        case .gaps:
            fixes.append(ProblemFix(id: "speed-factor", title: "Tempo am Drucker prüfen", detail: "Steht das Tempo am Drucker über 100 %, schafft der Extruder die Menge nicht und zermahlt das Filament. In der Live-Ansicht auf 100 % stellen."))
            if !s.factorCommands.isEmpty || !s.footerGCode.isEmpty || !s.retractLengthSteps.isEmpty {
                fixes.append(ProblemFix(id: "leftovers", title: "Tempo-Befehle aus der Kalibrierung entfernen", detail: "Die Einstellungen enthalten Tempo- oder Fluss-Stufen eines Kalibrierdrucks.",
                                        change: .setting(.removeLeftoverCommands)))
            }
            fixes.append(ProblemFix(id: "maxflow-down", title: String(format: "Max. Fluss senken (%.1f → %.1f mm³/s)", f.maxVolumetricSpeed, slower),
                                    detail: "Druckt langsamer, wo die Düse sonst nicht genug Filament schmelzen kann. Gilt danach für \(f.name) an diesem Drucker.",
                                    change: .filament(.maxFlow, slower), calibration: .maxFlow))
            if let t = hotter { fixes.append(tempFix(t, why: "Wärmeres Filament fließt leichter durch die Düse.")) }
            fixes.append(ProblemFix(id: "flow-test", title: "Fluss testen", detail: String(format: "Eingestellt ist ein Fluss von %.2f. Lücken in Deckflächen bei sonst sauberem Druck: Fluss in 2–3-%%-Schritten anpassen.", f.flowRatio), calibration: .flow))
            fixes.append(ProblemFix(id: "nozzle", title: "Düse prüfen", detail: "Eine teilweise verstopfte Düse fördert zu wenig. Kaltzug (Cold Pull) machen oder Düse tauschen; bei \(label) auch den Schlauch auf Knicke prüfen."))
            fixes.append(dry)

        case .weakLayers:
            if let t = hotter { fixes.append(tempFix(t, why: "Heißere Schichten verschmelzen besser miteinander.")) }
            if (petg || f.needsEnclosure), f.fanSpeed > 0.35 {
                fixes.append(ProblemFix(id: "fan", title: "Lüfter schwächer (\(Int(f.fanSpeed * 100)) → 30 %)", detail: "Zu starke Kühlung lässt die nächste Schicht auf kaltem Material liegen.",
                                        change: .setting(.filamentFan(slot: slot, speed: 0.3))))
            }
            fixes.append(ProblemFix(id: "maxflow-down", title: String(format: "Langsamer drucken (max. Fluss %.1f → %.1f mm³/s)", f.maxVolumetricSpeed, slower),
                                    detail: "Mehr Zeit in der heißen Düse: das Filament ist ganz geschmolzen und verbindet sich besser.",
                                    change: .filament(.maxFlow, slower)))
            if s.wallLoops < 4 {
                fixes.append(ProblemFix(id: "walls", title: "4 Wände", detail: "Mehr Wände tragen Kräfte zwischen den Schichten besser als mehr Füllung.", change: .setting(.atLeastWalls(4))))
            }
            fixes.append(dry)

        case .overhangs:
            if !s.slowDownOverhangs || s.overhangSpeed > 30 {
                fixes.append(ProblemFix(id: "overhang-speed", title: "Überhänge langsamer (25 mm/s)", detail: "Wände über freier Luft werden langsam und mit vollem Lüfter gedruckt.",
                                        change: .setting(.overhangSlowdown(speed: 25))))
            }
            if let t = cooler { fixes.append(tempFix(t, why: "Kühleres Filament erstarrt schneller und hängt weniger durch.")) }
            fixes.append(ProblemFix(id: "supports", title: "Stützen ab etwa 55°", detail: "Überhänge flacher als etwa 35° zur Waagerechten (55° von der Senkrechten) brauchen Stützen. Im Vorbereiten-Bildschirm „Stützen“ einschalten."))
            fixes.append(ProblemFix(id: "orientation", title: "Teil anders hinlegen", detail: "Oft verschwindet der Überhang, wenn das Teil gedreht oder auf eine andere Seite gelegt wird (Objekt-Menü → Flach hinlegen)."))

        case .elephantFoot:
            if s.elephantFootCompensation < 0.2, s.brimWidth == 0 {
                fixes.append(ProblemFix(id: "foot", title: String(format: "Elefantenfuß ausgleichen (%.2f → 0,2 mm)", s.elephantFootCompensation),
                                        detail: "Die erste Schicht wird um diesen Betrag nach innen gezogen und quillt dann auf die richtige Breite.",
                                        change: .setting(.elephantFoot(0.2))))
            }
            fixes.append(ProblemFix(id: "bed-down", title: "Bett 5 °C kühler", detail: "Ein zu heißes Bett hält die unteren Schichten weich, sie geben unter dem Gewicht nach.",
                                    change: .setting(.filamentBedDelta(slot: slot, delta: -5))))
            fixes.append(ProblemFix(id: "z-offset", title: "Düse nicht zu nah", detail: "Ist die Düse beim ersten Layer zu nah am Bett, wird die Schicht breitgequetscht. Z-Offset am Drucker in 0,02-mm-Schritten erhöhen."))

        case .supportsStuck:
            let contact = s.filament(for: s.supportInterfaceSlot ?? s.supportSlot ?? slot).type.uppercased()
            if contact.hasPrefix("PETG"), s.supportTopZDistance < 0.28 || s.supportXYDistance < 0.6 {
                fixes.append(ProblemFix(id: "petg-gap", title: "Mehr Abstand für PETG (0,28 mm, seitlich 0,6 mm)", detail: "PETG verschweißt mit sich selbst. Mit etwas mehr Luft brechen die Stützen sauber ab.",
                                        change: .setting(.supportDistances(z: max(0.28, s.supportTopZDistance), xy: max(0.6, s.supportXYDistance)))))
            } else if !contact.hasPrefix("PETG"), s.supportTopZDistance < s.layerHeight + 0.04 {
                let value = ((s.layerHeight + 0.05) * 100).rounded() / 100
                fixes.append(ProblemFix(id: "gap", title: String(format: "Abstand oben %.2f mm", value), detail: "Eine Schichthöhe plus 0,05 mm: Die Stützen tragen noch, lösen sich aber leicht.",
                                        change: .setting(.supportTopZ(value))))
            }
            if s.supportBottomZDistance < 0.2 {
                fixes.append(ProblemFix(id: "bottom-gap", title: "Abstand unten 0,2 mm", detail: "Wo Stützen auf dem Teil stehen, bleibt eine Schicht Luft. So verschweißen sie nicht mit der Oberfläche darunter.",
                                        change: .setting(.supportBottomZ(0.2))))
            }
            if s.machine.toolCount > 1 {
                fixes.append(ProblemFix(id: "interface", title: "Kontaktschicht aus anderem Material", detail: "Mit einem zweiten Druckkopf oder Slot: Stützen oder nur ihre Kontaktschicht aus einem Material, das nicht am Teil haftet (PLA unter PETG, PETG unter PLA). Experte → Stütz-Material."))
            }

        case .supportsFall:
            if s.brimWidth == 0 {
                fixes.append(ProblemFix(id: "brim", title: "Brim 5 mm", detail: "Der Rand läuft auch um die Füße der Stützen und hält hohe, schmale Stützen am Bett.",
                                        change: .setting(.brim(5))))
            }
            if s.supportSpacing > 2 {
                fixes.append(ProblemFix(id: "spacing", title: String(format: "Stützen dichter (%.1f → 2 mm)", s.supportSpacing), detail: "Mehr Linien stützen sich gegenseitig und kippen nicht so leicht.",
                                        change: .setting(.supportSpacing(2))))
            }
            fixes.append(ProblemFix(id: "foot-info", title: "Stützen auf dem Teil", detail: "Stehen Stützen aus einem anderen Material auf dem Teil (PLA auf PETG), druckt die App dort automatisch einen dichten, breiteren Fuß und drei dichte Kontaktschichten."))
            fixes.append(dry)
        }
        return fixes
    }

    static let cleanPlate = ProblemFix(id: "clean", title: "Platte reinigen",
                                       detail: "Fett von Fingern verhindert die Haftung: Platte mit warmem Wasser und Spülmittel abwaschen und gut trocknen. Kein Aceton, es greift PEI an.")

    /// Drying recommendation for a filament type.
    static func dryingHint(_ type: String) -> String {
        let t = type.uppercased()
        if t.hasPrefix("PLA") { return "PLA trocknet bei 45–50 °C in 4–6 Stunden." }
        if t.hasPrefix("PETG") || t.hasPrefix("PCTG") { return "PETG trocknet bei 60–65 °C in 4–6 Stunden." }
        if t.hasPrefix("TPU") || t.hasPrefix("TPE") { return "TPU trocknet bei 50–55 °C in 4–6 Stunden." }
        if t.hasPrefix("ABS") || t.hasPrefix("ASA") { return "\(type) trocknet bei 65–80 °C in 4 Stunden." }
        if t.hasPrefix("PA") { return "PA (Nylon) trocknet bei 70–80 °C in 8–12 Stunden." }
        if t.hasPrefix("PC") { return "PC trocknet bei 70–80 °C in 6–8 Stunden." }
        if t.hasPrefix("PVA") { return "PVA trocknet bei 45–55 °C in 6–8 Stunden." }
        return "Temperatur und Zeit stehen meist auf der Spule."
    }
}
