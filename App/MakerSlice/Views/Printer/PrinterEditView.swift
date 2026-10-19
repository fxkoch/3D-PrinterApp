import PrinterKit
import SliceKit
import SwiftUI

/// Add or edit a printer: model, connection type, address; with network discovery.
struct PrinterEditView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let existing: PrinterConnection?

    @State private var model: PrinterModel = .snapmakerU1
    @State private var kind: ConnectionKind = .moonraker
    @State private var name = ""
    @State private var host = ""
    @State private var apiKey = ""
    @State private var testing = false
    @State private var testResult: String?
    @StateObject private var discovery = PrinterDiscovery()

    var body: some View {
        NavigationStack {
            Form {
                Section("Drucker") {
                    Picker("Modell", selection: $model) {
                        ForEach(PrinterModel.allCases) { Text($0.displayName).tag($0) }
                    }
                    .onChange(of: model) { _, new in
                        kind = new == .kobraS1 ? .anycubicLAN : .moonraker
                        if name.isEmpty || PrinterModel.allCases.map(\.displayName).contains(name) { name = new.displayName }
                    }
                    if model == .kobraS1 {
                        Picker("Verbindung", selection: $kind) {
                            Text("LAN-Modus (Original-Firmware)").tag(ConnectionKind.anycubicLAN)
                            Text("Rinkhals / Moonraker").tag(ConnectionKind.moonraker)
                        }
                    }
                    TextField("Name", text: $name)
                }

                if kind == .moonraker {
                    Section("Im WLAN gefunden") {
                        if discovery.printers.isEmpty {
                            HStack { ProgressView(); Text("Suche …").foregroundStyle(.secondary) }
                        }
                        ForEach(discovery.printers) { found in
                            Button {
                                host = found.host
                                if name.isEmpty { name = found.name }
                            } label: {
                                HStack {
                                    Image(systemName: "printer")
                                    VStack(alignment: .leading) {
                                        Text(found.name)
                                        Text(found.host).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if host == found.host { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }

                Section {
                    TextField("IP-Adresse, z. B. 192.168.1.50", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("printerHost")
                    if kind == .moonraker {
                        SecureField("API-Schlüssel (optional)", text: $apiKey)
                    }
                } header: {
                    Text("Adresse")
                } footer: {
                    Text(footer)
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Verbindung testen")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(host.isEmpty || testing)
                    if let testResult { Text(testResult).font(.callout) }
                }

                if let existing {
                    Section {
                        Button("Drucker entfernen", role: .destructive) {
                            app.printers.remove(existing)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Drucker hinzufügen" : "Drucker bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { save() }
                        .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("savePrinter")
                }
            }
            .onAppear {
                if let existing {
                    model = PrinterModel(rawValue: existing.model) ?? .snapmakerU1
                    kind = existing.kind
                    name = existing.name
                    host = existing.host
                    apiKey = existing.apiKey ?? ""
                } else {
                    name = model.displayName
                }
                discovery.start()
            }
            .onDisappear { discovery.stop() }
        }
    }

    private var footer: String {
        switch (model, kind) {
        case (.kobraS1, .anycubicLAN):
            return "Am Kobra S1 unter Einstellungen → Netzwerk den LAN-Modus einschalten. Die IP steht im selben Menü. Hinweis: Im LAN-Modus ist die Anycubic-Cloud-App getrennt."
        case (.kobraS1, .moonraker):
            return "Für Kobra S1 mit der Community-Firmware Rinkhals (Moonraker auf Port 7125)."
        default:
            return "Die IP findest du am U1 unter Einstellungen → WLAN. Port 7125 wird automatisch verwendet."
        }
    }

    private var connection: PrinterConnection {
        PrinterConnection(id: existing?.id ?? UUID(), name: name.isEmpty ? model.displayName : name,
                          host: host.trimmingCharacters(in: .whitespaces), apiKey: apiKey.isEmpty ? nil : apiKey,
                          model: model.rawValue, kind: kind)
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let driver = PrinterDrivers.make(for: connection)
        defer { driver.disconnect() }
        do {
            let status = try await driver.status()
            var text = "✅ Verbunden – Status: \(status.state.displayName)"
            if let fw = status.firmware { text += ", Firmware \(fw)" }
            testResult = text
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }

    private func save() {
        if existing != nil {
            app.printers.update(connection)
        } else {
            app.printers.add(connection)
        }
        dismiss()
    }
}
