import Foundation

/// The calibration prints the app can create.
public enum CalibrationKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case temperature, flow, pressureAdvance, retraction, maxFlow

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .temperature: return "Temperatur"
        case .flow: return "Fluss"
        case .pressureAdvance: return "Pressure Advance"
        case .retraction: return "Rückzug"
        case .maxFlow: return "Max. Fließgeschwindigkeit"
        }
    }

    public var symbol: String {
        switch self {
        case .temperature: return "thermometer.medium"
        case .flow: return "drop"
        case .pressureAdvance: return "arrow.turn.up.right"
        case .retraction: return "arrow.uturn.backward"
        case .maxFlow: return "gauge.high"
        }
    }

    /// One sentence for the list.
    public var summary: String {
        switch self {
        case .temperature: return "Findet die beste Düsentemperatur für dieses Filament."
        case .flow: return "Gleicht aus, wenn das Filament zu viel oder zu wenig fließt."
        case .pressureAdvance: return "Schärfere Ecken und gleichmäßigere Linien."
        case .retraction: return "Weniger Fäden zwischen getrennten Teilen."
        case .maxFlow: return "Wie schnell die Düse Filament höchstens schmelzen kann."
        }
    }

    /// Roughly how long the test print takes and how much filament it uses.
    public var effort: String {
        switch self {
        case .temperature: return "ca. 35 Min. · 7 g"
        case .flow: return "ca. 30 Min. · 12 g"
        case .pressureAdvance: return "ca. 20 Min. · 3 g"
        case .retraction: return "ca. 35 Min. · 8 g"
        case .maxFlow: return "ca. 15 Min. · 4 g"
        }
    }

    /// Unit of the measured value.
    public var unit: String {
        switch self {
        case .temperature: return "°C"
        case .flow: return ""
        case .pressureAdvance: return ""
        case .retraction: return "mm"
        case .maxFlow: return "mm³/s"
        }
    }

    public func format(_ value: Double) -> String {
        switch self {
        case .temperature: return "\(Int(value.rounded())) °C"
        case .flow: return String(format: "%.3f", value)
        case .pressureAdvance: return String(format: "%.3f", value)
        case .retraction: return String(format: "%.1f mm", value)
        case .maxFlow: return String(format: "%.1f mm³/s", value)
        }
    }

    /// Why this calibration matters.
    public var why: String {
        switch self {
        case .temperature:
            return "Jedes Filament (auch jede Farbe und Marke) hat sein eigenes Temperaturfenster. Zu kalt: schwache Schichthaftung, rauhe Oberfläche, verstopfte Düse. Zu heiß: Fäden, Tropfen, schlechte Überhänge und Brücken."
        case .flow:
            return "Der Durchmesser des Filaments und sein Schmelzverhalten schwanken. Zu wenig Fluss lässt Lücken in den Deckflächen, zu viel macht Beulen, raue Oberflächen und falsche Maße."
        case .pressureAdvance:
            return "In der Düse baut sich Druck auf. Beim Beschleunigen fehlt Material (Ecken werden rund), beim Bremsen läuft zu viel nach (Beulen an Ecken). Pressure Advance gleicht das aus."
        case .retraction:
            return "Vor jeder Leerfahrt zieht der Drucker das Filament ein Stück zurück, damit nichts aus der Düse läuft. Zu wenig Rückzug: Fäden. Zu viel: verstopfte Düse, Lücken nach dem Rückzug."
        case .maxFlow:
            return "Die Düse kann nur eine bestimmte Menge Filament pro Sekunde schmelzen. Wird schneller gedruckt, fehlt Material – die Wände werden dünn und rau, Schichten halten schlecht."
        }
    }

    /// What to do, step by step.
    public var instructions: [String] {
        switch self {
        case .temperature:
            return ["Das Filament in den gewählten Slot einlegen und trocken halten.",
                    "Testturm drucken: Von unten nach oben fällt die Temperatur in 5-°C-Schritten.",
                    "Den fertigen Turm ansehen: Fäden zwischen den Säulen, Brücken (Durchhängen), Oberfläche.",
                    "Die Stufe wählen, bei der Brücke und Oberfläche am besten sind und die wenigsten Fäden entstanden."]
        case .flow:
            return ["Die Fluss-Treppe drucken: Jede Stufe hat einen etwas anderen Fluss.",
                    "Die Oberseite jeder Stufe ansehen und mit dem Fingernagel darüberfahren.",
                    "Die Stufe wählen, deren Oberfläche geschlossen und glatt ist – ohne Lücken und ohne Wülste."]
        case .pressureAdvance:
            return ["Den Turm drucken: Alle 2 mm Höhe steigt der Pressure-Advance-Wert.",
                    "Die Ecken des Turms von der Seite ansehen.",
                    "Die Höhe wählen, auf der die Ecken am schärfsten sind – nicht rund, nicht ausgebeult."]
        case .retraction:
            return ["Den Turm drucken: Mit jeder Stufe wächst der Rückzug.",
                    "Den Raum zwischen den beiden Säulen ansehen: Fäden.",
                    "Den kleinsten Rückzug wählen, bei dem (fast) keine Fäden mehr entstehen."]
        case .maxFlow:
            return ["Den Turm drucken: Die Geschwindigkeit steigt alle 3 mm Höhe.",
                    "Die Wand von der Seite und im Licht ansehen.",
                    "Die letzte Stufe wählen, bei der die Wand noch gleichmäßig und glänzend ist. Die App nimmt 15 % Sicherheitsabstand."]
        }
    }

    /// How to read the result: what you see, what it means, what to do.
    public var observations: [(sees: String, meaning: String, action: String)] {
        switch self {
        case .temperature:
            return [("Feine Fäden zwischen den Säulen", "zu heiß – das Filament ist zu flüssig", "niedrigere Stufe wählen"),
                    ("Brücken hängen durch, Überhänge kräuseln", "zu heiß oder zu wenig Kühlung", "niedrigere Stufe wählen"),
                    ("Raue, matte Oberfläche, Schichten lösen sich", "zu kalt – Schichten verbinden sich schlecht", "höhere Stufe wählen"),
                    ("Wand wirkt gleichmäßig, wenig Fäden, saubere Brücken", "passende Temperatur", "diese Stufe speichern")]
        case .flow:
            return [("Lücken oder feine Rillen in der Oberseite", "zu wenig Fluss (Unterextrusion)", "Stufe mit mehr Fluss wählen"),
                    ("Wülste, Kanten wirken aufgequollen, Ränder rau", "zu viel Fluss (Überextrusion)", "Stufe mit weniger Fluss wählen"),
                    ("Oberseite glatt und geschlossen", "passender Fluss", "diese Stufe speichern")]
        case .pressureAdvance:
            return [("Ecken sind rund, innen bleibt eine Lücke", "Wert zu niedrig", "höhere Stufe wählen"),
                    ("Ecken haben Beulen, nach der Ecke wird die Linie dünn", "Wert zu hoch", "niedrigere Stufe wählen"),
                    ("Ecken scharf, Linien gleichmäßig breit", "passender Wert", "diese Stufe speichern")]
        case .retraction:
            return [("Viele Fäden zwischen den Säulen", "Rückzug zu klein", "höhere Stufe wählen"),
                    ("Lücken oder dünne Stellen nach der Leerfahrt", "Rückzug zu groß", "niedrigere Stufe wählen"),
                    ("Kaum Fäden, saubere Säulen", "passender Rückzug", "kleinste saubere Stufe speichern")]
        case .maxFlow:
            return [("Wand dünn, rau oder mit Rillen, Klackern im Extruder", "Düse schafft die Menge nicht", "Stufe darunter wählen"),
                    ("Wand gleichmäßig und glänzend", "Fluss reicht", "höchste saubere Stufe wählen")]
        }
    }
}
