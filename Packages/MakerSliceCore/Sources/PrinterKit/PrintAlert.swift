import Foundation

/// What is worth a notification when a printer's state changes (pure logic; the app turns it into a notification).
public struct PrintAlert: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case finished, failed, paused, filament, cancelled
    }

    public var kind: Kind
    public var title: String
    public var body: String
    /// Same key = same event (no second notification for it).
    public var key: String

    /// `old` is the last state seen before (nil = unknown, then nothing is reported: no alert for something that happened before).
    public static func alert(printer: String, old: PrinterStatus.JobState?, new: PrinterStatus) -> PrintAlert? {
        guard let old, old != new.state else { return nil }
        let file = new.fileName.map { " „\($0)“" } ?? ""
        let wasRunning = old == .printing || old == .paused
        func make(_ kind: Kind, _ title: String, _ body: String) -> PrintAlert {
            PrintAlert(kind: kind, title: title, body: body, key: "\(printer)|\(kind.rawValue)|\(new.fileName ?? "")|\(new.currentLayer ?? 0)")
        }
        let message = new.stateMessage
        switch new.state {
        case .complete where wasRunning || old == .unknown:
            return make(.finished, "\(printer): Druck fertig", "Der Druck\(file) ist fertig. Teil entnehmen, sobald das Bett abgekühlt ist.")
        case .error:
            if FilamentCheck.isFilamentMessage(message) {
                return make(.filament, "\(printer): Filamentproblem", (message ?? "Filament prüfen.") + " Tippe, um das Filament zu prüfen.")
            }
            return make(.failed, "\(printer): Druckfehler", message ?? "Der Drucker meldet einen Fehler.")
        case .paused where old == .printing:
            if FilamentCheck.isFilamentMessage(message) {
                return make(.filament, "\(printer): Filamentproblem", (message ?? "Filament prüfen.") + " Der Druck wurde angehalten.")
            }
            return make(.paused, "\(printer): Druck pausiert", message ?? "Der Druck\(file) wurde angehalten.")
        case .cancelled where wasRunning:
            return make(.cancelled, "\(printer): Druck abgebrochen", "Der Druck\(file) wurde abgebrochen.")
        default:
            return nil
        }
    }
}
