import SliceKit
import SwiftUI

/// Expert mode: every slicer parameter, each with an explanation (ⓘ).
struct AdvancedSettingsView: View {
    @Binding var settings: PrintSettings
    @AppStorage("showInlineHelp") private var inlineHelp = false

    var body: some View {
        Form {
            Section {
                Toggle("Erklärungen direkt anzeigen", isOn: $inlineHelp)
            } footer: {
                Text("Tippe auf ⓘ neben einer Einstellung: was sie bewirkt, was mehr oder weniger bedeutet und ein Praxistipp.")
            }

            Section("Schichten") {
                number(.layerHeight, $settings.layerHeight, "mm", 0.06...0.32, step: 0.02)
                number(.firstLayerHeight, $settings.firstLayerHeight, "mm", 0.1...0.35, step: 0.05)
                number(.lineWidth, $settings.lineWidth, "mm", 0.3...0.8, step: 0.01)
                number(.outerWallLineWidth, $settings.outerWallLineWidth, "mm", 0.3...0.8, step: 0.01)
            }
            Section("Wände") {
                stepper(.wallLoops, $settings.wallLoops, 1...10)
                stepper(.topLayers, $settings.topLayers, 0...20)
                stepper(.bottomLayers, $settings.bottomLayers, 0...20)
                picker(.wallOrder, $settings.wallOrder)
                picker(.seamPosition, $settings.seamPosition)
            }
            Section {
                picker(.infillPattern, $settings.infillPattern)
                number(.infillDensity, percent(\.infillDensity), "%", 0...100, step: 5)
                number(.infillOverlap, percent(\.infillOverlap), "%", 0...50, step: 5)
            } header: {
                Text("Füllung")
            } footer: {
                Text(settings.infillPattern.explanation)
            }
            Section("Oberflächen") {
                picker(.topSurfacePattern, $settings.topSurfacePattern)
                picker(.bottomSurfacePattern, $settings.bottomSurfacePattern)
                toggle(.ironing, $settings.ironing)
                if settings.ironing {
                    number(.ironingSpeed, $settings.ironingSpeed, "mm/s", 10...100, step: 5)
                    number(.ironingFlow, percent(\.ironingFlow), "%", 5...30, step: 1)
                    number(.ironingSpacing, $settings.ironingSpacing, "mm", 0.05...0.4, step: 0.05)
                }
                toggle(.detectBridges, $settings.detectBridges)
                if settings.detectBridges {
                    number(.bridgeSpeed, $settings.bridgeSpeed, "mm/s", 10...150, step: 5)
                    number(.bridgeFlow, percent(\.bridgeFlow), "%", 60...120, step: 5)
                }
            }
            Section {
                toggle(.spiralVase, $settings.spiralVase)
                toggle(.fuzzySkin, $settings.fuzzySkin)
                if settings.fuzzySkin {
                    number(.fuzzySkinThickness, $settings.fuzzySkinThickness, "mm", 0.1...1, step: 0.05)
                    number(.fuzzySkinPointDistance, $settings.fuzzySkinPointDistance, "mm", 0.2...3, step: 0.1)
                }
            } header: {
                Text("Spezialmodi")
            } footer: {
                if settings.spiralVase {
                    Text("Vasenmodus aktiv: 1 Wand, keine Füllung, kein Deckel. Die \(settings.bottomLayers) unteren Schichten bilden den Boden.")
                }
            }
            Section("Geschwindigkeit") {
                number(.outerWallSpeed, $settings.outerWallSpeed, "mm/s", 20...500, step: 10)
                number(.innerWallSpeed, $settings.innerWallSpeed, "mm/s", 20...600, step: 10)
                number(.infillSpeed, $settings.infillSpeed, "mm/s", 20...600, step: 10)
                number(.solidInfillSpeed, $settings.solidInfillSpeed, "mm/s", 20...600, step: 10)
                number(.topSurfaceSpeed, $settings.topSurfaceSpeed, "mm/s", 20...500, step: 10)
                number(.firstLayerSpeed, $settings.firstLayerSpeed, "mm/s", 10...150, step: 5)
                number(.travelSpeed, $settings.travelSpeed, "mm/s", 100...600, step: 25)
                number(.acceleration, $settings.acceleration, "mm/s²", 1000...20000, step: 500)
                number(.outerWallAcceleration, $settings.outerWallAcceleration, "mm/s²", 500...20000, step: 500)
                number(.minLayerTime, $settings.minLayerTime, "s", 0...30, step: 1)
            }
            Section("Stützen") {
                picker(.support, $settings.support)
                if settings.support != .off {
                    number(.supportAngle, $settings.supportAngle, "°", 10...80, step: 5)
                    number(.supportTopZDistance, $settings.supportTopZDistance, "mm", 0.1...0.4, step: 0.05)
                    number(.supportXYDistance, $settings.supportXYDistance, "mm", 0.2...2, step: 0.05)
                    number(.supportSpacing, $settings.supportSpacing, "mm", 1...6, step: 0.5)
                }
            }
            Section("Haftung") {
                number(.brimWidth, $settings.brimWidth, "mm", 0...15, step: 1)
                stepper(.skirtLoops, $settings.skirtLoops, 0...5)
                if settings.skirtLoops > 0 {
                    number(.skirtDistance, $settings.skirtDistance, "mm", 1...20, step: 1)
                }
                number(.elephantFootCompensation, $settings.elephantFootCompensation, "mm", 0...0.4, step: 0.025)
            }
            if settings.machine.multiMaterial == .filamentSwitcher {
                Section("Mehrfarbig (ACE Pro)") {
                    toggle(.primeTower, $settings.primeTower)
                    if settings.primeTower {
                        number(.primeTowerWidth, $settings.primeTowerWidth, "mm", 15...60, step: 5)
                    }
                }
            }
            Section("Rückzug & Bewegung") {
                number(.zHop, $settings.zHop, "mm", 0...1, step: 0.1)
                number(.retractSpeed, $settings.retractSpeed, "mm/s", 10...80, step: 5)
                number(.retractMinTravel, $settings.retractMinTravel, "mm", 0.5...5, step: 0.5)
            }
            Section("Drucker") {
                if settings.machine.supportsPlateTypes.count > 1 {
                    HelpRow(key: .plateType) {
                        Picker(SettingKey.plateType.help.title, selection: $settings.plateType) {
                            ForEach(settings.machine.supportsPlateTypes) { Text($0.displayName).tag($0) }
                        }
                    }
                }
                if settings.printer == .snapmakerU1 {
                    toggle(.enableTimelapse, $settings.enableTimelapse)
                    toggle(.enableBedLeveling, $settings.enableBedLeveling)
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

    // MARK: - Rows

    private func percent(_ path: WritableKeyPath<PrintSettings, Double>) -> Binding<Double> {
        Binding(get: { settings[keyPath: path] * 100 }, set: { settings[keyPath: path] = $0 / 100 })
    }

    private func number(_ key: SettingKey, _ value: Binding<Double>, _ unit: String,
                        _ range: ClosedRange<Double>, step: Double) -> some View {
        HelpRow(key: key) {
            Stepper(value: value, in: range, step: step) {
                LabeledContent(key.help.title, value: Self.format(value.wrappedValue, step: step) + " " + unit)
            }
        }
    }

    private func stepper(_ key: SettingKey, _ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        HelpRow(key: key) {
            Stepper(value: value, in: range) {
                LabeledContent(key.help.title, value: "\(value.wrappedValue)")
            }
        }
    }

    private func toggle(_ key: SettingKey, _ value: Binding<Bool>) -> some View {
        HelpRow(key: key) {
            Toggle(key.help.title, isOn: value)
        }
    }

    private func picker<T: CaseIterable & Identifiable & Hashable & DisplayNamed>(_ key: SettingKey, _ value: Binding<T>) -> some View
    where T.AllCases: RandomAccessCollection {
        HelpRow(key: key) {
            Picker(key.help.title, selection: value) {
                ForEach(T.allCases) { Text($0.displayName).tag($0) }
            }
        }
    }

    static func format(_ v: Double, step: Double) -> String {
        let cents = step * 100
        return abs(cents - cents.rounded()) > 1e-6 ? String(format: "%.3f", v) : step < 0.1 ? String(format: "%.2f", v)
            : step < 1 ? String(format: "%.1f", v) : String(format: "%.0f", v)
    }
}

/// Enums that show a German name in pickers.
protocol DisplayNamed {
    var displayName: String { get }
}

extension InfillPattern: DisplayNamed {}
extension SupportMode: DisplayNamed {}
extension SeamPosition: DisplayNamed {}
extension WallOrder: DisplayNamed {}
extension SurfacePattern: DisplayNamed {}
