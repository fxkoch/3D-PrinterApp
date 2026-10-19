import SliceKit
import SwiftUI

/// Expert mode: every slicer parameter.
struct AdvancedSettingsView: View {
    @Binding var settings: PrintSettings

    var body: some View {
        Form {
            Section("Schichten & Wände") {
                number("Schichthöhe", $settings.layerHeight, "mm", 0.06...0.32, step: 0.02)
                number("Erste Schicht", $settings.firstLayerHeight, "mm", 0.1...0.35, step: 0.05)
                number("Linienbreite", $settings.lineWidth, "mm", 0.3...0.8, step: 0.01)
                number("Linienbreite außen", $settings.outerWallLineWidth, "mm", 0.3...0.8, step: 0.01)
                stepper("Wandlinien", $settings.wallLoops, 1...10)
                stepper("Obere Schichten", $settings.topLayers, 0...20)
                stepper("Untere Schichten", $settings.bottomLayers, 0...20)
            }
            Section {
                Picker("Muster", selection: $settings.infillPattern) {
                    ForEach(InfillPattern.allCases) { Text($0.displayName).tag($0) }
                }
                number("Dichte", Binding(get: { settings.infillDensity * 100 }, set: { settings.infillDensity = $0 / 100 }),
                       "%", 0...100, step: 5)
                number("Überlappung Füllung/Wand", Binding(get: { settings.infillOverlap * 100 },
                                                         set: { settings.infillOverlap = $0 / 100 }), "%", 0...50, step: 5)
            } header: {
                Text("Füllung")
            } footer: {
                Text(settings.infillPattern.explanation)
            }
            Section("Oberflächen") {
                Toggle("Glätten (Ironing)", isOn: $settings.ironing)
                if settings.ironing {
                    number("Glätt-Geschwindigkeit", $settings.ironingSpeed, "mm/s", 10...100, step: 5)
                    number("Glätt-Fluss", Binding(get: { settings.ironingFlow * 100 }, set: { settings.ironingFlow = $0 / 100 }),
                           "%", 5...30, step: 1)
                    number("Glätt-Abstand", $settings.ironingSpacing, "mm", 0.05...0.4, step: 0.05)
                }
                Toggle("Brücken erkennen", isOn: $settings.detectBridges)
                if settings.detectBridges {
                    number("Brücken-Geschwindigkeit", $settings.bridgeSpeed, "mm/s", 10...150, step: 5)
                    number("Brücken-Fluss", Binding(get: { settings.bridgeFlow * 100 }, set: { settings.bridgeFlow = $0 / 100 }),
                           "%", 60...120, step: 5)
                }
            }
            Section("Geschwindigkeit") {
                number("Außenwand", $settings.outerWallSpeed, "mm/s", 20...500, step: 10)
                number("Innenwand", $settings.innerWallSpeed, "mm/s", 20...600, step: 10)
                number("Füllung", $settings.infillSpeed, "mm/s", 20...600, step: 10)
                number("Massive Füllung", $settings.solidInfillSpeed, "mm/s", 20...600, step: 10)
                number("Oberfläche", $settings.topSurfaceSpeed, "mm/s", 20...500, step: 10)
                number("Erste Schicht", $settings.firstLayerSpeed, "mm/s", 10...150, step: 5)
                number("Bewegung", $settings.travelSpeed, "mm/s", 100...600, step: 25)
                number("Beschleunigung", $settings.acceleration, "mm/s²", 1000...20000, step: 500)
                number("Beschl. Außenwand", $settings.outerWallAcceleration, "mm/s²", 500...20000, step: 500)
                number("Min. Schichtzeit (0 = Material)", $settings.minLayerTime, "s", 0...30, step: 1)
            }
            Section("Stützen") {
                Picker("Modus", selection: $settings.support) {
                    ForEach(SupportMode.allCases) { Text($0.displayName).tag($0) }
                }
                number("Überhang-Winkel", $settings.supportAngle, "°", 10...80, step: 5)
                number("Abstand oben (Z)", $settings.supportTopZDistance, "mm", 0.1...0.4, step: 0.05)
                number("Abstand seitlich", $settings.supportXYDistance, "mm", 0.2...2, step: 0.05)
                number("Linienabstand", $settings.supportSpacing, "mm", 1...6, step: 0.5)
            }
            Section("Haftung") {
                number("Brim-Breite", $settings.brimWidth, "mm", 0...15, step: 1)
                stepper("Skirt-Linien", $settings.skirtLoops, 0...5)
                number("Skirt-Abstand", $settings.skirtDistance, "mm", 1...20, step: 1)
            }
            if settings.machine.multiMaterial == .filamentSwitcher {
                Section("Mehrfarbig (ACE Pro)") {
                    Toggle("Reinigungsturm", isOn: $settings.primeTower)
                    number("Turmbreite", $settings.primeTowerWidth, "mm", 15...60, step: 5)
                }
            }
            Section("Rückzug & Bewegung") {
                number("Z-Hop", $settings.zHop, "mm", 0...1, step: 0.1)
                number("Rückzugs-Geschwindigkeit", $settings.retractSpeed, "mm/s", 10...80, step: 5)
                number("Min. Weg für Rückzug", $settings.retractMinTravel, "mm", 0.5...5, step: 0.5)
            }
            Section("Drucker") {
                if settings.printer == .snapmakerU1 {
                    Toggle("Zeitraffer", isOn: $settings.enableTimelapse)
                    Toggle("Automatisches Bett-Leveling", isOn: $settings.enableBedLeveling)
                }
                LabeledContent("Bauraum", value: "\(Int(settings.bedSize)) × \(Int(settings.bedSize)) × \(Int(settings.maxHeight)) mm")
            }
            Section {
                Button("Auf Standard zurücksetzen", role: .destructive) {
                    let filaments = settings.filaments
                    settings = PrintSettings(printer: settings.printer)
                    settings.filaments = filaments
                }
            }
        }
        .navigationTitle("Experte")
    }

    private func number(_ title: String, _ value: Binding<Double>, _ unit: String,
                        _ range: ClosedRange<Double>, step: Double) -> some View {
        Stepper(value: value, in: range, step: step) {
            LabeledContent(title, value: Self.format(value.wrappedValue, step: step) + " " + unit)
        }
    }

    private func stepper(_ title: String, _ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            LabeledContent(title, value: "\(value.wrappedValue)")
        }
    }

    static func format(_ v: Double, step: Double) -> String {
        step < 0.1 ? String(format: "%.2f", v) : step < 1 ? String(format: "%.1f", v) : String(format: "%.0f", v)
    }
}
