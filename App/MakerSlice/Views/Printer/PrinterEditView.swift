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
    @State private var serial = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var scan = PrinterScan()

    var body: some View {
        NavigationStack {
            Form {
                Section("Drucker") {
                    Picker("Modell", selection: $model) {
                        ForEach(PrinterModel.allCases) { Text($0.displayName).tag($0) }
                    }
                    .onChange(of: model) { _, new in
                        kind = new == .kobraS1 ? .anycubicLAN : (new == .bambuP1S ? .bambuLAN : .moonraker)
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

                Section {
                    if scan.scanning {
                        HStack {
                            ProgressView()
                            Text("Suche im WLAN … \(Int(scan.progress * 100)) %").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(scan.found) { printer in
                        Button { choose(printer) } label: {
                            HStack {
                                Image(systemName: "printer")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(printer.name)
                                    Text("\(printer.host) · \(printer.kind.displayName)").font(.caption).foregroundStyle(.secondary)
                                    if let note = printer.note { Text(note).font(.caption).foregroundStyle(.orange) }
                                }
                                Spacer()
                                if host == printer.host { Image(systemName: "checkmark") }
                            }
                        }
                        .accessibilityIdentifier("found-\(printer.host)")
                    }
                    if !scan.scanning {
                        if scan.found.isEmpty {
                            Text("Kein Drucker gefunden. Ist er eingeschaltet, im selben WLAN – und beim Kobra S1 der LAN-Modus an?")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button { scan.start() } label: { Label("Erneut suchen", systemImage: "arrow.clockwise") }
                            .accessibilityIdentifier("scanAgain")
                    }
                } header: {
                    Text("Im WLAN gefunden")
                } footer: {
                    Text("Die Suche fragt alle Adressen deines Heimnetzes ab – ganz ohne IP-Eingabe.")
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
                    if kind == .bambuLAN {
                        TextField("Seriennummer (Typenschild)", text: $serial)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("printerSerial")
                        SecureField("Zugangscode (Drucker-Display)", text: $apiKey)
                            .accessibilityIdentifier("printerAccessCode")
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
                    serial = existing.serial ?? ""
                } else {
                    scan.start()
                    name = model.displayName
                }
            }
            .onDisappear { scan.stop() }
        }
    }

    private var footer: String {
        switch (model, kind) {
        case (.kobraS1, .anycubicLAN):
            return "Am Kobra S1 unter Einstellungen → Netzwerk den LAN-Modus einschalten. Die IP steht im selben Menü. Hinweis: Im LAN-Modus ist die Anycubic-Cloud-App getrennt."
        case (.kobraS1, .moonraker):
            return "Für Kobra S1 mit der Community-Firmware Rinkhals (Moonraker auf Port 7125)."
        case (.bambuP1S, _):
            return "Am P1S unter Einstellungen → WLAN den LAN-Modus einschalten. Dort stehen IP-Adresse und Zugangscode; die Seriennummer steht auf dem Typenschild. Für den Druck muss eine microSD-Karte im Drucker stecken."
        default:
            return "Die IP findest du am U1 unter Einstellungen → WLAN. Port 7125 wird automatisch verwendet."
        }
    }

    private var connection: PrinterConnection {
        PrinterConnection(id: existing?.id ?? UUID(), name: name.isEmpty ? model.displayName : name,
                          host: host.trimmingCharacters(in: .whitespaces), apiKey: apiKey.isEmpty ? nil : apiKey,
                          model: model.rawValue, kind: kind, serial: serial.trimmingCharacters(in: .whitespaces).isEmpty ? nil : serial.trimmingCharacters(in: .whitespaces))
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

    /// Takes over a printer found on the network: model, connection type, address and name.
    private func choose(_ printer: DiscoveredPrinter) {
        let newModel: PrinterModel = printer.looksLikeBambu ? .bambuP1S : (printer.looksLikeKobraS1 || printer.modelText.lowercased().contains("kobra") ? .kobraS1 : .snapmakerU1)
        model = newModel
        host = printer.host
        if name.isEmpty || PrinterModel.allCases.map(\.displayName).contains(name) { name = printer.name }
        // `model` resets the connection type in onChange; set the detected one afterwards.
        Task { @MainActor in kind = printer.kind }
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
