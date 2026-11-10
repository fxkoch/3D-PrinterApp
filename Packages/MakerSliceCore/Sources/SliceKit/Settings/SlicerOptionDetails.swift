import Foundation

/// What a setting looks like in the print: drawn as a before/after picture in the app.
public enum SettingDiagram: String, Sendable, CaseIterable {
    case layerHeight, lineWidth, wallCount, infillDensity, ironing, seam, scarfSeam, bridge, overhang
    case elephantFoot, arcFitting, supportGap, brim, fuzzySkin, crossingWalls, holeSize, topShell
    case flow, stringing, wallOrder, polyhole, thinWall, primeTower
    case speed, acceleration, jerk, infillPattern, surfacePattern, supportType, supportInterface, raft, skirt, wipe
    case gapFill, bridgeDensity, interlocking, flush, gcodeText, preheat, spiralVase, printSequence, filamentAssign, minFeature

    /// Captions for the left (less / off) and right (more / on) picture.
    public var captions: (String, String) {
        switch self {
        case .layerHeight: return ("dünne Schichten", "dicke Schichten")
        case .lineWidth: return ("schmale Linien", "breite Linien")
        case .wallCount: return ("2 Wände", "4 Wände")
        case .infillDensity: return ("15 % Füllung", "50 % Füllung")
        case .ironing: return ("ohne Ironing", "mit Ironing")
        case .seam: return ("Naht sichtbar", "Naht versteckt")
        case .scarfSeam: return ("normale Naht", "Schrägnaht")
        case .bridge: return ("Brücke durchhängend", "Brücke straff")
        case .overhang: return ("ohne Erkennung", "mit Erkennung")
        case .elephantFoot: return ("ohne Ausgleich", "mit Ausgleich")
        case .arcFitting: return ("viele Segmente", "glatte Bögen")
        case .supportGap: return ("kleiner Abstand", "großer Abstand")
        case .brim: return ("ohne Brim", "mit Brim")
        case .fuzzySkin: return ("glatt", "Fuzzy Skin")
        case .crossingWalls: return ("direkter Weg", "Umweg um Wände")
        case .holeSize: return ("ohne Korrektur", "mit Korrektur")
        case .topShell: return ("wenige Deckschichten", "viele Deckschichten")
        case .flow: return ("zu wenig Fluss", "zu viel Fluss")
        case .stringing: return ("mit Fäden", "ohne Fäden")
        case .wallOrder: return ("innen → außen", "außen → innen")
        case .polyhole: return ("rundes Loch (zu eng)", "Polyhole (passt)")
        case .thinWall: return ("Lücke", "Einzellinie")
        case .primeTower: return ("ohne Turm", "mit Turm")
        case .speed: return ("langsam", "schnell")
        case .acceleration: return ("sanft beschleunigt", "stark beschleunigt")
        case .jerk: return ("niedriger Ruck", "hoher Ruck")
        case .infillPattern: return ("Gitter-Muster", "Wellen-Muster (Gyroid)")
        case .surfacePattern: return ("parallele Linien", "konzentrisch")
        case .supportType: return ("normaler Support", "Baum-Support")
        case .supportInterface: return ("ohne Kontaktschicht", "mit Kontaktschicht")
        case .raft: return ("ohne Raft", "mit Raft")
        case .skirt: return ("ohne Schürze", "mit Schürze")
        case .wipe: return ("ohne Abwischen", "mit Abwischen")
        case .gapFill: return ("Lücke bleibt", "Lücke gefüllt")
        case .bridgeDensity: return ("lockere Brücke", "dichte Brücke")
        case .interlocking: return ("glatte Grenze", "Verzahnung")
        case .flush: return ("in den Turm", "in die Füllung")
        case .gcodeText: return ("kompakter G-Code", "ausführlicher G-Code")
        case .preheat: return ("ohne Vorheizen", "mit Vorheizen")
        case .spiralVase: return ("Schicht für Schicht", "Spirale (Vase)")
        case .printSequence: return ("Schicht für Schicht", "Objekt für Objekt")
        case .filamentAssign: return ("ein Filament", "Filament je Bereich")
        case .minFeature: return ("Detail fehlt", "Detail gedruckt")
        }
    }
}

/// A longer explanation of a setting: meaning in practice, what more/less does, a concrete example and a picture.
public struct SlicerOptionDetail: Sendable, Equatable {
    public var meaning: String
    public var more: String?
    public var less: String?
    public var example: String?
    public var diagram: SettingDiagram?
}

public enum SlicerOptionDetails {
    public static func detail(for key: String) -> SlicerOptionDetail? { all[key] ?? generated[key] }

    private static func d(_ meaning: String, more: String? = nil, less: String? = nil, example: String? = nil, diagram: SettingDiagram? = nil) -> SlicerOptionDetail {
        SlicerOptionDetail(meaning: meaning, more: more, less: less, example: example, diagram: diagram)
    }

    static let all: [String: SlicerOptionDetail] = [
        "layer_height": d("Dicke jeder einzelnen Druckschicht. Der Drucker baut das Teil wie einen Stapel dünner Scheiben auf.",
            more: "Schneller und stabiler verbunden, aber Stufen an Schrägen und Rundungen werden sichtbar.",
            less: "Glattere Schrägen und feinere Details, aber der Druck dauert deutlich länger.",
            example: "Ein 10 cm hohes Teil hat bei 0,2 mm 500 Schichten, bei 0,1 mm schon 1000 – doppelte Druckzeit.", diagram: .layerHeight),
        "line_width": d("Breite der Kunststofflinie, die die Düse legt. Sie ist meist etwas breiter als die Düse selbst.",
            more: "Stabilere Teile und schnellerer Druck, aber feine Details verwischen.",
            less: "Schärfere Details, dafür länger und etwas weniger fest.",
            example: "Bei einer 0,4-mm-Düse sind 0,42 mm für Außenwände (sauber) und 0,45–0,5 mm für Füllung (schnell) üblich.", diagram: .lineWidth),
        "wall_loops": d("Anzahl der Umrandungen (Wände) um das Teil, von außen nach innen.",
            more: "Teil wird fester und dichter (wasserdicht), braucht mehr Material und Zeit.",
            less: "Leichter und schneller, aber dünnwandig und weniger belastbar.",
            example: "Halterungen und Schrauben-Aufnahmen: 3–4 Wände. Deko-Figuren: 2 Wände genügen.", diagram: .wallCount),
        "sparse_infill_density": d("Wie dicht das Innere des Teils gefüllt wird. Das Innere ist meist ein Gitter, kein Vollmaterial.",
            more: "Fester und schwerer, aber teurer und langsamer. Oberhalb 40 % bringt es kaum noch Festigkeit.",
            less: "Leicht und schnell; Deckflächen können einsinken, wenn die Stützfläche fehlt.",
            example: "Deko 5–10 %, Alltagsteile 15–20 %, tragende Teile 30–40 %.", diagram: .infillDensity),
        "ironing_type": d("Nach dem Druck fährt die Düse noch einmal heiß und mit wenig Fluss über die Oberseite und glättet sie wie ein Bügeleisen.",
            more: "Spiegelglatte Deckflächen, aber deutlich längere Druckzeit (+10–30 %).",
            less: "Schneller, die Deckfläche zeigt die Linienstruktur.",
            example: "Nur bei sichtbaren, ebenen Flächen sinnvoll – etwa Schildern oder Deckeln.", diagram: .ironing),
        "seam_position": d("Jede Wandschleife startet und endet an einer Stelle. Dort entsteht eine kleine, sichtbare Naht.",
            more: "„Hinten ausgerichtet“ stapelt alle Nähte in einer Linie, die man leicht wegschleifen kann.",
            less: "„Zufällig“ verteilt sie, dann fällt sie weniger auf, ist aber überall zu spüren.",
            example: "Bei Vasen: ausgerichtet an der Rückseite. Bei Teilen mit scharfen Ecken: in Ecken verstecken.", diagram: .seam),
        "seam_gap": d("Lücke zwischen Anfang und Ende einer Wandschleife an der Naht.",
            more: "Weniger Nahtklumpen, aber ein sichtbarer Spalt kann entstehen.",
            less: "Geschlossene Naht, dafür kleine Verdickung an der Stelle.",
            example: "Wert in Prozent der Düsenbreite; 10 % ist ein guter Start.", diagram: .seam),
        "seam_slope_type": d("Die „Schrägnaht“ (Scarf Joint) lässt die Wand am Nahtpunkt allmählich auslaufen und beginnen, statt abrupt zu enden. Dadurch wird die Naht nahezu unsichtbar.",
            more: "Fast unsichtbare Naht an glatten Außenwänden; etwas längere Druckzeit.",
            less: "Klassische Naht mit sichtbarem Punkt.",
            example: "Besonders sinnvoll bei Rundungen und einfarbigen Teilen, wo die Naht sonst auffällt.", diagram: .scarfSeam),
        "seam_slope_conditional": d("Nutzt die Schrägnaht nur dort, wo sie sinnvoll ist (glatte Flächen), nicht an Ecken oder Überhängen.",
            more: "Bessere Ergebnisse auf glatten Flächen, weniger Fehler an Ecken.", diagram: .scarfSeam),
        "staggered_inner_seams": d("Versetzt die Nähte der Innenwände gegenüber der Außennaht.",
            more: "Die Nähte der Innenwände liegen nicht übereinander – gleichmäßigere Festigkeit.",
            less: "Alle Nähte liegen auf einer Linie – kann eine Schwachstelle bilden.", diagram: .seam),
        "wipe_on_loops": d("Zieht die Düse am Ende der Wand ein Stück nach innen, damit der Kunststoff nicht an der Naht ausblutet.",
            more: "Weniger Tröpfchen und Klumpen an der Naht, besonders bei PETG.",
            less: "Schneller, aber die Naht kann kleine Kleckse zeigen.", diagram: .wipe),
        "resolution": d("Wie fein die Modellkontur in G-Code übersetzt wird. Kleinere Werte folgen der Rundung genauer.",
            more: "Kleinere Datei und schnelleres Slicen, aber eckige Rundungen.",
            less: "Sehr glatte Rundungen, aber riesige G-Code-Dateien, die manche Drucker ruckeln lassen.",
            example: "0,012 mm ist ein sinnvoller Standard.", diagram: .arcFitting),
        "enable_arc_fitting": d("Fasst viele kleine Strecken zu echten Kreisbögen zusammen (Befehle G2/G3).",
            more: "Glattere Rundungen, kleinere G-Code-Datei, weniger Ruckeln.",
            less: "Viele kurze Geradenstücke – bei schwachem Druckerprozessor kann das Ruckeln verursachen.",
            example: "Der Drucker muss G2/G3 unterstützen; Snapmaker U1 und Kobra S1 tun das.", diagram: .arcFitting),
        "xy_hole_compensation": d("Gleicht aus, dass Löcher im Druck meist etwas zu klein werden. Negative Werte machen Löcher größer, positive kleiner.",
            more: "Löcher werden kleiner.", less: "Löcher werden größer.",
            example: "Wenn eine 5-mm-Schraube nicht in ein 5-mm-Loch passt, hier −0,1 mm testen.", diagram: .holeSize),
        "xy_contour_compensation": d("Gleicht aus, dass Außenmaße des Drucks leicht abweichen. Positive Werte machen das Teil außen größer.",
            more: "Teil wird außen größer.", less: "Teil wird außen kleiner.",
            example: "Für Steckverbindungen: erst mit Messschieber prüfen, dann in 0,05-mm-Schritten korrigieren.", diagram: .holeSize),
        "elefant_foot_compensation": d("Die erste Schicht wird auf das heiße Bett gedrückt und quetscht nach außen, sodass ein „Elefantenfuß“ entsteht. Der Ausgleich schrumpft die erste Schicht dagegen.",
            more: "Gerade Unterkante, aber bei zu hohen Werten ein sichtbarer Absatz.",
            less: "Unterkante bauscht leicht aus.",
            example: "0,1–0,2 mm bei PLA; bei höherer Bett-Temperatur eher mehr.", diagram: .elephantFoot),
        "precise_outer_wall": d("Berechnet die Position der Außenwand genauer, damit das Maß auch mit Innenwänden stimmt.",
            more: "Maßgenauere Außenflächen, besonders bei Passungen.", diagram: .holeSize),
        "hole_to_polyhole": d("Wandelt runde Löcher in ein Vieleck um, dessen Ecken genau auf dem Sollmaß liegen. Gedruckte Löcher sind sonst meist zu klein.",
            more: "Schrauben und Stifte passen besser in Löcher.",
            less: "Runde Löcher, aber oft zu eng.", example: "Besonders hilfreich bei kleinen Löchern bis ca. 8 mm.", diagram: .polyhole),
        "ironing_pattern": d("Muster, in dem beim Ironing über die Fläche gefahren wird.",
            more: "„Konzentrisch“ folgt der Kontur, „Geradlinig“ geht gerade hin und her.", example: "Geradlinig ist schneller.", diagram: .ironing),
        "wall_generator": d("Berechnet, wie die Wände gelegt werden. „Arachne“ passt die Linienbreite variabel an und füllt dünne Stellen sauber. „Klassisch“ nutzt feste Breiten.",
            more: "Arachne: bessere Wände bei dünnen Teilen, Rundungen und Text.",
            less: "Klassisch: vorhersehbar, manchmal Lücken in sehr dünnen Bereichen.", example: "Für fast alle Teile ist Arachne die bessere Wahl.", diagram: .thinWall),
        "only_one_wall_top": d("Nutzt auf der obersten Fläche nur eine Wand und spart dadurch Platz für die Deckfläche.",
            more: "Glattere Deckflächen mit weniger Linien.", less: "Mehr Wände auf der Oberseite, sichtbarer Rand.", diagram: .wallCount),
        "reduce_crossing_wall": d("Der Druckkopf macht beim Verfahren Umwege, statt über Wände zu fahren. So entstehen weniger Klumpen auf sichtbaren Flächen.",
            more: "Sauberere Oberflächen, dafür etwas längere Fahrten.",
            less: "Direkter Weg, schneller, aber Spuren auf der Wand möglich.", diagram: .crossingWalls),
        "bridge_flow": d("Fluss beim Drucken freitragender Brücken. Weniger Fluss spannt die Linie dünner und strafft sie.",
            more: "Dickere Linie, die stärker durchhängt.", less: "Dünnere, straffere Brücke, aber Lücken sind möglich.",
            example: "0,85–0,95 ist typisch; bei durchhängenden Brücken senken.", diagram: .bridge),
        "thick_bridges": d("Druckt Brücken mit dickeren Linien (Düsendurchmesser statt Schichthöhe). Dickere Linien tragen sich selbst besser.",
            more: "Stabilere Brücken ohne Durchhängen.", less: "Dünne, glatte Brücken, aber anfälliger für Durchhängen.", diagram: .bridge),
        "detect_overhang_wall": d("Erkennt, wie stark eine Wand ins Leere ragt, und druckt solche Stellen langsamer (und kühler).",
            more: "Bessere Überhänge, weniger Kringel.", less: "Schneller, aber Überhänge können ausfransen.", diagram: .overhang),
        "make_overhang_printable": d("Ändert das Modell leicht, damit Überhänge flacher werden und ohne Stützen druckbar sind.",
            more: "Weniger Stützen nötig, Modell weicht minimal ab.", example: "Praktisch für Löcher, die sonst gestützt werden müssten.", diagram: .overhang),
        "extra_perimeters_on_overhangs": d("Ergänzt Wände unter Überhängen, damit sie sich gegenseitig tragen.",
            more: "Stabilere Überhänge ohne Stütze, mehr Material.", diagram: .overhang),
        "top_solid_infill_flow_ratio": d("Fluss für die oberste Fläche. Kleine Anpassungen verbessern die Deckfläche, ohne andere Teile zu verändern.",
            more: "Dichtere, aber leicht rauere Oberfläche.", less: "Feinere Linien, aber Lücken möglich.", diagram: .flow),
        "print_flow_ratio": d("Globaler Fluss-Faktor für alle Druckteile. Gleicht aus, wenn das Filament etwas zu viel oder zu wenig fließt.",
            more: "Mehr Material: Linien verschmelzen, bei zu viel „Beulen“.", less: "Weniger Material: Lücken zwischen den Linien.",
            example: "Bei der Fluss-Kalibrierung in 1–2 %-Schritten ändern.", diagram: .flow),
        "detect_thin_wall": d("Erkennt Wände, in die keine zwei Linien passen, und druckt sie mit einer einzigen Linie.",
            more: "Dünne Wände bleiben erhalten.", less: "Dünne Wände können fehlen.", diagram: .thinWall),
        "infill_anchor": d("Verbindet Füllungslinien über ein kurzes Wandstück mit der Innenwand.",
            more: "Fester Verbund zwischen Füllung und Wand.", less: "Weniger Material, aber Füllung löst sich leichter.", diagram: .infillDensity),
        "support_top_z_distance": d("Luftspalt zwischen Stütze und Oberseite des gestützten Teils.",
            more: "Stützen lassen sich leicht lösen, die gestützte Fläche wird rauer.",
            less: "Glattere Fläche, aber Stütze haftet fester und hinterlässt Spuren.",
            example: "0,2 mm (= eine Schicht) ist ein guter Start.", diagram: .supportGap),
        "support_object_xy_distance": d("Seitlicher Abstand zwischen Stütze und Teil.",
            more: "Stütze löst sich leichter, Wände werden schlechter gestützt.", less: "Wände besser gestützt, aber festes Verkleben.", diagram: .supportGap),
        "brim_object_gap": d("Abstand zwischen Brim (Haftrand) und Teil.",
            more: "Brim lässt sich leichter abziehen.", less: "Brim haftet fest und stützt besser gegen Verzug.", diagram: .brim),
        "brim_type": d("Breite Randlinien um das Teil in der ersten Schicht, die die Haftfläche vergrößern.",
            more: "Weniger Abheben und Verzug an Ecken.", less: "Kein Randlinien-Entfernen nötig.", example: "ABS und große flache Teile profitieren am meisten.", diagram: .brim),
        "fuzzy_skin": d("Lässt die Außenwand leicht zittern, sodass eine raue, griffige Oberfläche entsteht – und Fingerabdrücke/Schichtlinien verschwinden.",
            more: "Raue Optik, versteckt Schichtlinien.", less: "Glatte Oberfläche.", diagram: .fuzzySkin),
        "fuzzy_skin_thickness": d("Wie stark die Außenwand zittert (Amplitude).", more: "Gröbere Textur.", less: "Feinere Textur.", diagram: .fuzzySkin),
        "draft_shield": d("Eine dünne Schutzwand um das Teil hält die Wärme zusammen und blockt Zugluft.",
            more: "Weniger Verzug bei ABS/ASA/PC, mehr Material.", less: "Schneller, empfindlich gegen Luftzug.", diagram: .brim),
        "ensure_vertical_shell_thickness": d("Stellt sicher, dass auch an senkrechten Flächen genug feste Schichten vorhanden sind.",
            more: "Stabilere Außenwände, wenn Füllung nur knapp dahinter liegt.", diagram: .topShell),
        "top_shell_thickness": d("Mindestdicke der Deckfläche. Mehr Schichten decken die Füllung besser zu.",
            more: "Geschlossenere Oberseite, besonders bei dünner Schichthöhe.", less: "Löcher oder Linien der Füllung scheinen durch.",
            example: "Bei 0,2 mm Schichten sind 0,8–1,0 mm üblich (4–5 Schichten).", diagram: .topShell),
        "enable_prime_tower": d("Bei Farb- oder Materialwechsel spült der Drucker die Düse an einem separaten Turm, damit keine Farbreste im Teil landen.",
            more: "Saubere Farben, aber mehr Material und Zeit.", less: "Ohne Turm bleibt Restfarbe in der Düse.", diagram: .primeTower),
        "wall_sequence": d("Reihenfolge, in der Innen- und Außenwände gedruckt werden.",
            more: "„Innen → außen“ ergibt oft die schönere Oberfläche und bessere Überhänge.",
            less: "„Außen → innen“ erreicht oft maßgenauere Außenmaße.", diagram: .wallOrder),
        "reduce_infill_retraction": d("Vermeidet Rückzüge, wenn der Weg nur über Füllung führt.",
            more: "Weniger Rückzüge – wichtig für TPU.", less: "Mehr Rückzüge, weniger Fädenziehen.", diagram: .stringing),
    ]
}

extension SettingKey {
    /// The same setting in the vendor slicer's list, for the detailed explanation and picture.
    public var slicerOptionKey: String? {
        switch self {
        case .layerHeight: return "layer_height"
        case .firstLayerHeight: return "initial_layer_print_height"
        case .lineWidth: return "line_width"
        case .outerWallLineWidth: return "outer_wall_line_width"
        case .wallLoops: return "wall_loops"
        case .topLayers: return "top_shell_layers"
        case .bottomLayers: return "bottom_shell_layers"
        case .wallOrder: return "wall_sequence"
        case .seamPosition: return "seam_position"
        case .infillPattern: return "sparse_infill_pattern"
        case .infillDensity: return "sparse_infill_density"
        case .infillOverlap: return "infill_wall_overlap"
        case .topSurfacePattern: return "top_surface_pattern"
        case .bottomSurfacePattern: return "bottom_surface_pattern"
        case .ironing: return "ironing_type"
        case .ironingSpeed: return "ironing_speed"
        case .ironingFlow: return "ironing_flow"
        case .ironingSpacing: return "ironing_spacing"
        case .detectBridges: return "thick_bridges"
        case .bridgeSpeed: return "bridge_speed"
        case .bridgeFlow: return "bridge_flow"
        case .outerWallSpeed: return "outer_wall_speed"
        case .innerWallSpeed: return "inner_wall_speed"
        case .infillSpeed: return "sparse_infill_speed"
        case .solidInfillSpeed: return "internal_solid_infill_speed"
        case .topSurfaceSpeed: return "top_surface_speed"
        case .firstLayerSpeed: return "initial_layer_speed"
        case .travelSpeed: return "travel_speed"
        case .acceleration: return "default_acceleration"
        case .outerWallAcceleration: return "outer_wall_acceleration"
        case .support: return "enable_support"
        case .supportAngle: return "support_threshold_angle"
        case .supportTopZDistance: return "support_top_z_distance"
        case .supportXYDistance: return "support_object_xy_distance"
        case .supportSpacing: return "support_base_pattern_spacing"
        case .brimWidth: return "brim_width"
        case .skirtLoops: return "skirt_loops"
        case .skirtDistance: return "skirt_distance"
        case .elephantFootCompensation: return "elefant_foot_compensation"
        case .primeTower: return "enable_prime_tower"
        case .primeTowerWidth: return "prime_tower_width"
        case .spiralVase: return "spiral_mode"
        case .fuzzySkin: return "fuzzy_skin"
        case .fuzzySkinThickness: return "fuzzy_skin_thickness"
        case .fuzzySkinPointDistance: return "fuzzy_skin_point_distance"
        case .zHop, .retractSpeed, .retractMinTravel: return nil
        default: return nil
        }
    }
}
