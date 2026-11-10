import Foundation

/// A stored calibration result for one printer and filament.
public struct CalibrationResult: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(printer)|\(filament)|\(kind.rawValue)" }
    /// `PrinterModel` raw value.
    public var printer: String
    /// Filament profile name, e.g. "Generic PETG".
    public var filament: String
    public var kind: CalibrationKind
    public var value: Double
    public var date: Date

    public init(printer: String, filament: String, kind: CalibrationKind, value: Double, date: Date = Date()) {
        self.printer = printer
        self.filament = filament
        self.kind = kind
        self.value = value
        self.date = date
    }
}

/// All calibration results. Filament profiles loaded from the library carry them automatically, so every later print
/// of that filament on that printer uses the calibrated values.
public final class CalibrationBook: @unchecked Sendable {
    public static let shared = CalibrationBook()

    private let lock = NSLock()
    private var results: [String: CalibrationResult] = [:]
    /// Called after every change (the app saves the book there).
    public var onChange: (([CalibrationResult]) -> Void)?

    public init() {}

    public var all: [CalibrationResult] {
        lock.lock(); defer { lock.unlock() }
        return results.values.sorted { $0.date > $1.date }
    }

    public func results(printer: PrinterModel, filament: String) -> [CalibrationResult] {
        all.filter { $0.printer == printer.rawValue && $0.filament == filament }
    }

    public func result(_ kind: CalibrationKind, printer: PrinterModel, filament: String) -> CalibrationResult? {
        results(printer: printer, filament: filament).first { $0.kind == kind }
    }

    public func set(_ result: CalibrationResult) {
        lock.lock()
        results[result.id] = result
        lock.unlock()
        onChange?(all)
    }

    public func remove(_ result: CalibrationResult) {
        lock.lock()
        results[result.id] = nil
        lock.unlock()
        onChange?(all)
    }

    /// Replaces the book with saved results (at app start).
    public func load(_ saved: [CalibrationResult]) {
        lock.lock()
        results = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.date >= b.date ? a : b })
        lock.unlock()
    }

    /// Merges results from another place (e.g. the printer's database); the newer one wins. Returns how many changed.
    @discardableResult
    public func merge(_ other: [CalibrationResult]) -> Int {
        var changed = 0
        lock.lock()
        for r in other where (results[r.id]?.date ?? .distantPast) < r.date {
            results[r.id] = r
            changed += 1
        }
        lock.unlock()
        if changed > 0 { onChange?(all) }
        return changed
    }

    /// The filament with this printer's calibrated values.
    public func apply(to filament: Filament, printer: PrinterModel) -> Filament {
        let mine = results(printer: printer, filament: filament.name)
        guard !mine.isEmpty else { return filament }
        var f = filament
        for r in mine {
            switch r.kind {
            case .temperature:
                let delta = f.firstLayerNozzleTemp - f.nozzleTemp
                f.nozzleTemp = Int(r.value.rounded())
                f.firstLayerNozzleTemp = f.nozzleTemp + max(delta, 0)
            case .flow: f.flowRatio = r.value
            case .pressureAdvance: f.pressureAdvance = r.value > 0 ? r.value : nil
            case .retraction: f.retractLength = r.value
            case .maxFlow: f.maxVolumetricSpeed = r.value
            }
        }
        f.calibratedKinds = mine.map { $0.kind.rawValue }.sorted()
        return f
    }

    // MARK: Coding for the printer's database

    public static func encode(_ results: [CalibrationResult]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(results)
    }

    public static func decode(_ data: Data) -> [CalibrationResult] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CalibrationResult].self, from: data)) ?? []
    }
}
