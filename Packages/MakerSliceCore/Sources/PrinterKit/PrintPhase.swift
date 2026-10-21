import Foundation

/// Which step of a print the printer is in – for the live view.
public struct PrintPhase: Equatable, Sendable {
    public enum Step: Int, CaseIterable, Sendable {
        case preparing, heating, printing, finishing, done

        public var title: String {
            switch self {
            case .preparing: return "Vorbereiten"
            case .heating: return "Aufheizen"
            case .printing: return "Drucken"
            case .finishing: return "Abschluss"
            case .done: return "Fertig"
            }
        }
    }

    /// The step in the progress bar, nil when no print is running.
    public var step: Step?
    public var title: String
    public var detail: String?
}

extension PrinterStatus {
    /// Current step of the print, worked out from temperatures, layer and progress.
    public var phase: PrintPhase {
        func temp(_ h: Heater) -> String { "\(Int(h.temperature.rounded()))/\(Int(h.target.rounded())) °C" }
        let activeHeater: Heater? = activeTool.flatMap { tools.indices.contains($0) ? tools[$0] : nil }
            ?? tools.max { $0.target < $1.target }
        switch state {
        case .standby: return PrintPhase(step: nil, title: "Bereit", detail: nil)
        case .unknown: return PrintPhase(step: nil, title: "Status unbekannt", detail: nil)
        case .complete: return PrintPhase(step: .done, title: "Druck fertig", detail: fileName)
        case .cancelled: return PrintPhase(step: nil, title: "Abgebrochen", detail: stateMessage)
        case .error: return PrintPhase(step: nil, title: "Fehler", detail: stateMessage)
        case .paused:
            let layerText = currentLayer.flatMap { l in totalLayers.map { "bei Schicht \(l) von \($0)" } }
            return PrintPhase(step: .printing, title: "Pausiert", detail: layerText)
        case .printing:
            let nozzleHeating = activeHeater.map { $0.target > 0 && $0.temperature < $0.target - 5 } ?? false
            let bedHeating = bed.target > 0 && bed.temperature < bed.target - 3
            let started = (currentLayer ?? 0) > 0 || progress > 0.003
            if (nozzleHeating || bedHeating) && !started {
                var parts: [String] = []
                if bed.target > 0 { parts.append("Bett \(temp(bed))") }
                if let h = activeHeater, h.target > 0 { parts.append("Düse \(temp(h))") }
                return PrintPhase(step: .heating, title: "Heizt auf", detail: parts.joined(separator: " · "))
            }
            if !started {
                return PrintPhase(step: .preparing, title: "Bereitet vor", detail: "Kalibrieren, Leveln und erste Linien")
            }
            if progress >= 0.995 { return PrintPhase(step: .finishing, title: "Schließt den Druck ab", detail: nil) }
            var title = "Druckt"
            if let l = currentLayer, let t = totalLayers, t > 0 { title = "Druckt Schicht \(l) von \(t)" }
            return PrintPhase(step: .printing, title: title, detail: "\(Int((progress * 100).rounded())) %")
        }
    }
}
