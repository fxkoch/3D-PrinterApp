import SliceKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section {
                    Toggle("Expertenmodus", isOn: $app.expertMode)
                        .accessibilityIdentifier("expertToggle")
                } footer: {
                    Text("Zeigt alle Slicer-Parameter und erlaubt, Filament-Werte im Detail anzupassen. Empfohlene Werte werden immer je Filament vorgeladen.")
                }
                Section("Standard-Einstellungen") {
                    ForEach(PrinterModel.allCases) { model in
                        NavigationLink(model.displayName) {
                            DefaultSettingsEditor(model: model)
                        }
                    }
                }
                Section("Bibliothek") {
                    LabeledContent("Filamentprofile", value: "\(FilamentLibrary.all.count)")
                    LabeledContent("Hersteller", value: "\(FilamentLibrary.vendors.count)")
                    LabeledContent("Modelle in der Bibliothek", value: "\(app.library.items.count)")
                }
                Section("Über") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    Text("Druckprofile: offizielle OrcaSlicer-Profile für Snapmaker U1 und Anycubic Kobra S1 sowie die Orca-Filamentbibliothek.")
                    Text("Polygon-Geometrie: Clipper2 von Angus Johnson (Boost Software License).")
                    Text("Kobra-S1-LAN-Protokoll nach den Community-Projekten anycubic-lan, anycubic_ha_local und Rinkhals.")
                    Text("MakerWorld und Printables sind Marken ihrer jeweiligen Betreiber; MakerSlice ist nicht mit ihnen verbunden.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Einstellungen")
        }
    }
}

/// Edits the stored default settings of a printer model.
private struct DefaultSettingsEditor: View {
    @Environment(AppModel.self) private var app
    let model: PrinterModel
    @State private var settings = PrintSettings()

    var body: some View {
        AdvancedSettingsView(settings: $settings)
            .navigationTitle(model.displayName)
            .onAppear { settings = app.settings(for: model) }
            .onDisappear { app.remember(settings) }
    }
}
