import SliceKit
import PrinterKit
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
                    Text("Zeigt zusätzlich alle Slicer-Einstellungen mit Erklärungen, Filament-Werte, Cloud-Slicing und Gerätedetails. Ohne Expertenmodus bleibt die App bewusst einfach – die App wählt passende Werte selbst.")
                }
                NotificationSettingsSection()
                if app.expertMode {
                Section {
                    NavigationLink {
                        CloudSetupView()
                    } label: {
                        LabeledContent("OrcaSlicer in der Cloud", value: app.cloud.isComplete ? "Eingerichtet" : "Aus")
                    }
                } header: {
                    Text("Profi-Slicing")
                } footer: {
                    Text("Optional: slicet mit dem echten OrcaSlicer auf GitHub – gleiche Qualität wie am PC.")
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

/// Which printer events send a notification.
private struct NotificationSettingsSection: View {
    @State private var enabled = NotificationService.shared.enabled
    @State private var denied = false
    @State private var kinds: [PrintAlert.Kind: Bool] = Dictionary(uniqueKeysWithValues: PrintAlert.Kind.allCases.map { ($0, NotificationService.shared.isOn($0)) })

    private static let names: [PrintAlert.Kind: String] = [
        .finished: "Druck fertig", .failed: "Fehler", .paused: "Pause", .filament: "Filamentproblem", .cancelled: "Abbruch",
    ]

    var body: some View {
        Section {
            Toggle("Mitteilungen", isOn: $enabled)
                .accessibilityIdentifier("notifyToggle")
                .onChange(of: enabled) { _, on in
                    NotificationService.shared.enabled = on
                    guard on else { return }
                    Task {
                        let ok = await NotificationService.shared.requestPermission()
                        denied = !ok
                        if !ok { enabled = false; NotificationService.shared.enabled = false } else { NotificationService.shared.scheduleRefresh() }
                    }
                }
            if enabled {
                ForEach(PrintAlert.Kind.allCases, id: \.self) { kind in
                    Toggle(Self.names[kind] ?? kind.rawValue, isOn: Binding(
                        get: { kinds[kind] ?? true },
                        set: { kinds[kind] = $0; NotificationService.shared.set(kind, $0) }))
                }
                Button("Testmitteilung senden") { NotificationService.shared.sendTest() }
                    .accessibilityIdentifier("notifyTest")
            }
            if denied { Text("Mitteilungen sind für MakerSlice in den iPhone-Einstellungen ausgeschaltet.").font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Benachrichtigungen")
        } footer: {
            Text("Bei geöffneter App kommt die Mitteilung sofort. Im Hintergrund fragt iOS die Drucker nur etwa alle 15–30 Minuten ab – eine fertige oder gestörte Druckerei kann also verzögert gemeldet werden. Sofortige Push-Mitteilungen bei geschlossener App brauchen einen Server und ein bezahltes Entwicklerkonto.")
        }
    }
}
