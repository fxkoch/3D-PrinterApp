import Foundation

/// Plain-language explanation of one setting: what it does and what changing it causes.
public struct SettingHelp: Sendable, Equatable {
    public var title: String
    /// What the setting does.
    public var summary: String
    /// Effect of a higher value / switching it on.
    public var increase: String?
    /// Effect of a lower value / switching it off.
    public var decrease: String?
    /// Practical advice, incl. printer-specific notes.
    public var tip: String?

    public init(_ title: String, _ summary: String, increase: String? = nil, decrease: String? = nil, tip: String? = nil) {
        self.title = title
        self.summary = summary
        self.increase = increase
        self.decrease = decrease
        self.tip = tip
    }
}

/// Every adjustable setting in the app.
public enum SettingKey: String, CaseIterable, Sendable {
    // Process
    case layerHeight, firstLayerHeight, lineWidth, outerWallLineWidth
    case wallLoops, topLayers, bottomLayers, wallOrder, seamPosition
    case infillPattern, infillDensity, infillOverlap
    case topSurfacePattern, bottomSurfacePattern
    case ironing, ironingSpeed, ironingFlow, ironingSpacing
    case detectBridges, bridgeSpeed, bridgeFlow
    case outerWallSpeed, innerWallSpeed, infillSpeed, solidInfillSpeed, topSurfaceSpeed, firstLayerSpeed, travelSpeed
    case acceleration, outerWallAcceleration, minLayerTime
    case support, supportAngle, supportTopZDistance, supportXYDistance, supportSpacing
    case brimWidth, skirtLoops, skirtDistance, elephantFootCompensation
    case primeTower, primeTowerWidth
    case zHop, retractSpeed, retractMinTravel
    case spiralVase, fuzzySkin, fuzzySkinThickness, fuzzySkinPointDistance
    case plateType, enableTimelapse, enableBedLeveling
    // Filament
    case nozzleTemp, firstLayerNozzleTemp, bedTemp, firstLayerBedTemp, smoothPlateBedTemp
    case fanSpeed, overhangFanSpeed, fanOffLayers, filamentMinLayerTime
    case maxVolumetricSpeed, flowRatio, retractLength, pressureAdvance

    public var help: SettingHelp { SettingsHelp.entries[self]! }
}

public enum SettingsHelp {
    public static func help(_ key: SettingKey) -> SettingHelp { key.help }

    static let entries: [SettingKey: SettingHelp] = [
        // MARK: Layers & walls
        .layerHeight: SettingHelp(
            "Schichthöhe", "Dicke jeder gedruckten Schicht.",
            increase: "Schneller, aber sichtbare Stufen an Schrägen und Rundungen.",
            decrease: "Feinere Details und glattere Schrägen, Druck dauert deutlich länger.",
            tip: "0,2 mm ist der beste Kompromiss. 0,12 mm für Figuren, 0,28 mm für große Funktionsteile. Maximal ca. 75 % des Düsendurchmessers."),
        .firstLayerHeight: SettingHelp(
            "Erste Schicht", "Dicke der ersten Schicht auf dem Druckbett.",
            increase: "Gleicht Unebenheiten des Betts besser aus und haftet sicherer.",
            decrease: "Präzisere Unterseite, aber empfindlicher bei schlechtem Leveling.",
            tip: "U1: 0,25 mm, Kobra S1: 0,2 mm (Herstellerprofile)."),
        .lineWidth: SettingHelp(
            "Linienbreite", "Breite der Innenwände und Füllungslinien.",
            increase: "Stabilere Teile, schnellerer Druck, etwas gröber.",
            decrease: "Feinere Strukturen, länger.",
            tip: "Üblich: 100–120 % des Düsendurchmessers (0,42–0,48 mm bei 0,4-mm-Düse)."),
        .outerWallLineWidth: SettingHelp(
            "Linienbreite außen", "Breite der sichtbaren Außenwand.",
            increase: "Robuster, Außenhaut verzeiht mehr.",
            decrease: "Schärfere Kanten und feinere Details.",
            tip: "0,42 mm bei 0,4-mm-Düse liefert die schönste Oberfläche."),
        .wallLoops: SettingHelp(
            "Wandlinien", "Anzahl der Umrisslinien jeder Schicht.",
            increase: "Deutlich stabiler (Wände tragen mehr als Füllung), schwerer, länger.",
            decrease: "Schneller und leichter, aber bruchanfälliger.",
            tip: "2 für Deko, 3–4 für Funktionsteile, Schrauben und Gewinde."),
        .topLayers: SettingHelp(
            "Obere Schichten", "Massive Schichten, die die Oberseite schließen.",
            increase: "Geschlossene, glatte Oberseite ohne durchscheinende Füllung.",
            decrease: "Löcher oder „Kissenbildung“ über der Füllung möglich.",
            tip: "Ziel ca. 1 mm Gesamtdicke: 5 Schichten bei 0,2 mm."),
        .bottomLayers: SettingHelp(
            "Untere Schichten", "Massive Schichten am Boden.",
            increase: "Dichterer, stabilerer Boden.",
            decrease: "Schneller, aber Boden kann durchscheinen.",
            tip: "Ziel ca. 0,6 mm: 3 Schichten bei 0,2 mm. Im Vasenmodus bilden sie den Boden der Vase."),
        .wallOrder: SettingHelp(
            "Wandreihenfolge", "Ob zuerst die inneren oder die äußere Wand gedruckt wird.",
            increase: "Außen → innen: maßhaltiger, bessere Überhänge (Außenwand wird nicht nach außen gedrückt).",
            decrease: "Innen → außen: schönste Oberfläche, Außenwand legt sich an eine fertige Innenwand.",
            tip: "Kobra-S1-Profil nutzt außen → innen, U1-Profil innen → außen."),
        .seamPosition: SettingHelp(
            "Naht", "Wo jede Wandlinie beginnt und endet. Dort bleibt eine kleine Erhebung sichtbar.",
            increase: nil, decrease: nil,
            tip: "Hinten ausgerichtet: eine saubere Linie auf der Rückseite. In Ecken: fast unsichtbar bei eckigen Teilen. Zufällig: keine Linie, dafür feine Punkte überall (gut für runde Teile)."),

        // MARK: Infill
        .infillPattern: SettingHelp(
            "Füllmuster", "Struktur im Inneren des Teils.",
            tip: "Gitter: schnell und solide. Gyroid: in alle Richtungen gleich fest, ideal für TPU und Funktionsteile. Kubisch: stabil bei wenig Material. Dreiecke: steif für flache Teile. Linien: am schnellsten."),
        .infillDensity: SettingHelp(
            "Fülldichte", "Wie viel des Inneren gefüllt wird.",
            increase: "Stabiler und schwerer; über 40 % kaum noch Gewinn, aber viel mehr Zeit.",
            decrease: "Spart Material und Zeit; unter 10 % können Oberseiten einsinken.",
            tip: "Deko 10–15 %, Gebrauchsteile 20–30 %, hochbelastet 40 % + mehr Wände."),
        .infillOverlap: SettingHelp(
            "Überlappung Füllung/Wand", "Wie weit die Füllung in die Wand hineinreicht.",
            increase: "Bessere Verbindung, aber Füllung kann außen durchdrücken.",
            decrease: "Saubere Außenhaut, Füllung löst sich eher von der Wand.",
            tip: "10–25 % ist üblich."),
        .topSurfacePattern: SettingHelp(
            "Muster Oberseite", "Linienführung der sichtbaren Oberseite.",
            tip: "Monoton: Linien laufen streng nebeneinander – gleichmäßiger Glanz ohne Streifen (Standard der Herstellerprofile). Konzentrisch: Ringe entlang der Kontur – schön bei runden Teilen. Linien: schnellste Variante."),
        .bottomSurfacePattern: SettingHelp(
            "Muster Unterseite", "Linienführung der ersten Schicht und der Unterseiten.",
            tip: "Monoton ergibt eine gleichmäßige Unterseite. Konzentrisch verzieht sich bei großen Flächen weniger in den Ecken."),

        // MARK: Surfaces
        .ironing: SettingHelp(
            "Glätten (Ironing)", "Die heiße Düse fährt ein zweites Mal fast ohne Material über die Oberseite und schmilzt sie glatt.",
            increase: "Spiegelglatte flache Oberseiten.",
            decrease: "Schneller; Oberseite zeigt die normale Linienstruktur.",
            tip: "Nur bei flachen Oberseiten sinnvoll. Bei TPU und PETG eher aus (Fäden, Kleben an der Düse)."),
        .ironingSpeed: SettingHelp(
            "Glätt-Geschwindigkeit", "Tempo der Glättfahrt.",
            increase: "Schneller, aber weniger glatt.",
            decrease: "Glatter, dauert länger.",
            tip: "20–40 mm/s."),
        .ironingFlow: SettingHelp(
            "Glätt-Fluss", "Wie viel Material beim Glätten nachgeschoben wird.",
            increase: "Füllt Rillen besser, zu viel erzeugt Wulste.",
            decrease: "Weniger Material, Rillen bleiben eher sichtbar.",
            tip: "10–15 %. Bei matten Stellen erhöhen, bei Wulsten senken."),
        .ironingSpacing: SettingHelp(
            "Glätt-Abstand", "Abstand der Glättlinien.",
            increase: "Schneller, Oberfläche weniger gleichmäßig.",
            decrease: "Glatter, dauert länger.",
            tip: "0,1–0,15 mm."),
        .detectBridges: SettingHelp(
            "Brücken erkennen", "Frei gespannte Flächen werden in der günstigsten Richtung, langsamer und mit voller Kühlung gedruckt.",
            increase: "Saubere Brücken ohne Durchhängen.",
            decrease: "Brücken werden wie normale Füllung gedruckt und hängen eher durch."),
        .bridgeSpeed: SettingHelp(
            "Brücken-Geschwindigkeit", "Tempo über freier Luft.",
            increase: "Weniger Durchhängen durch Zeit, aber Linien reißen eher.",
            decrease: "Mehr Zeit zum Abkühlen, stabilere Linien.",
            tip: "25–50 mm/s."),
        .bridgeFlow: SettingHelp(
            "Brücken-Fluss", "Materialmenge auf Brücken.",
            increase: "Dickere, stabilere Brückenstränge, hängen aber stärker.",
            decrease: "Straffere Stränge, Lücken möglich.",
            tip: "85–95 %."),

        // MARK: Speed
        .outerWallSpeed: SettingHelp(
            "Außenwand", "Druckgeschwindigkeit der sichtbaren Außenwand.",
            increase: "Schneller, aber Ringing/Ghosting und Glanzunterschiede möglich.",
            decrease: "Sauberere Oberfläche und Maßhaltigkeit.",
            tip: "Bei Seidenfilament oder Ringing auf 100–150 mm/s senken."),
        .innerWallSpeed: SettingHelp(
            "Innenwand", "Tempo der nicht sichtbaren Innenwände.",
            increase: "Schneller; begrenzt durch den Volumenstrom des Filaments.",
            decrease: "Bessere Schichthaftung."),
        .infillSpeed: SettingHelp(
            "Füllung", "Tempo der inneren Füllung.",
            increase: "Spart viel Zeit; die App drosselt automatisch auf den maximalen Volumenstrom.",
            decrease: "Stabilere Füllung bei schwierigen Materialien."),
        .solidInfillSpeed: SettingHelp(
            "Massive Füllung", "Tempo für massive Innenschichten und Unterseiten.",
            increase: "Schneller.", decrease: "Gleichmäßiger, weniger Lücken."),
        .topSurfaceSpeed: SettingHelp(
            "Oberfläche", "Tempo der obersten sichtbaren Schicht.",
            increase: "Schneller, Oberfläche kann matter/streifiger werden.",
            decrease: "Glattere, gleichmäßige Oberseite."),
        .firstLayerSpeed: SettingHelp(
            "Erste Schicht", "Tempo der ersten Schicht.",
            increase: "Schneller, aber schlechtere Haftung.",
            decrease: "Bessere Haftung auf dem Bett.",
            tip: "Bei Haftproblemen auf 30 mm/s senken."),
        .travelSpeed: SettingHelp(
            "Bewegung", "Tempo der Leerfahrten ohne Extrusion.",
            increase: "Weniger Fäden (Stringing), kürzere Druckzeit.",
            decrease: "Ruhiger, weniger Erschütterungen.",
            tip: "Kobra S1: 300 mm/s, U1: 500 mm/s (Herstellerprofile)."),
        .acceleration: SettingHelp(
            "Beschleunigung", "Wie schnell der Druckkopf auf Tempo kommt.",
            increase: "Kürzere Druckzeit, mehr Vibrationen/Ringing.",
            decrease: "Ruhigere Bewegung, schärfere Ecken, länger."),
        .outerWallAcceleration: SettingHelp(
            "Beschleunigung Außenwand", "Beschleunigung nur für die sichtbare Außenwand.",
            increase: "Schneller, Ringing an Kanten sichtbar.",
            decrease: "Sauberere Außenhaut."),
        .minLayerTime: SettingHelp(
            "Min. Schichtzeit", "Kleine Schichten werden verlangsamt, damit sie abkühlen können. 0 = Wert des Filaments.",
            increase: "Saubere Spitzen und kleine Teile, aber langsamer.",
            decrease: "Schneller; kleine Teile können weich werden und verformen."),

        // MARK: Support
        .support: SettingHelp(
            "Stützen", "Hilfsstrukturen unter Überhängen, die nach dem Druck entfernt werden.",
            tip: "Nur vom Druckbett: Stützen stehen nur auf dem Bett – leicht zu entfernen. Überall: auch auf dem Modell selbst, nötig bei Überhängen über anderen Teilen."),
        .supportAngle: SettingHelp(
            "Überhang-Winkel", "Ab welcher Neigung (von der Waagerechten gemessen) gestützt wird.",
            increase: "Mehr Stützen, sichere Überhänge.",
            decrease: "Weniger Stützen; steile Überhänge druckt der Drucker meist auch frei.",
            tip: "30° ist ein guter Wert; mit guter Kühlung (PLA) gehen auch 20°."),
        .supportTopZDistance: SettingHelp(
            "Abstand oben (Z)", "Luftspalt zwischen Stütze und Modell.",
            increase: "Stützen lösen sich leichter, Unterseite wird rauer.",
            decrease: "Schönere Unterseite, Stützen kleben fester.",
            tip: "0,2 mm bei PLA, 0,25–0,3 mm bei PETG (klebt stärker)."),
        .supportXYDistance: SettingHelp(
            "Abstand seitlich", "Seitlicher Abstand der Stützen zum Modell.",
            increase: "Stützen berühren die Wände nicht, leichter zu entfernen.",
            decrease: "Stützt auch nahe an Wänden."),
        .supportSpacing: SettingHelp(
            "Linienabstand", "Abstand der Stützlinien.",
            increase: "Weniger Material, leichter zu entfernen, weniger tragfähig.",
            decrease: "Stabilere Stützen, schwieriger zu entfernen."),

        // MARK: Adhesion
        .brimWidth: SettingHelp(
            "Brim-Breite", "Flacher Rand um das Teil auf der ersten Schicht, vergrößert die Haftfläche.",
            increase: "Hält hohe, schmale oder verzugsanfällige Teile sicher auf dem Bett.",
            decrease: "Kein Nacharbeiten nötig.",
            tip: "5 mm bei kleinen Auflageflächen, ABS/ASA/PC und hohen Teilen."),
        .skirtLoops: SettingHelp(
            "Skirt-Linien", "Linien mit Abstand um das Teil – bereitet die Düse vor, bevor das Teil beginnt.",
            increase: "Sicher gefüllte Düse beim Start.",
            decrease: "Spart etwas Zeit."),
        .skirtDistance: SettingHelp(
            "Skirt-Abstand", "Abstand des Skirts zum Teil.",
            tip: "3–6 mm."),
        .elephantFootCompensation: SettingHelp(
            "Elefantenfuß-Ausgleich", "Die erste Schicht wird etwas nach innen versetzt, weil sie flachgedrückt breiter wird.",
            increase: "Unterkante bleibt maßhaltig (wichtig für Passungen und Steckverbindungen).",
            decrease: "Mehr Haftfläche, aber ein kleiner Wulst an der Unterkante.",
            tip: "U1: 0,15 mm, Kobra S1: 0,075 mm (Herstellerprofile). Bei PETG ggf. 0,2 mm."),

        // MARK: Multi-material
        .primeTower: SettingHelp(
            "Reinigungsturm", "Kleiner Turm, in den nach jedem Farbwechsel gespült wird.",
            increase: "Saubere Farben am Modell (beim Kobra mit ACE Pro notwendig).",
            decrease: "Spart Material und Zeit, aber Farben vermischen sich am Modell.",
            tip: "Beim U1 nicht nötig – jeder Kopf hat seine eigene Düse."),
        .primeTowerWidth: SettingHelp(
            "Turmbreite", "Kantenlänge des Reinigungsturms.",
            increase: "Mehr Spülvolumen pro Schicht, sauberere Farbwechsel.",
            decrease: "Weniger Platz und Material."),

        // MARK: Retraction & travel
        .zHop: SettingHelp(
            "Z-Hop", "Bei Leerfahrten hebt die Düse kurz an.",
            increase: "Düse streift nicht über das Teil (wichtig bei Oberflächen und PETG).",
            decrease: "Weniger Fäden, etwas schneller.",
            tip: "0,4 mm Standard. Bei starkem Stringing (PETG) ggf. auf 0,2 senken."),
        .retractSpeed: SettingHelp(
            "Rückzugs-Geschwindigkeit", "Tempo, mit dem Filament vor Leerfahrten zurückgezogen wird.",
            increase: "Weniger Fäden, zu schnell kann Filament abschleifen.",
            decrease: "Schonender für weiche Materialien (TPU)."),
        .retractMinTravel: SettingHelp(
            "Min. Weg für Rückzug", "Kürzere Leerfahrten erfolgen ohne Rückzug.",
            increase: "Weniger Rückzüge, schneller, evtl. feine Fäden.",
            decrease: "Mehr Rückzüge, weniger Fäden."),

        // MARK: Special modes
        .spiralVase: SettingHelp(
            "Vasenmodus", "Druckt nur eine einzige Außenwand, die ohne Unterbrechung spiralförmig nach oben steigt – ohne Naht, ohne Deckel, ohne Füllung.",
            increase: "Nahtlose Vasen, Lampenschirme und Becher in kurzer Zeit.",
            decrease: "Normaler Druck mit Wänden, Füllung und Deckel.",
            tip: "Nur für ein einzelnes Objekt mit einer Farbe. Die unteren Schichten bilden den Boden. Linienbreite 0,5–0,6 mm macht die Wand stabiler."),
        .fuzzySkin: SettingHelp(
            "Fuzzy Skin", "Die Außenwand wird zufällig leicht nach innen und außen versetzt – das ergibt eine raue, griffige Oberfläche.",
            increase: "Griffig, versteckt Schichtlinien (Griffe, Gehäuse, Deko).",
            decrease: "Glatte Außenseite.",
            tip: "Erste Schicht bleibt glatt, damit die Haftung nicht leidet."),
        .fuzzySkinThickness: SettingHelp(
            "Fuzzy-Stärke", "Wie weit die Punkte maximal versetzt werden.",
            increase: "Gröbere Struktur.", decrease: "Feinere Struktur.",
            tip: "0,2–0,4 mm."),
        .fuzzySkinPointDistance: SettingHelp(
            "Fuzzy-Punktabstand", "Abstand der versetzten Punkte.",
            increase: "Weichere, wellige Struktur.", decrease: "Feinere, „pelzige“ Struktur, mehr G-Code."),

        // MARK: Machine
        .plateType: SettingHelp(
            "Druckplatte", "Bestimmt die Betttemperatur je Filament.",
            tip: "Strukturiertes PEI: universell, PETG löst sich gut. Glattes PEI: glänzende Unterseite, PETG kann die Beschichtung beschädigen."),
        .enableTimelapse: SettingHelp(
            "Zeitraffer", "Der U1 nimmt pro Schicht ein Kamerabild auf.",
            decrease: "Spart wenige Sekunden pro Schicht."),
        .enableBedLeveling: SettingHelp(
            "Automatisches Bett-Leveling", "Der U1 vermisst vor dem Druck das Bett im Bereich des Modells.",
            increase: "Perfekte erste Schicht.",
            decrease: "Startet ca. 1–2 Minuten schneller; nur ausschalten, wenn kürzlich gelevelt wurde."),

        // MARK: Filament
        .nozzleTemp: SettingHelp(
            "Düsentemperatur", "Schmelztemperatur ab der zweiten Schicht.",
            increase: "Bessere Schichthaftung und Glanz, aber mehr Fäden und Durchhängen.",
            decrease: "Weniger Fäden, schärfere Details, schlechtere Schichthaftung.",
            tip: "Bei Stringing in 5-°C-Schritten senken. PETG: 230–245 °C. Höheres Tempo braucht höhere Temperatur."),
        .firstLayerNozzleTemp: SettingHelp(
            "Düse 1. Schicht", "Temperatur für die erste Schicht.",
            increase: "Bessere Haftung am Bett.", decrease: "Weniger Elefantenfuß."),
        .bedTemp: SettingHelp(
            "Betttemperatur", "Temperatur des Druckbetts ab der zweiten Schicht.",
            increase: "Bessere Haftung, weniger Verzug.",
            decrease: "Teil löst sich leichter, weniger Elefantenfuß.",
            tip: "PLA 55–65 °C, PETG 70–80 °C, ABS/ASA 90–100 °C, TPU 35–50 °C."),
        .firstLayerBedTemp: SettingHelp(
            "Bett 1. Schicht", "Betttemperatur für die erste Schicht.",
            increase: "Sichere Haftung.", decrease: "Weniger Elefantenfuß."),
        .smoothPlateBedTemp: SettingHelp(
            "Bett (glatte Platte)", "Betttemperatur, wenn die glatte PEI-Platte gewählt ist.",
            tip: "Meist 5 °C weniger als auf strukturiertem PEI, weil die glatte Platte mehr Kontaktfläche bietet."),
        .fanSpeed: SettingHelp(
            "Lüfter", "Bauteilkühlung während des Drucks.",
            increase: "Schärfere Details, bessere Überhänge und Brücken.",
            decrease: "Bessere Schichthaftung, weniger Verzug (wichtig bei ABS/ASA/PC).",
            tip: "PLA 100 %, PETG 30–60 %, ABS/ASA 0–30 %."),
        .overhangFanSpeed: SettingHelp(
            "Lüfter Brücken/Überhänge", "Kühlung bei Brücken und starken Überhängen.",
            increase: "Brücken hängen weniger durch.", decrease: "Weniger Verzug bei technischen Materialien."),
        .fanOffLayers: SettingHelp(
            "Ohne Lüfter (Schichten)", "Anzahl der ersten Schichten ohne Kühlung.",
            increase: "Bessere Haftung am Bett.", decrease: "Kühlt früher, schärfere Unterkanten."),
        .filamentMinLayerTime: SettingHelp(
            "Min. Schichtzeit", "Mindestzeit pro Schicht, bevor die nächste beginnt.",
            increase: "Kleine Teile kühlen sauber ab.", decrease: "Schneller."),
        .maxVolumetricSpeed: SettingHelp(
            "Max. Volumenstrom", "Wie viel Material pro Sekunde maximal geschmolzen werden kann. Begrenzt automatisch das Tempo.",
            increase: "Schneller, aber Unterextrusion, wenn das Hotend nicht nachkommt.",
            decrease: "Sicherer, langsamer.",
            tip: "PLA 15–21 mm³/s, PETG 10–12 mm³/s, TPU 3–4 mm³/s."),
        .flowRatio: SettingHelp(
            "Flussfaktor", "Feinkorrektur der Materialmenge.",
            increase: "Mehr Material: schließt Lücken, zu viel erzeugt raue Oberflächen und Wulste.",
            decrease: "Weniger Material: glatter, zu wenig erzeugt Lücken.",
            tip: "PETG oft 0,95."),
        .retractLength: SettingHelp(
            "Rückzug", "Wie weit Filament vor Leerfahrten zurückgezogen wird.",
            increase: "Weniger Fäden, zu viel kann die Düse verstopfen.",
            decrease: "Weniger Verstopfungsgefahr, mehr Fäden.",
            tip: "Direktextruder: 0,5–1 mm (PLA), 0,8–2 mm (PETG), 0–1 mm (TPU)."),
        .pressureAdvance: SettingHelp(
            "Pressure Advance", "Gleicht den Druckaufbau in der Düse beim Beschleunigen aus.",
            increase: "Schärfere Ecken, zu viel erzeugt Lücken nach Ecken.",
            decrease: "Wulste an Ecken.",
            tip: "Wird pro Filament kalibriert; leer lassen = Wert des Druckers."),
    ]
}
