import PrinterKit
import SwiftUI

/// Log of printer and app events with error filter and export.
struct LogView: View {
    @Environment(AppModel.self) private var app
    var source: String?
    @State private var errorsOnly = false

    private var entries: [PrinterEvent] {
        app.log.entries.filter { e in
            (source == nil || e.source.hasPrefix(source!)) && (!errorsOnly || e.level != .info)
        }
    }

    var body: some View {
        List {
            Section {
                Toggle("Nur Warnungen & Fehler", isOn: $errorsOnly)
            }
            if entries.isEmpty {
                Text("Keine Einträge.").foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(entry.level))
                        .foregroundStyle(color(entry.level))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.message).font(.callout)
                        HStack {
                            Text(entry.source)
                            Spacer()
                            Text(entry.date, format: .dateTime.day().month().hour().minute().second())
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Protokoll")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: app.log.exportText()) { Image(systemName: "square.and.arrow.up") }
                Button(role: .destructive) { app.log.clear() } label: { Image(systemName: "trash") }
            }
        }
    }

    private func icon(_ level: PrinterEvent.Level) -> String {
        switch level {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private func color(_ level: PrinterEvent.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}
