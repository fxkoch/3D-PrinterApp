import PrinterKit
import SwiftUI

/// Sets up slicing with the real OrcaSlicer on GitHub Actions (free for personal repositories).
struct CloudSetupView: View {
    @Environment(AppModel.self) private var app
    @State private var config = CloudSliceConfig()
    @State private var checking = false
    @State private var result: String?
    @State private var ok = false

    var body: some View {
        Form {
            Section {
                Text("Für knifflige Modelle kann MakerSlice den echten OrcaSlicer nutzen – er läuft kostenlos auf einem GitHub-Rechner. Die App lädt das Modell mit deinen Einstellungen hoch, OrcaSlicer rechnet mit den offiziellen Profilen von Snapmaker bzw. Anycubic und der fertige G-Code kommt zurück aufs iPhone (ca. 1–3 Minuten).")
                    .font(.callout)
            }
            Section {
                TextField("Repository (Besitzer/Name)", text: $config.repository)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("cloudRepo")
                SecureField("Zugangs-Token", text: $config.token)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("cloudToken")
                TextField("Branch mit dem Workflow (leer = Standard)", text: $config.workflowBranch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("GitHub")
            } footer: {
                Text("Der Token wird nur im Schlüsselbund dieses iPhones gespeichert.")
            }
            Section {
                Button {
                    Task { await check() }
                } label: {
                    if checking { ProgressView() } else { Label("Verbindung prüfen", systemImage: "checkmark.shield") }
                }
                .disabled(!config.isComplete || checking)
                if let result {
                    Label(result, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ok ? .green : .orange)
                        .font(.callout)
                }
            }
            Section("So richtest du es ein (einmalig)") {
                step(1, "Das Repository mit MakerSlice liegt in deinem GitHub-Konto (z. B. „fxkoch/3D-PrinterApp“). Der Workflow „Cloud slice“ ist schon enthalten.")
                step(2, "Auf github.com: Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token.")
                step(3, "Nur dieses Repository auswählen. Berechtigungen: „Contents“ und „Actions“ jeweils Read and write. Ablaufdatum nach Wunsch.")
                step(4, "Token kopieren, oben einfügen, „Verbindung prüfen“ tippen.")
                step(5, "Beim Vorbereiten erscheint nun die Wahl „iPhone“ oder „OrcaSlicer (Cloud)“.")
            }
            Section("Gut zu wissen") {
                Text("• Für private Repositories sind 2000 Minuten pro Monat kostenlos, öffentliche unbegrenzt. Ein Auftrag dauert meist 1–3 Minuten.")
                Text("• Aufträge liegen im Branch „slice-jobs“ und werden nach drei Tagen automatisch gelöscht.")
                Text("• Ohne Internet oder bei einfachen Teilen ist der iPhone-Slicer schneller.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Profi-Slicing")
        .onAppear { config = app.cloud }
        .onDisappear { app.cloud = config }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.caption.weight(.bold)).frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            Text(text).font(.callout)
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        app.cloud = config
        do {
            let branch = try await CloudSliceClient(config: config).verify()
            ok = true
            result = "Bereit – Workflow gefunden (Branch „\(branch)“)."
        } catch {
            ok = false
            result = error.localizedDescription
        }
    }
}
