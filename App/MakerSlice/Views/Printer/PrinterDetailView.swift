import PrinterKit
import SliceKit
import SwiftUI

/// Live dashboard of one printer.
struct PrinterDetailView: View {
    @Environment(AppModel.self) private var app
    let printer: PrinterConnection
    @State private var confirmCancel = false
    @State private var editing = false

    private var status: PrinterStatus? { app.printers.status(of: printer) }
    private var model: PrinterModel { app.printers.model(of: printer) }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                header
                if let status {
                    jobPanel(status)
                    if printer.kind == .moonraker {
                        CameraView(driver: app.printers.driver(for: printer), active: status.state == .printing)
                    }
                    temperaturePanel(status)
                    materialPanel(status)
                    machinePanel(status)
                } else if let error = app.printers.errors[printer.id] {
                    offlinePanel(error)
                } else {
                    ProgressView("Verbinde …").padding(.top, 40)
                }
                links
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(printer.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Bearbeiten") { editing = true }
            }
        }
        .sheet(isPresented: $editing) { PrinterEditView(existing: printer) }
        .confirmationDialog("Druck wirklich abbrechen?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Druck abbrechen", role: .destructive) {
                Task { await app.printers.perform(on: printer, "Druck abgebrochen") { try await $0.cancel() } }
            }
        }
        .refreshable { await app.printers.refresh(printer) }
        .onAppear { app.printers.selectedID = printer.id }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName).font(.headline)
                Text("\(printer.hostOnly) · \(printer.kind.displayName)").font(.caption).foregroundStyle(.secondary)
                if let fw = status?.firmware { Text("Firmware \(fw)").font(.caption2).foregroundStyle(.tertiary) }
            }
            Spacer()
            StatusBadge(text: app.printers.isOnline(printer) ? "Online" : "Offline",
                        color: app.printers.isOnline(printer) ? .green : .secondary)
        }
    }

    private func jobPanel(_ s: PrinterStatus) -> some View {
        Panel(title: "Auftrag", systemImage: "printer") {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Color(.tertiarySystemFill), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: s.progress)
                        .stroke(s.state.color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(s.progress * 100)) %").font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                }
                .frame(width: 86, height: 86)
                .animation(.easeInOut, value: s.progress)
                VStack(alignment: .leading, spacing: 5) {
                    StatusBadge(text: s.state.displayName, color: s.state.color)
                    if let file = s.fileName { Text(file).font(.subheadline).lineLimit(2) }
                    if let layer = s.currentLayer, let total = s.totalLayers, total > 0 {
                        Label("Schicht \(layer) / \(total)", systemImage: "square.3.layers.3d").font(.caption)
                    }
                    if let remaining = s.remainingSeconds {
                        Label("noch \(Format.duration(remaining))", systemImage: "clock").font(.caption)
                    }
                    if let message = s.stateMessage { Text(message).font(.caption).foregroundStyle(.orange) }
                }
                Spacer(minLength: 0)
            }
            if s.state == .printing || s.state == .paused {
                HStack {
                    if s.state == .printing {
                        Button {
                            Task { await app.printers.perform(on: printer, "Druck pausiert") { try await $0.pause() } }
                        } label: { Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity) }
                    } else {
                        Button {
                            Task { await app.printers.perform(on: printer, "Druck fortgesetzt") { try await $0.resume() } }
                        } label: { Label("Fortsetzen", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    }
                    Button(role: .destructive) { confirmCancel = true } label: {
                        Label("Abbrechen", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func temperaturePanel(_ s: PrinterStatus) -> some View {
        Panel(title: "Temperaturen", systemImage: "thermometer.medium") {
            let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(Array(s.tools.enumerated()), id: \.offset) { i, heater in
                    Metric(value: "\(Int(heater.temperature))° / \(Int(heater.target))°",
                           caption: s.tools.count > 1 ? "Düse T\(i + 1)" : "Düse", systemImage: "flame")
                }
                Metric(value: "\(Int(s.bed.temperature))° / \(Int(s.bed.target))°", caption: "Bett", systemImage: "square.fill")
                if let chamber = s.chamber {
                    Metric(value: Format.temp(chamber.temperature), caption: "Kammer", systemImage: "cube.transparent")
                }
            }
            if s.state != .printing && s.state != .paused {
                Menu {
                    ForEach(["PLA", "PETG", "ABS", "TPU"], id: \.self) { type in
                        if let f = FilamentLibrary.bestMatch(type: type, printer: model) {
                            Button("\(type): \(f.nozzleTemp)° / \(f.bedTemp)°") {
                                Task {
                                    await app.printers.perform(on: printer, "Vorheizen \(type)") { driver in
                                        try await driver.setBedTemperature(f.bedTemp)
                                        try await driver.setToolTemperature(tool: 0, f.nozzleTemp)
                                    }
                                }
                            }
                        }
                    }
                    Button("Abkühlen", role: .destructive) {
                        Task {
                            await app.printers.perform(on: printer, "Heizungen aus") { driver in
                                try await driver.setBedTemperature(0)
                                for t in 0..<max(1, s.tools.count) { try await driver.setToolTemperature(tool: t, 0) }
                            }
                        }
                    }
                } label: {
                    Label("Vorheizen", systemImage: "flame").font(.subheadline)
                }
            }
        }
    }

    private func materialPanel(_ s: PrinterStatus) -> some View {
        Panel(title: model == .kobraS1 ? "ACE Pro" : "Filament", systemImage: "circle.hexagongrid") {
            if s.filaments.isEmpty {
                Text("Der Drucker meldet kein Filament.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    ForEach(Array(s.filaments.prefix(4).enumerated()), id: \.offset) { i, f in
                        VStack(spacing: 4) {
                            Swatch(color: f.present ? (f.color ?? "#888888") : "#E5E5EA", label: "\(i + 1)",
                                   selected: s.activeTool == i || s.filamentBox?.activeSlot == i, size: 36)
                            Text(f.present ? (f.type ?? "?") : "leer").font(.caption2.weight(.medium)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            if let box = s.filamentBox {
                Divider()
                HStack {
                    if let h = box.humidity { Metric(value: "\(Int(h)) %", caption: "Feuchte", systemImage: "humidity") }
                    if let t = box.temperature { Metric(value: Format.temp(t), caption: "Box", systemImage: "thermometer") }
                    Metric(value: box.drying ? "\(Int(box.dryingRemainingMinutes ?? 0)) min" : "aus", caption: "Trocknen",
                           systemImage: "sun.max")
                }
                #if canImport(Network)
                if let lan = app.printers.driver(for: printer) as? AnycubicLANClient {
                    Button(box.drying ? "Trocknen beenden" : "Trocknen starten (45 °C, 4 h)") {
                        let on = !box.drying
                        Task { await app.printers.perform(on: printer, on ? "Trocknen gestartet" : "Trocknen beendet") { _ in
                            try await lan.setDrying(on)
                        } }
                    }
                    .font(.subheadline)
                }
                #endif
            }
        }
    }

    private func machinePanel(_ s: PrinterStatus) -> some View {
        Panel(title: "Gerät", systemImage: "gearshape") {
            HStack {
                if let fan = s.fanPercent { Metric(value: "\(Int(fan)) %", caption: "Bauteillüfter", systemImage: "fan") }
                if let aux = s.auxFanPercent { Metric(value: "\(Int(aux)) %", caption: "Zusatzlüfter", systemImage: "wind") }
                if let mode = s.speedMode {
                    Metric(value: ["", "Leise", "Standard", "Sport"][min(max(mode, 0), 3)], caption: "Tempo", systemImage: "speedometer")
                }
            }
            Toggle(isOn: Binding(get: { s.lightOn ?? false }, set: { on in
                Task { await app.printers.perform(on: printer, on ? "Licht an" : "Licht aus") { try await $0.setLight(on) } }
            })) {
                Label("Beleuchtung", systemImage: "lightbulb")
            }
        }
    }

    private func offlinePanel(_ error: String) -> some View {
        Panel(title: "Nicht erreichbar", systemImage: "wifi.exclamationmark") {
            Text(error).font(.callout).foregroundStyle(.secondary)
            Text(printer.kind == .anycubicLAN
                 ? "Am Kobra S1: Einstellungen → Netzwerk → LAN-Modus einschalten. iPhone und Drucker müssen im selben WLAN sein."
                 : "Prüfe, ob der Drucker eingeschaltet und im selben WLAN ist.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Erneut versuchen") { Task { await app.printers.refresh(printer) } }.buttonStyle(.bordered)
        }
    }

    private var links: some View {
        VStack(spacing: 0) {
            NavigationLink { CalibrationView(printer: printer) } label: {
                LinkRow(title: "Kalibrierdaten", icon: "level")
            }
            Divider().padding(.leading, 44)
            NavigationLink { LogView(source: printer.name) } label: {
                LinkRow(title: "Protokoll & Fehler", icon: "list.bullet.rectangle")
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

private struct LinkRow: View {
    let title: String
    let icon: String

    var body: some View {
        HStack {
            Image(systemName: icon).frame(width: 24).foregroundStyle(Color.accentColor)
            Text(title).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(14)
        .contentShape(Rectangle())
    }
}

/// Refreshing webcam snapshot (Moonraker webcam config).
struct CameraView: View {
    let driver: PrinterDriver
    let active: Bool
    @State private var image: UIImage?
    @State private var snapshotURL: URL?
    @State private var unavailable = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            } else if !unavailable {
                RoundedRectangle(cornerRadius: Theme.corner).fill(Color(.tertiarySystemFill))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { ProgressView() }
            }
        }
        .task(id: active) {
            guard let moonraker = driver as? MoonrakerClient else { unavailable = true; return }
            if snapshotURL == nil {
                snapshotURL = try? await moonraker.webcamSnapshotURL()
                if snapshotURL == nil { unavailable = true; return }
            }
            repeat {
                if let url = snapshotURL, let response = try? await URLSession.shared.data(from: url),
                   let img = UIImage(data: response.0) {
                    image = img
                }
                try? await Task.sleep(nanoseconds: UInt64((active ? 2 : 10) * 1_000_000_000))
            } while !Task.isCancelled
        }
    }
}
