import Foundation

/// G-code of the multiACE add-on (github.com/decay71/multiACE) for the Anycubic ACE Pro 2 on a Snapmaker U1.
public enum MultiACECommand {
    /// Loads tool head `head` (0...3) from the ACE slot assigned to it.
    public static func load(head: Int) -> String { "ACE_LOAD_HEAD HEAD=\(head)" }

    /// Pulls the filament of tool head `head` back into the ACE.
    public static func unload(head: Int) -> String { "ACE_UNLOAD_HEAD HEAD=\(head)" }

    /// Starts the dryer; multiACE takes the duration in minutes.
    public static func startDrying(unit: Int, temperature: Int, minutes: Int) -> String {
        "ACE_START_DRYING TEMP=\(temperature) DURATION=\(minutes)"
    }

    public static func stopDrying(unit: Int) -> String { "ACE_STOP_DRYING ACE=\(unit)" }
}
