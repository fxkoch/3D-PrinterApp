import ClaudeKit
import SwiftUI

/// Chat with Claude. Claude sees the app live (printers, open project, library) and can change
/// the project; printer commands and printing need a tap on „Ausführen“.
struct AssistantView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// Shown as a sheet (from the prepare screen) instead of a tab.
    var isSheet = false
    @State private var input = ""
    @State private var showSetup = false
    @FocusState private var inputFocused: Bool

    private var session: AssistantSession { app.assistant }

    var body: some View {
        NavigationStack {
            Group {
                if session.isConfigured {
                    chat
                } else {
                    setupHint
                }
            }
            .navigationTitle("Claude")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showSetup) { ClaudeSetupView() }
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Neues Gespräch", systemImage: "square.and.pencil") { session.reset() }
                            .disabled(session.entries.isEmpty)
                        Button("Einstellungen", systemImage: "gearshape") { showSetup = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("assistantMenu")
                }
            }
        }
    }

    // MARK: - Chat

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if session.entries.isEmpty { welcome }
                        ForEach(session.entries) { entry in
                            EntryView(entry: entry).id(entry.id)
                        }
                        if let pending = session.pendingConfirmation {
                            ConfirmationCard(confirmation: pending) { session.answer($0) }
                                .id("confirm")
                        }
                        if session.isRunning && session.pendingConfirmation == nil {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Claude denkt nach …").font(.footnote).foregroundStyle(.secondary)
                            }
                            .id("running")
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: session.entries.count) { _, _ in scrollToEnd(proxy) }
                .onChange(of: session.pendingConfirmation?.id) { _, _ in scrollToEnd(proxy) }
                .onChange(of: session.isRunning) { _, _ in scrollToEnd(proxy) }
            }
            Divider()
            inputBar
        }
        .background(Color(.systemGroupedBackground))
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if session.pendingConfirmation != nil {
                proxy.scrollTo("confirm", anchor: .bottom)
            } else if session.isRunning {
                proxy.scrollTo("running", anchor: .bottom)
            } else if let last = session.entries.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Frag mich alles rund um deinen Druck.", systemImage: "sparkles")
                .font(.headline)
            Text("Ich sehe live deine Drucker, das geöffnete Projekt und die Bibliothek – und kann Einstellungen, Material und Objekte direkt mit dir anpassen. Druckerbefehle führe ich nur aus, wenn du sie bestätigst.")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(suggestions, id: \.self) { s in
                Button {
                    session.send(s)
                } label: {
                    Text(s).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.bottom, 8)
    }

    private var suggestions: [String] {
        if app.project != nil {
            return ["Wie bekomme ich das Teil stabiler?", "Ist das gut druckbar? Was würdest du ändern?",
                    "Wie lange dauert der Druck und wie viel Filament brauche ich?"]
        }
        return ["Wie läuft mein Druck gerade?", "Ist mein Filament zu feucht?", "Finde mir einen Kabelhalter für den Schreibtisch"]
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Nachricht an Claude", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .accessibilityIdentifier("assistantInput")
            if session.isRunning {
                Button {
                    session.stop()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .accessibilityLabel("Stopp")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Senden")
                .accessibilityIdentifier("assistantSend")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let text = input
        input = ""
        session.send(text)
    }

    private var setupHint: some View {
        ContentUnavailableView {
            Label("Claude einrichten", systemImage: "sparkles")
        } description: {
            Text("Hinterlege deinen Anthropic-API-Schlüssel, dann kann Claude deine Drucker und Projekte live sehen und mitgestalten.")
        } actions: {
            NavigationLink("Jetzt einrichten") { ClaudeSetupView() }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Rows

private struct EntryView: View {
    let entry: AssistantSession.Entry

    var body: some View {
        switch entry.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
            }
        case .assistant(let text):
            Text(markdown(text))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let name, let state):
            let label = AssistantSession.label(for: name)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    switch state {
                    case .running: ProgressView().controlSize(.mini)
                    case .done: Image(systemName: label.icon).foregroundStyle(.secondary)
                    case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    Text(label.text)
                }
                if case .failed(let reason) = state {
                    Text(reason).lineLimit(3).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private struct ConfirmationCard: View {
    let confirmation: AssistantSession.Confirmation
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(confirmation.title, systemImage: "hand.raised.fill")
                .font(.headline)
            Text(confirmation.detail).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button("Ablehnen", role: .cancel) { answer(false) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Ausführen") { answer(true) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("assistantConfirm")
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.orange.opacity(0.6)))
    }
}
