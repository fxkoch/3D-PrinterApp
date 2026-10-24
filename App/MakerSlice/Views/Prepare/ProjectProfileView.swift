import SliceKit
import SwiftUI

/// Asks before taking over the print profile a downloaded model brings along (temperature towers, flow tests, ironing …).
struct ProjectProfileView: View {
    @Environment(\.dismiss) private var dismiss
    let project: PrintProject
    let report: ProfileReport
    @State private var selected: Set<String>
    @State private var showOther = false

    init(project: PrintProject, report: ProfileReport) {
        self.project = project
        self.report = report
        _selected = State(initialValue: Set(report.important.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(intro).font(.subheadline)
                    if report.foreignPrinter, let printer = report.printerName {
                        Label("Das Profil wurde für „\(printer)“ erstellt. Geschwindigkeiten und Beschleunigungen sind deshalb nicht vorgewählt – sie passen zu einem anderen Drucker.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                if !report.materialNotes.isEmpty {
                    Section {
                        ForEach(report.materialNotes, id: \.self) { Label($0, systemImage: "arrow.triangle.2.circlepath").font(.footnote) }
                    } header: {
                        Text("Automatisch an dein Filament angepasst")
                    }
                }
                if !report.important.isEmpty {
                    Section("Besonderheiten des Profils") {
                        ForEach(report.important) { row($0) }
                    }
                }
                if !report.other.isEmpty {
                    Section {
                        DisclosureGroup("Weitere Unterschiede (\(report.other.count))", isExpanded: $showOther) {
                            ForEach(report.other) { row($0) }
                        }
                    } footer: {
                        Text("Diese Werte weichen ab, sind aber meist nur vom Drucker des Autors geprägt. Sie sind nicht vorgewählt.")
                    }
                }
            }
            .navigationTitle("Druckprofil im Modell")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Nicht übernehmen") { project.dismissProfile(); dismiss() }.accessibilityIdentifier("profileDismiss")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(report.changes.isEmpty ? "Verstanden" : "Übernehmen (\(selected.count))") {
                        project.applyProfile(report.changes.filter { selected.contains($0.id) })
                        dismiss()
                    }
                    .disabled(selected.isEmpty && !report.changes.isEmpty)
                    .accessibilityIdentifier("profileApply")
                }
            }
        }
        .presentationDetents([.large])
    }

    private var intro: String {
        let name = report.profileName.map { "„\($0)“" } ?? "ein eigenes Druckprofil"
        return "Dieses Modell bringt \(name) mit. Unten stehen die Werte, die vom aktuellen Profil für \(project.settings.printer.displayName) abweichen – mit kurzer Erklärung. Wähle, was übernommen werden soll."
    }

    private func row(_ change: ProfileChange) -> some View {
        Toggle(isOn: Binding(get: { selected.contains(change.id) },
                             set: { if $0 { selected.insert(change.id) } else { selected.remove(change.id) } })) {
            VStack(alignment: .leading, spacing: 3) {
                Text(change.title).font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    Text(change.projectValue).foregroundStyle(Color.accentColor)
                    Text("statt \(change.currentValue)").foregroundStyle(.secondary)
                }
                .font(.footnote)
                Text(change.explanation).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
