import PrinterKit
import SliceKit
import SwiftUI

struct PrintersView: View {
    @Environment(AppModel.self) private var app
    @State private var showAdd = false

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.printerPath) {
            Group {
                if app.printers.printers.isEmpty {
                    ContentUnavailableView {
                        Label("Kein Drucker", systemImage: "printer")
                    } description: {
                        Text("Füge deinen Snapmaker U1, Anycubic Kobra S1 oder Bambu Lab P1S hinzu. Der Drucker muss im selben WLAN sein.")
                    } actions: {
                        Button("Drucker hinzufügen") { showAdd = true }.buttonStyle(.borderedProminent)
                    }
                } else if app.printers.printers.count == 1, let only = app.printers.printers.first {
                    PrinterDetailView(printer: only)
                } else {
                    List {
                        ForEach(app.printers.printers) { printer in
                            NavigationLink(value: printer.id) {
                                PrinterRow(printer: printer)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Drucker")
            .navigationDestination(for: UUID.self) { id in
                if let printer = app.printers.printers.first(where: { $0.id == id }) {
                    PrinterDetailView(printer: printer)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        LogView()
                    } label: {
                        Label("Protokoll", systemImage: app.log.unseenErrorCount > 0 ? "exclamationmark.bubble" : "list.bullet.rectangle")
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
            if let status, app.printers.isOnline(printer) {
                VStack(alignment: .trailing, spacing: 2) {
                    StatusBadge(text: status.state.displayName, color: status.state.color)
                    if app.printers.isRemote(printer) {
                        Label("unterwegs", systemImage: "globe").font(.caption2).foregroundStyle(.blue)
                    }
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
