import Foundation

/// What to do next with the calibration prints: after a test with no good step, and which tests are still open.
public struct CalibrationAdviceItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    /// Calibration to start for this step, if there is one.
    public var run: CalibrationKind?
}

public enum CalibrationAdvice {
    /// The order in which the tests build on each other.
    public static let order: [CalibrationKind] = [.temperature, .retraction, .pressureAdvance, .flow, .maxFlow]

    /// Tests without a saved result for this printer and filament, in a sensible order.
    public static func open(printer: PrinterModel, filament: String, book: CalibrationBook = .shared) -> [CalibrationKind] {
        order.filter { book.result($0, printer: printer, filament: filament) == nil }
    }

    /// The test print showed nothing good: the usual causes in the order worth checking.
    public static func whenNoStepIsGood(_ kind: CalibrationKind, filamentType: String) -> [CalibrationAdviceItem] {
        let wet = ["PETG", "TPU", "PA", "PC", "PVA", "PLA"].contains { filamentType.uppercased().hasPrefix($0) }
        var items: [CalibrationAdviceItem] = []
        switch kind {
        case .temperature:
            if wet {
                items.append(.init(id: "dry", title: "Filament trocknen", detail: "Fäden und Blasen über den ganzen Turm sind meist Feuchtigkeit, nicht die Temperatur. \(filamentType) zieht Wasser – trocknen (im ACE oder Ofen), dann den Turm wiederholen.", run: nil))
            }
            items.append(.init(id: "retraction", title: "Rückzug testen", detail: "Fäden zwischen den Stegen verhindert vor allem der Rückzug. Der Test zeigt, welche Länge bei diesem Filament genügt.", run: .retraction))
            items.append(.init(id: "again", title: "Turm danach wiederholen", detail: "Mit trockenem Filament und passendem Rückzug neu drucken. Erst dann lässt sich die Temperatur beurteilen.", run: .temperature))
        case .retraction:
            items.append(.init(id: "dry", title: "Filament trocknen", detail: "Feuchtes Filament fädelt auch mit gutem Rückzug.", run: nil))
            items.append(.init(id: "temp", title: "Temperatur senken", detail: "10 °C kühler drucken (Temperaturturm), dann den Rückzug-Test wiederholen.", run: .temperature))
        case .flow:
            items.append(.init(id: "pa", title: "Pressure Advance testen", detail: "Wellige oder ungleiche Linien kommen oft vom Druckaufbau in der Düse, nicht vom Fluss.", run: .pressureAdvance))
            items.append(.init(id: "dry", title: "Filament trocknen", detail: "Feuchtes Filament fließt ungleichmäßig.", run: nil))
        case .pressureAdvance:
            items.append(.init(id: "dry", title: "Filament trocknen", detail: "Feuchtes Filament verfälscht die Ecken.", run: nil))
            items.append(.init(id: "flow", title: "Fluss testen", detail: "Ein falscher Fluss lässt Ecken ebenfalls schlecht aussehen.", run: .flow))
        case .maxFlow:
            items.append(.init(id: "temp", title: "Temperatur prüfen", detail: "Zu kühl schmilzt das Filament nicht schnell genug – Temperaturturm.", run: .temperature))
        }
        return items
    }
}
