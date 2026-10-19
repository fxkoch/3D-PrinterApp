import PrinterKit
import SwiftUI

struct PrinterView: View {
    @Environment(AppModel.self) private var app
    @State private var showAdd = false
    @State private var editing: PrinterConnection?
    @State private var confirmCancel = false

    private var manager: PrinterManager { app.printers }

    var body: some View {
        NavigationStack {
            Group {
                if let printer = manager.selected {
                    ScrollView {
                        VStack(spacing: 16) {
                            header(printer)
                            if let status = manager.status {
                                jobCard(status)
                                CameraView(client: manager.client, active: status.state == .printing || status.state == .paused)
                                toolsCard(status)
                                bedCard(status)
                            } else if let error = manager.lastError {
                                offlineCard(error)
                            } else {
                                ProgressView("Verbinde …").padding(.top, 40)
                            }
                        }
                        .padding()
                    }
                    .refreshable { await manager.refresh() }
                } else {
                    ContentUnavailableView {
                        Label("Kein Drucker", systemImage: "printer")
                    } description: {
                        Text("Füge deinen Snapmaker U1 hinzu. Er muss im selben WLAN sein.")
                    } actions: {
                        Button("Drucker hinzufügen") { showAdd = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Drucker")
            .toolbar {
                Menu {
                    ForEach(manager.printers) { p in
                        Button {
                            manager.selectedID = p.id
                            manager.restartPolling()
                        } label: {
                            if p.id == manager.selected?.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                        }
                    }
                    Divider()
                    Button { showAdd = true } label: { Label("Drucker hinzufügen", systemImage: "plus") }
                    if let p = manager.selected {
                        Button { editing = p } label: { Label("Bearbeiten", systemImage: "pencil") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .sheet(isPresented: $showAdd) { PrinterEditView(existing: nil) }
            .sheet(item: $editing) { PrinterEditView(existing: $0) }
            .confirmationDialog("Druck wirklich abbrechen?", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Druck abbrechen", role: .destructive) { Task { await manager.perform { try await $0.cancel() } } }
            }
        }
        .onAppear { manager.startPolling() }
    }

    private func header(_ printer: PrinterConnection) -> some View {
        HStack {
            Image(systemName: "printer.fill").font(.title2)
            VStack(alignment: .leading) {
                Text(printer.name).font(.headline)
                Text(printer.host).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label(manager.isOnline ? "Online" : "Offline", systemImage: "circle.fill")
                .font(.caption)
                .foregroundStyle(manager.isOnline ? .green : .red)
        }
    }

    private func jobCard(_ s: PrinterStatus) -> some View {
        Card {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: s.progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(s.progress * 100)) %").font(.title3.weight(.semibold)).monospacedDigit()
                }
                .frame(width: 92, height: 92)
                .animation(.easeInOut, value: s.progress)

                VStack(alignment: .leading, spacing: 6) {
                    Text(s.state.displayName).font(.headline)
                    if let file = s.fileName {
                        Text(file).font(.subheadline).lineLimit(2).foregroundStyle(.secondary)
                    }
                    if let layer = s.currentLayer, let total = s.totalLayers, total > 0 {
                        Label("Schicht \(layer)/\(total)", systemImage: "square.3.layers.3d").font(.caption)
                    }
                    if let remaining = s.remainingSeconds {
                        Label("noch \(Self.duration(remaining))", systemImage: "clock").font(.caption)
                    }
                    if let message = s.stateMessage {
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            if s.state == .printing || s.state == .paused {
                HStack {
                    if s.state == .printing {
                        Button { Task { await manager.perform { try await $0.pause() } } } label: {
                            Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
                        }
                    } else {
                        Button { Task { await manager.perform { try await $0.resume() } } } label: {
                            Label("Fortsetzen", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                    }
                    Button(role: .destructive) { confirmCancel = true } label: {
                        Label("Abbrechen", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    private func toolsCard(_ s: PrinterStatus) -> some View {
        Card {
            Text("Druckköpfe").font(.headline)
            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { i in
                    let heater = i < s.tools.count ? s.tools[i] : nil
                    let filament = i < s.filaments.count ? s.filaments[i] : nil
                    VStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(filament?.present == true ? Color(hex: filament?.color ?? "#888888") : Color.secondary.opacity(0.15))
                                .frame(height: 54)
                            if filament?.present != true {
                                Image(systemName: "questionmark").foregroundStyle(.secondary)
                            }
                            if s.activeTool == i {
                                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 3)
                            }
                        }
                        Text("T\(i + 1)").font(.caption.weight(.bold))
                        Text(filament?.type.flatMap { $0 == "NONE" ? nil : $0 } ?? "–").font(.caption2).lineLimit(1)
                        if let heater {
                            Text("\(Int(heater.temperature))°/\(Int(heater.target))°")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func bedCard(_ s: PrinterStatus) -> some View {
        Card {
            HStack {
                Label("Druckbett", systemImage: "square.fill.on.square")
                Spacer()
                Text("\(Int(s.bed.temperature)) °C / \(Int(s.bed.target)) °C").monospacedDigit()
            }
            if s.state != .printing && s.state != .paused {
                HStack {
                    Button("PLA vorheizen") {
                        Task { await manager.perform { try await $0.setBedTemperature(60) } }
                    }
                    Button("PETG vorheizen") {
                        Task { await manager.perform { try await $0.setBedTemperature(70) } }
                    }
                    Button("Aus") {
                        Task { await manager.perform { try await $0.setBedTemperature(0) } }
                    }
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
        }
    }

    private func offlineCard(_ error: String) -> some View {
        Card {
            Label("Drucker nicht erreichbar", systemImage: "wifi.exclamationmark").font(.headline)
            Text(error).font(.callout).foregroundStyle(.secondary)
            Text("Prüfe, ob der U1 eingeschaltet und im selben WLAN ist. Falls im Drucker-Menü ein LAN-/Entwicklermodus existiert, aktiviere ihn.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Erneut versuchen") { Task { await manager.refresh() } }.buttonStyle(.bordered)
        }
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Refreshing webcam snapshot (Moonraker webcam config).
struct CameraView: View {
    let client: MoonrakerClient?
    let active: Bool
    @State private var image: UIImage?
    @State private var snapshotURL: URL?
    @State private var unavailable = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else if !unavailable {
                RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.1))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { ProgressView() }
            }
        }
        .task(id: active) {
            guard let client else { return }
            if snapshotURL == nil {
                snapshotURL = try? await client.webcamSnapshotURL()
                if snapshotURL == nil { unavailable = true; return }
            }
            repeat {
                if let url = snapshotURL, let response = try? await URLSession.shared.data(from: url),
                   let img = UIImage(data: response.0) {
                    image = img
                }
                try? await Task.sleep(for: .seconds(active ? 2 : 10))
            } while !Task.isCancelled
        }
    }
}

/// Add or edit a printer, with Bonjour discovery.
struct PrinterEditView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let existing: PrinterConnection?

    @State private var name = "Snapmaker U1"
    @State private var host = ""
    @State private var apiKey = ""
    @State private var testing = false
    @State private var testResult: String?
    @StateObject private var discovery = PrinterDiscovery()

    var body: some View {
        NavigationStack {
            Form {
                Section("Im WLAN gefunden") {
                    if discovery.printers.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Suche nach Druckern …").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(discovery.printers) { found in
                        Button {
                            name = found.name
                            host = found.host
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
                Section {
                    TextField("Name", text: $name)
                    TextField("IP-Adresse (z. B. 192.168.1.50)", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API-Schlüssel (optional)", text: $apiKey)
                } header: {
                    Text("Manuell")
                } footer: {
                    Text("Die IP findest du am U1 unter Einstellungen → WLAN. Port 7125 wird automatisch verwendet.")
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
                    Button("Sichern") { save() }.disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let existing {
                    name = existing.name
                    host = existing.host
                    apiKey = existing.apiKey ?? ""
                }
                discovery.start()
            }
            .onDisappear { discovery.stop() }
        }
    }

    private var connection: PrinterConnection {
        PrinterConnection(id: existing?.id ?? UUID(), name: name.isEmpty ? "Snapmaker U1" : name,
                          host: host.trimmingCharacters(in: .whitespaces), apiKey: apiKey.isEmpty ? nil : apiKey)
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let info = try await MoonrakerClient(connection: connection).serverInfo()
            testResult = "✅ Verbunden – Klipper: \(info.klippyState)"
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
