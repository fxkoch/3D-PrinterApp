import PrinterKit
import SliceKit
import SwiftUI

struct PrintersView: View {
    @Environment(AppModel.self) private var app
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            Group {
                if app.printers.printers.isEmpty {
                    ContentUnavailableView {
                        Label("Kein Drucker", systemImage: "printer")
                    } description: {
                        Text("Füge deinen Snapmaker U1 oder Anycubic Kobra S1 hinzu. Der Drucker muss im selben WLAN sein.")
                    } actions: {
                        Button("Drucker hinzufügen") { showAdd = true }.buttonStyle(.borderedProminent)
                    }
                } else if app.printers.printers.count == 1, let only = app.printers.printers.first {
                    PrinterDetailView(printer: only)
                } else {
                    List {
                        ForEach(app.printers.printers) { printer in
                            NavigationLink {
                                PrinterDetailView(printer: printer)
                            } label: {
                                PrinterRow(printer: printer)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Drucker")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        LogView()
                    } label: {
                        Label("Protokoll", systemImage: app.log.errorCount > 0 ? "exclamationmark.bubble" : "list.bullet.rectangle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { PrinterEditView(existing: nil) }
            .refreshable { await app.printers.refreshAll() }
        }
        .onAppear { app.printers.startPolling() }
    }
}

private struct PrinterRow: View {
    @Environment(AppModel.self) private var app
    let printer: PrinterConnection

    var body: some View {
        let status = app.printers.status(of: printer)
        HStack(spacing: 12) {
            Image(systemName: "printer.fill").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(printer.name).font(.headline)
                Text(app.printers.model(of: printer).displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let status {
                VStack(alignment: .trailing, spacing: 2) {
                    StatusBadge(text: status.state.displayName, color: status.state.color)
                    if status.state == .printing {
                        Text("\(Int(status.progress * 100)) %").font(.caption.monospacedDigit())
                    }
                }
            } else {
                StatusBadge(text: "Offline", color: .secondary)
            }
        }
    }
}

extension PrinterStatus.JobState {
    var color: Color {
        switch self {
        case .printing: return .blue
        case .paused: return .orange
        case .complete: return .green
        case .error, .cancelled: return .red
        case .standby: return .secondary
        case .unknown: return .secondary
        }
    }
}
