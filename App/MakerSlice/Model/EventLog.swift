import Foundation
import Observation
import PrinterKit

/// App-wide log of printer and app events (connection problems, errors, uploads).
@MainActor
@Observable
final class EventLog {
    private(set) var entries: [PrinterEvent] = []
    private let url: URL
    private let limit = 500

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = docs.appendingPathComponent("eventlog.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([PrinterEvent].self, from: data) {
            entries = saved
        }
    }

    var errorCount: Int { entries.filter { $0.level == .error }.count }

    func add(_ level: PrinterEvent.Level, _ message: String, source: String) {
        // Avoid flooding the log with the same message while polling.
        if let last = entries.first, last.message == message, last.source == source,
           Date().timeIntervalSince(last.date) < 60 {
            return
        }
        entries.insert(PrinterEvent(level: level, message: message, source: source), at: 0)
        trimAndSave()
    }

    /// Merges events reported by a printer (deduplicated by time and text).
    func merge(_ events: [PrinterEvent]) {
        var known = Set(entries.map { "\($0.source)|\($0.message)|\(Int($0.date.timeIntervalSince1970))" })
        var added = false
        for e in events {
            let key = "\(e.source)|\(e.message)|\(Int(e.date.timeIntervalSince1970))"
            if known.insert(key).inserted {
                entries.append(e)
                added = true
            }
        }
        if added {
            entries.sort { $0.date > $1.date }
            trimAndSave()
        }
    }

    func clear() {
        entries.removeAll()
        trimAndSave()
    }

    func exportText() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return entries.map { "\(f.string(from: $0.date)) [\($0.level.rawValue.uppercased())] \($0.source): \($0.message)" }
            .joined(separator: "\n")
    }

    private func trimAndSave() {
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
    }
}
