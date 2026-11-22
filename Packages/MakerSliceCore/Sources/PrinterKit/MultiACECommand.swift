import Foundation

/// G-code of the multiACE add-on (github.com/decay71/multiACE) for the Anycubic ACE Pro 2 on a Snapmaker U1.
public enum MultiACECommand {
    /// Loads tool head `head` (0...3) from the ACE slot assigned to it.
    public static func load(head: Int) -> String { "ACE_LOAD_HEAD HEAD=\(head)" }

    /// Pulls the filament of tool head `head` back into the ACE.
    public static func unload(head: Int) -> String { "ACE_UNLOAD_HEAD HEAD=\(head)" }

    /// Starts the dryer of ACE `unit` (0-based). `ACE_START_DRYING` would dry the active unit, whichever that is;
    /// `ACE_DRY` switches to the unit first. multiACE takes the duration in minutes.
    public static func startDrying(unit: Int, temperature: Int, minutes: Int) -> String {
        "ACE_DRY ACE=\(unit) TEMP=\(temperature) DURATION=\(minutes)"
    }

    /// Highest dryer temperature of a unit: ACE Pro 55 °C, ACE 2 Pro 65 °C (multiACE `kind`/`protocol` v1 / v2).
    public static func maxDryingTemperature(kind: String?) -> Int {
        switch (kind ?? "").lowercased() {
        case "v2", "ace2k": return 65
        default: return 55
        }
    }

    public static func stopDrying(unit: Int) -> String { "ACE_STOP_DRYING ACE=\(unit)" }
}
