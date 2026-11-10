import PrinterKit
import SliceKit
import SwiftUI

/// Live view of the running print: camera plus what the printer is doing right now.
struct LivePrintView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let printer: PrinterConnection
    @State private var camera = LiveCamera()

    private var status: PrinterStatus? { app.printers.status(of: printer) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    cameraPanel
                    if let status {
                        phasePanel(status)
                        statsPanel(status)
                    } else {
                        ProgressView("Verbinde …").padding(.top, 30)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Live")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } } }
            .refreshable { await app.printers.refresh(printer) }
        }
        .onAppear { startCamera() }
        .onDisappear { camera.stop() }
    }

    // MARK: Camera

    @ViewBuilder private var cameraPanel: some View {
        #if canImport(Network)
        if let lan = app.printers.driver(for: printer) as? AnycubicLANClient {
            ZStack {
                Color.black
                H264PlayerView(renderer: camera.renderer)
                switch camera.state {
                case .starting, .idle: VStack(spacing: 8) { ProgressView().tint(.white); Text("Kamera startet …").font(.caption).foregroundStyle(.white) }
                case .failed(let message):
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash").font(.title).foregroundStyle(.white)
                        Text(message).font(.caption).foregroundStyle(.white).multilineTextAlignment(.center)
                        Button("Erneut versuchen") { startCamera() }.buttonStyle(.bordered).tint(.white)
                    }.padding()
                case .live: EmptyView()
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .accessibilityIdentifier("liveCamera")
            .accessibilityValue(camera.state == .live ? "live" : "wartet")
            .onChange(of: status?.cameraStreamURL) { _, _ in if camera.state == .idle { startCamera() } }
            .id(lan.connection.id)
        } else {
            CameraView(driver: app.printers.driver(for: printer), active: true)
        }
        #else
        CameraView(driver: app.printers.driver(for: printer), active: true)
        #endif
    }

    private func startCamera() {
        #if canImport(Network)
        guard let lan = app.printers.driver(for: printer) as? AnycubicLANClient else { return }
        let url = status?.cameraStreamURL ?? URL(string: "http://\(printer.hostOnly):18088/flv")!
        camera.start(streamURL: url, prepare: { try await lan.startCamera() }, finish: { try? await lan.stopCamera() })
        #endif
    }

    // MARK: Info

    private func phasePanel(_ s: PrinterStatus) -> some View {
        let phase = s.phase
        return Panel(title: "Aktueller Schritt", systemImage: "list.bullet.below.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(PrintPhase.Step.allCases, id: \.rawValue) { step in
                        stepChip(step, current: phase.step)
                    }
                }
                Text(phase.title).font(.title3.weight(.semibold))
                if let detail = phase.detail { Text(detail).font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
                if s.state == .printing || s.state == .paused {
                    ProgressView(value: s.progress).tint(s.state.color)
                }
            }
        }
    }

    private func stepChip(_ step: PrintPhase.Step, current: PrintPhase.Step?) -> some View {
        let reached = current.map { step.rawValue <= $0.rawValue } ?? false
        let active = current == step
        return Text(step.title)
            .font(.caption2.weight(active ? .bold : .regular))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(active ? Color.white : (reached ? Color.primary : Color.secondary))
            .background(active ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
            .opacity(reached || active ? 1 : 0.6)
            .lineLimit(1)
    }

    private func statsPanel(_ s: PrinterStatus) -> some View {
        Panel(title: "Details", systemImage: "gauge") {
            let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                if let file = s.fileName { Metric(value: file, caption: "Datei", systemImage: "doc") }
                if let layer = s.currentLayer, let total = s.totalLayers, total > 0 {
                    Metric(value: "\(layer) / \(total)", caption: "Schicht", systemImage: "square.3.layers.3d")
                }
                if let remaining = s.remainingSeconds {
                    Metric(value: Format.duration(remaining), caption: "Restzeit", systemImage: "clock")
                    Metric(value: Date().addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened),
                           caption: "Fertig um", systemImage: "flag.checkered")
                }
                if s.printDuration > 0 { Metric(value: Format.duration(s.printDuration), caption: "Gedruckt seit", systemImage: "hourglass") }
                if let tool = s.tools.first {
                    Metric(value: "\(Int(tool.temperature))° / \(Int(tool.target))°", caption: "Düse", systemImage: "flame")
                }
                Metric(value: "\(Int(s.bed.temperature))° / \(Int(s.bed.target))°", caption: "Bett", systemImage: "square.fill")
                if let fan = s.fanPercent { Metric(value: "\(Int(fan)) %", caption: "Lüfter", systemImage: "fan") }
                if let mode = s.speedMode {
                    Metric(value: ["", "Leise", "Standard", "Sport"][min(max(mode, 0), 3)], caption: "Tempo", systemImage: "speedometer")
                }
                if let slot = s.filamentBox?.activeSlot ?? s.activeTool, s.filaments.indices.contains(slot) {
                    let f = s.filaments[slot]
                    Metric(value: "\(slot + 1): \(f.type ?? "?")", caption: "Filament", systemImage: "circle.hexagongrid")
                }
            }
        }
    }
}
