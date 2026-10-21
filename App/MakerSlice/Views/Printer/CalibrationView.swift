import PrinterKit
import SwiftUI

/// Calibration values: bed mesh heat map, Z offset, pressure advance, input shaper.
struct CalibrationView: View {
    @Environment(AppModel.self) private var app
    let printer: PrinterConnection
    @State private var loading = true

    private var data: CalibrationData? { app.printers.calibration[printer.id] }

    var body: some View {
        List {
            if loading && data == nil {
                HStack { ProgressView(); Text("Lese Kalibrierdaten …").foregroundStyle(.secondary) }
            }
            if let mesh = data?.bedMesh {
                Section {
                    BedMeshView(mesh: mesh).frame(height: 260).listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    LabeledContent("Profil", value: mesh.profile)
                    LabeledContent("Messpunkte", value: "\(mesh.points.first?.count ?? 0) × \(mesh.points.count)")
                    LabeledContent("Unebenheit", value: String(format: "%.3f mm", mesh.range))
                } header: {
                    Text("Bett-Mesh")
                } footer: {
                    Text(mesh.range < 0.15 ? "Sehr eben – optimal." : mesh.range < 0.3 ? "Im normalen Bereich." : "Deutliche Unebenheit – Bett prüfen oder neu leveln.")
                }
            }
            if let data, data.zOffset != nil || !data.pressureAdvance.isEmpty || !data.inputShaper.isEmpty {
                Section("Werte") {
                    if let z = data.zOffset { LabeledContent("Z-Offset", value: String(format: "%.3f mm", z)) }
                    ForEach(data.pressureAdvance.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        LabeledContent("Pressure Advance \(Self.toolName(key))", value: String(format: "%.4f", value))
                    }
                    ForEach(data.inputShaper.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        LabeledContent(Self.shaperName(key), value: value)
                    }
                }
            }
            if let notes = data?.notes, !notes.isEmpty {
                Section("Gerät") {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                        LabeledContent(note.0) { Text(note.1).multilineTextAlignment(.trailing) }
                    }
                }
            }
            if !loading && data == nil {
                Text("Keine Kalibrierdaten verfügbar. Ist der Drucker online?").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Kalibrierung")
        .task {
            await app.printers.loadCalibration(printer)
            loading = false
        }
        .refreshable { await app.printers.loadCalibration(printer) }
    }

    static func toolName(_ key: String) -> String {
        key == "extruder" ? "T1" : key.hasPrefix("extruder") ? "T\((Int(key.dropFirst(8)) ?? 0) + 1)" : key
    }

    static func shaperName(_ key: String) -> String {
        switch key {
        case "shaper_type_x": return "Input Shaper X"
        case "shaper_freq_x": return "Frequenz X (Hz)"
        case "shaper_type_y": return "Input Shaper Y"
        case "shaper_freq_y": return "Frequenz Y (Hz)"
        default: return key
        }
    }
}

/// Heat map of the probed bed mesh (front at the bottom).
struct BedMeshView: View {
    let mesh: CalibrationData.BedMesh

    var body: some View {
        let flat = mesh.points.flatMap { $0 }
        let lo = flat.min() ?? 0, hi = flat.max() ?? 0
        let span = max(abs(lo), abs(hi), 0.05)
        VStack(spacing: 6) {
            Canvas { context, size in
                let rows = mesh.points.count
                let cols = mesh.points.first?.count ?? 0
                guard rows > 0, cols > 0 else { return }
                let w = size.width / CGFloat(cols), h = size.height / CGFloat(rows)
                for (r, row) in mesh.points.enumerated() {
                    for (c, value) in row.enumerated() {
                        let rect = CGRect(x: CGFloat(c) * w, y: size.height - CGFloat(r + 1) * h, width: w - 1, height: h - 1)
                        context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(BedMeshView.color(value, span: span)))
                        if w > 34 {
                            context.draw(Text(String(format: "%.2f", value)).font(.system(size: 9)).foregroundColor(.primary),
                                         at: CGPoint(x: rect.midX, y: rect.midY))
                        }
                    }
                }
            }
            HStack {
                Text(String(format: "%.2f mm", lo)).foregroundStyle(.blue)
                Spacer()
                Text("vorne ↓").foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "+%.2f mm", hi)).foregroundStyle(.red)
            }
            .font(.caption2)
        }
    }

    static func color(_ v: Double, span: Double) -> Color {
        let t = max(-1, min(1, v / span))
        return t < 0 ? Color.blue.opacity(0.15 + 0.6 * -t) : Color.red.opacity(0.15 + 0.6 * t)
    }
}
