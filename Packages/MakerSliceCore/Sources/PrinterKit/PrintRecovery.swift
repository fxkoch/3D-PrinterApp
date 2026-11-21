import Foundation

/// Advice for a paused or failed print: continue, or throw the part away and start again.
public struct PrintRecovery: Equatable, Sendable {
    public enum Verdict: String, Sendable {
        /// Fix the cause, then resume.
        case resume
        /// Resuming is possible but risky; look at the part first.
        case checkFirst
        /// Cancel: the part is unlikely to turn out well, or little is lost.
        case discard
    }

    public var verdict: Verdict
    public var title: String
    public var reasons: [String]
    /// What to do before pressing "Fortsetzen", in order.
    public var steps: [String]

    /// What the pause message says went wrong.
    enum Cause {
        case filamentOut, clog, heater, adhesion, power, userPause, unknown
        /// The extruder pushes against resistance and grinds the filament (multiACE "Widerstand … zermahlen").
        case grinding
    }

    static func cause(of message: String?) -> Cause {
        let m = (message ?? "").lowercased()
        func has(_ words: [String]) -> Bool { words.contains { m.contains($0) } }
        if has(["runaway", "heater", "mintemp", "maxtemp", "thermistor", "temperature", "temperatur", "heizer"]) { return .heater }
        // Before "filament": these messages name the filament too, but it is still there – it cannot be pushed.
        if has(["zermahl", "widerstand", "resistance", "grinding", "unterextrusion", "under-extrusion", "underextrusion", "coil-delta"]) { return .grinding }
        if has(["runout", "run out", "out of filament", "no filament", "filament sensor", "filament", "material", "feed", "ausgegangen", "leer", "retract", "rückgang", "rueckgang", "abnormal", "slip"]) { return .filamentOut }
        if has(["clog", "jam", "extru", "blocked", "verstopf", "grind", "skip"]) { return .clog }
        if has(["detach", "adhesion", "spaghetti", "first layer", "lift", "warp", "haftung", "gelöst"]) { return .adhesion }
        if has(["power", "strom", "outage"]) { return .power }
        if has(["user", "benutzer", "pause"]) { return .userPause }
        return .unknown
    }

    /// Advice for the current status; nil when nothing is paused or failed.
    public static func advice(for s: PrinterStatus) -> PrintRecovery? {
        // A failed job of a printer that is idle again is history, not something to resume or cancel.
        guard s.state == .paused || s.state == .error, !s.isIdle else { return nil }
        let percent = Int((s.progress * 100).rounded())
        let layerText = s.currentLayer.flatMap { l in s.totalLayers.map { "Schicht \(l) von \($0)" } }
        let cause = Self.cause(of: s.stateMessage)
        // Heaters switched off while paused: the part is cooling down (the printer times out after a while).
        let heatersOff = (s.tools.allSatisfy { $0.target <= 0 }) && s.bed.target <= 0 && !s.tools.isEmpty
        let nozzleCold = heatersOff && (s.tools.map(\.temperature).max() ?? 0) < 60
        var reasons: [String] = []
        if let layerText { reasons.append("Der Druck steht bei \(layerText) (\(percent) %).") } else { reasons.append("Der Druck steht bei \(percent) %.") }
        if let message = s.stateMessage { reasons.append("Meldung des Druckers: „\(message)“") }
        // A speed factor far above 100 % (left by a calibration's speed steps) makes the extruder grind the filament.
        let tooFast = (s.speedPercent ?? 100) > 150
        let speedStep = "Tempo steht auf \(Int(s.speedPercent ?? 100)) %: zuerst auf 100 % stellen (Live-Ansicht → Tempo)."
        if tooFast { reasons.append("Der Drucker läuft mit \(Int(s.speedPercent ?? 100)) % Tempo. So schnell kann kein Extruder fördern.") }

        func result(_ verdict: Verdict, _ title: String, steps: [String]) -> PrintRecovery {
            PrintRecovery(verdict: verdict, title: title, reasons: reasons, steps: tooFast && !steps.contains(speedStep) ? [speedStep] + steps : steps)
        }

        // Safety first: heater faults are never resumed blindly.
        if cause == .heater {
            reasons.append("Ein Heizungsfehler kann ein Sicherheitsproblem sein.")
            return result(.discard, "Abbrechen und Heizung prüfen",
                          steps: ["Drucker ausschalten und abkühlen lassen.", "Temperatursensor und Stecker an Düse und Bett prüfen.", "Erst nach dem Test neu starten."])
        }
        if cause == .adhesion {
            reasons.append("Ein vom Bett gelöstes Teil wird beim Weiterdrucken nicht besser.")
            return result(.discard, "Verwerfen und neu drucken",
                          steps: ["Abbrechen, Bett reinigen (Isopropanol).", "Neu starten, ggf. mit Brim oder anderer Druckplatte."])
        }
        if nozzleCold, s.progress > 0.02 {
            reasons.append("Düse und Bett sind schon kalt: das Teil ist abgekühlt, die nächste Schicht haftet schlecht.")
            if s.progress >= 0.85 {
                return result(.checkFirst, "Teil prüfen, dann entscheiden",
                              steps: ["Ist das Teil noch fest auf dem Bett und unverzogen?", "Wenn ja: Bett und Düse aufheizen, dann Fortsetzen – eine sichtbare Naht bleibt.", "Sonst abbrechen; bei \(percent) % ist das Teil eventuell schon brauchbar."])
            }
            return result(.discard, "Besser neu drucken", steps: ["Abbrechen und das Teil neu starten – ein kaltes Teil hält an der Naht meist nicht."])
        }
        if s.progress < 0.05 {
            reasons.append("Erst wenig gedruckt – Neustart kostet kaum Zeit und Filament.")
            return result(.discard, "Abbrechen und neu starten", steps: ["Ursache beheben (Filament, Düse, Haftung).", "Druck neu starten."])
        }
        switch cause {
        case .grinding:
            reasons.append("Das Filament ist noch da, kommt aber nicht durch: Die Stelle ist zu dünn gedruckt. Weiterdrucken geht, wenn die Ursache behoben ist.")
            return result(.checkFirst, "Ursache beheben, Teil prüfen",
                          steps: ["Spule prüfen: läuft sie frei, kein Knoten, nichts verklemmt im ACE.",
                                  "Schlauch zum Druckkopf auf Knicke prüfen.",
                                  "Düse prüfen: kommt beim Extrudieren ein gleichmäßiger Faden? Sonst Kaltzug (Cold Pull).",
                                  "Fehlen mehrere Schichten am Teil, lieber abbrechen. Sonst „Fortsetzen“; die dünne Stelle bleibt sichtbar."])
        case .filamentOut:
            let retract = ["retract", "rückgang", "rueckgang", "abnormal", "slip"].contains { (s.stateMessage ?? "").lowercased().contains($0) }
            reasons.append(retract
                ? "Das Filament wurde unerwartet zurückgezogen oder rutscht – meist ein verheddertes oder klemmendes Filament, ein geknickter Schlauch oder ein zu glattes Filamentende. Das lässt sich beheben, das Teil bleibt warm und fest."
                : "Filament leer oder nicht nachgeführt: lässt sich beheben, das Teil bleibt warm und fest.")
            return result(.resume, "Fortsetzen ist sinnvoll",
                          steps: ["Neues Filament desselben Typs einlegen (am ACE/Wechsler den Slot prüfen).", "Prüfen, dass es bis zur Düse läuft und sauber extrudiert.", "Dann „Fortsetzen“."])
        case .clog:
            if s.progress > 0.6 {
                reasons.append("Schon weit fortgeschritten, ein Düsenproblem lässt sich oft beheben.")
                return result(.checkFirst, "Düse reinigen, Teil prüfen",
                              steps: ["Abgesetzte Lücken im Teil ansehen: fehlen mehrere Schichten, abbrechen.", "Düse reinigen (Cold Pull) oder wechseln.", "Dann „Fortsetzen“; Fehlstelle bleibt sichtbar."])
            }
            reasons.append("Bei verstopfter Düse fehlen meist schon Schichten – das Teil ist geschwächt.")
            return result(.discard, "Düse reparieren, dann neu drucken",
                          steps: ["Abbrechen.", "Düse reinigen (Cold Pull) oder wechseln.", "Druck neu starten."])
        case .power:
            return result(.checkFirst, "Teil prüfen, dann entscheiden",
                          steps: ["Teil auf dem Bett prüfen (fest, nicht verschoben).", "Aufheizen lassen und Fortsetzen nur, wenn alles sitzt."])
        case .userPause, .unknown:
            if s.state == .error {
                reasons.append("Die Ursache ist nicht eindeutig.")
                return result(.checkFirst, "Erst Ursache klären",
                              steps: ["Am Drucker die Fehlermeldung lesen.", "Teil und Filament prüfen.", "Nur fortsetzen, wenn der Fehler behoben ist."])
            }
            return result(.resume, "Fortsetzen ist unkritisch",
                          steps: ["Bei einer kurzen Pause reicht „Fortsetzen“.", "Bei langer Pause vorher Düse aufheizen und Tropfen entfernen."])
        default:
            return nil
        }
    }
}
