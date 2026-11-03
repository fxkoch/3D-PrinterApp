import ClaudeKit
import SwiftUI

/// API key, model and depth for the Claude assistant, with a connection test.
struct ClaudeSetupView: View {
    @Environment(AppModel.self) private var app
    @State private var key = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    var body: some View {
        @Bindable var session = app.assistant
        Form {
            Section {
                SecureField("sk-ant-…", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("claudeKey")
                Button(testing ? "Teste …" : "Speichern und testen") { saveAndTest() }
                    .disabled(testing || key.trimmingCharacters(in: .whitespaces).isEmpty)
                if let testResult {
                    Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(testOK ? Color.green : Color.orange)
                        .font(.footnote)
                }
            } header: {
                Text("API-Schlüssel")
            } footer: {
                Text("Erstelle einen Schlüssel unter console.anthropic.com → API Keys. Er wird nur im Schlüsselbund dieses iPhones gespeichert. Die Nutzung wird über dein Anthropic-Konto abgerechnet.")
            }
            Section {
                Picker("Modell", selection: $session.config.model) {
                    ForEach(ClaudeModel.allCases) { model in
                        VStack(alignment: .leading) {
                            Text(model.displayName)
                            Text(model.note).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(model)
                    }
                }
                .pickerStyle(.inline)
                Picker("Gründlichkeit", selection: $session.config.effort) {
                    Text("Schnell").tag("low")
                    Text("Ausgewogen").tag("medium")
                    Text("Gründlich").tag("high")
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Modell")
            } footer: {
                Text("„Gründlich“ denkt länger nach – sinnvoll für knifflige Druckprobleme, kostet aber mehr Zeit und Tokens.")
            }
            Section("Was Claude sieht und darf") {
                Label("Live-Status deiner Drucker, das geöffnete Projekt mit allen Einstellungen, Bibliothek und Protokoll", systemImage: "eye")
                Label("Einstellungen, Material und Objekte im Projekt ändern, slicen, Modelle auf Printables suchen und laden", systemImage: "wand.and.stars")
                Label("Druckerbefehle und Drucken nur nach deiner Bestätigung im Chat", systemImage: "hand.raised")
                Label("Gesendet werden nur die Daten, die Claude für deine Frage abruft – an die Anthropic-API, nicht an Dritte", systemImage: "lock")
            }
            .font(.footnote)
            if session.inputTokens > 0 {
                Section("Dieses Gespräch") {
                    LabeledContent("Eingabe-Tokens", value: "\(session.inputTokens)")
                    LabeledContent("Davon aus dem Cache", value: "\(session.cacheReadTokens)")
                    LabeledContent("Ausgabe-Tokens", value: "\(session.outputTokens)")
                }
            }
            if session.isConfigured {
                Section {
                    Button("Schlüssel entfernen", role: .destructive) {
                        key = ""
                        session.config.apiKey = ""
                        testResult = nil
                    }
                }
            }
        }
        .navigationTitle("Claude-Assistent")
        .onAppear { key = app.assistant.config.apiKey }
    }

    private func saveAndTest() {
        app.assistant.config.apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        testing = true
        testResult = nil
        let client = ClaudeClient(config: app.assistant.config)
        Task {
            defer { testing = false }
            do {
                _ = try await client.send(system: "Antworte nur mit OK.", tools: [],
                                          messages: [["role": "user", "content": "Verbindungstest"]])
                testOK = true
                testResult = "Verbunden mit \(app.assistant.config.model.displayName)."
            } catch {
                testOK = false
                testResult = error.localizedDescription
            }
        }
    }
}
