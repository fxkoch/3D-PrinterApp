import SliceKit
import SwiftUI

struct AdvancedSettingsView: View {
    @Binding var settings: PrintSettings

    var body: some View {
        Form {
            Section("Schichten") {
                number("Schichthöhe", $settings.layerHeight, "mm", 0.08...0.32, step: 0.02)
                number("Erste Schicht", $settings.firstLayerHeight, "mm", 0.1...0.35, step: 0.05)
                stepper("Wandlinien", $settings.wallLoops, 1...8)
                stepper("Obere Schichten", $settings.topLayers, 0...15)
                stepper("Untere Schichten", $settings.bottomLayers, 0...15)
            }
            Section("Füllung") {
                Picker("Muster", selection: $settings.infillPattern) {
                    ForEach(InfillPattern.allCases) { Text($0.displayName).tag($0) }
                }
                number("Dichte", Binding(get: { settings.infillDensity * 100 }, set: { settings.infillDensity = $0 / 100 }),
                       "%", 0...100, step: 5)
            }
            Section("Geschwindigkeit (mm/s)") {
                number("Außenwand", $settings.outerWallSpeed, "mm/s", 20...500, step: 10)
                number("Innenwand", $settings.innerWallSpeed, "mm/s", 20...600, step: 10)
                number("Füllung", $settings.infillSpeed, "mm/s", 20...600, step: 10)
                number("Oberfläche", $settings.topSurfaceSpeed, "mm/s", 20...500, step: 10)
                number("Erste Schicht", $settings.firstLayerSpeed, "mm/s", 10...150, step: 5)
                number("Bewegung", $settings.travelSpeed, "mm/s", 100...500, step: 25)
                number("Min. Schichtzeit", $settings.minLayerTime, "s", 0...30, step: 1)
            }
            Section("Stützen") {
                Picker("Modus", selection: $settings.support) {
                    ForEach(SupportMode.allCases) { Text($0.displayName).tag($0) }
                }
                number("Überhang-Winkel", $settings.supportAngle, "°", 10...80, step: 5)
                number("Abstand Z", $settings.supportTopZDistance, "mm", 0.1...0.4, step: 0.05)
                number("Linienabstand", $settings.supportSpacing, "mm", 1...6, step: 0.5)
            }
            Section("Haftung") {
                number("Brim-Breite", $settings.brimWidth, "mm", 0...15, step: 1)
                stepper("Skirt-Linien", $settings.skirtLoops, 0...5)
            }
            Section("Rückzug") {
                number("Z-Hop", $settings.zHop, "mm", 0...1, step: 0.1)
                number("Rückzugs-Geschw.", $settings.retractSpeed, "mm/s", 10...60, step: 5)
            }
            Section("Drucker") {
                Toggle("Zeitraffer", isOn: $settings.enableTimelapse)
                Toggle("Automatisches Bett-Leveling", isOn: $settings.enableBedLeveling)
            }
            Section {
                Button("Auf Standard zurücksetzen", role: .destructive) {
                    let filaments = settings.filaments
                    settings = PrintSettings()
                    settings.filaments = filaments
                }
            }
        }
        .navigationTitle("Erweitert")
    }

    private func number(_ title: String, _ value: Binding<Double>, _ unit: String,
                        _ range: ClosedRange<Double>, step: Double) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text(Self.format(value.wrappedValue, step: step) + " " + unit).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func stepper(_ title: String, _ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private static func format(_ v: Double, step: Double) -> String {
        step < 0.1 ? String(format: "%.2f", v) : step < 1 ? String(format: "%.1f", v) : String(format: "%.0f", v)
    }
}
