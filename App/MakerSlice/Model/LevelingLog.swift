import Foundation
import SliceKit

/// When the bed was last levelled for a print (per printer model and plate), for the "skip leveling" hint.
enum LevelingLog {
    private static let key = "levelingLog"

    static func record(printer: PrinterModel, plate: PlateType, at date: Date = Date()) {
        var log = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Any]] ?? [:]
        log[printer.rawValue] = ["time": date.timeIntervalSince1970, "plate": plate.rawValue]
        UserDefaults.standard.set(log, forKey: key)
    }

    /// Hours since the last levelling with this plate; nil if never, or the plate changed since.
    static func hoursSince(printer: PrinterModel, plate: PlateType, now: Date = Date()) -> Double? {
        guard let entry = (UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Any]])?[printer.rawValue],
              let time = entry["time"] as? Double, (entry["plate"] as? String) == plate.rawValue else { return nil }
        return max(0, now.timeIntervalSince1970 - time) / 3600
    }
}
