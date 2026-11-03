import ClaudeKit
import Foundation
import Observation
import PrintAssistant

/// The chat with Claude: messages for the UI, the running turn and pending confirmations.
@MainActor
@Observable
final class AssistantSession {
    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable {
            case user(String)
            case assistant(String)
            case tool(name: String, state: ToolState)
            case error(String)
        }

        enum ToolState: Equatable {
            case running, done, failed(String)
        }

        let id: String
        var kind: Kind
    }

    struct Confirmation: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        fileprivate let answer: CheckedContinuation<Bool, Never>
    }

    private(set) var entries: [Entry] = []
    private(set) var isRunning = false
    private(set) var pendingConfirmation: Confirmation?
    /// Tokens of this chat (for the curious).
    private(set) var inputTokens = 0
    private(set) var outputTokens = 0
    private(set) var cacheReadTokens = 0

    var config: ClaudeConfig {
        didSet {
            guard config != oldValue else { return }
            ClaudeStore.save(config)
            conversation.client.config = config
        }
    }

    var isConfigured: Bool { config.isComplete }

    @ObservationIgnored private let toolbox: AssistantToolbox
    @ObservationIgnored private let conversation: ClaudeConversation
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        let config = ClaudeStore.load()
        self.config = config
        toolbox = AssistantToolbox(host: nil)
        conversation = ClaudeConversation(client: ClaudeClient(config: config), system: AssistantToolbox.systemPrompt,
                                          tools: AssistantToolbox.tools)
    }

    func attach(_ host: AssistantHost) {
        toolbox.host = host
    }

    // MARK: - Chat

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        entries.append(Entry(id: UUID().uuidString, kind: .user(trimmed)))
        isRunning = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await conversation.send(trimmed, runTool: { [toolbox] name, input in
                    await toolbox.run(name, input)
                }, onEvent: { [weak self] event in
                    self?.handle(event)
                })
            } catch is CancellationError {
                entries.append(Entry(id: UUID().uuidString, kind: .error("Abgebrochen.")))
            } catch {
                entries.append(Entry(id: UUID().uuidString, kind: .error(error.localizedDescription)))
            }
            // A turn that ended while a question was open: close it.
            answer(false)
            isRunning = false
            task = nil
        }
    }

    func stop() {
        task?.cancel()
        answer(false)
    }

    func reset() {
        stop()
        conversation.reset()
        entries = []
        inputTokens = 0
        outputTokens = 0
        cacheReadTokens = 0
    }

    private func handle(_ event: ConversationEvent) {
        switch event {
        case .text(let text):
            entries.append(Entry(id: UUID().uuidString, kind: .assistant(text)))
        case .toolStarted(let id, let name, _):
            entries.append(Entry(id: id, kind: .tool(name: name, state: .running)))
        case .toolFinished(let id, let name, let output):
            if let i = entries.lastIndex(where: { $0.id == id }) {
                entries[i].kind = .tool(name: name, state: output.isError ? .failed(output.content) : .done)
            }
        case .usage(let input, let output, let cacheRead):
            inputTokens += input
            outputTokens += output
            cacheReadTokens += cacheRead
        }
    }

    // MARK: - Confirmations (printer commands, printing)

    func confirm(title: String, detail: String) async -> Bool {
        answer(false) // only one open question at a time
        return await withCheckedContinuation { continuation in
            pendingConfirmation = Confirmation(title: title, detail: detail, answer: continuation)
        }
    }

    func answer(_ yes: Bool) {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        pending.answer.resume(returning: yes)
    }

    // MARK: - Labels

    static func label(for tool: String) -> (text: String, icon: String) {
        switch tool {
        case "get_overview": return ("Überblick gelesen", "square.grid.2x2")
        case "get_printer_status": return ("Druckerstatus gelesen", "printer")
        case "get_project": return ("Projekt gelesen", "cube")
        case "update_print_settings": return ("Einstellungen geändert", "slider.horizontal.3")
        case "list_filament_profiles": return ("Filamentprofile gesucht", "list.bullet")
        case "set_filament": return ("Material gesetzt", "circle.hexagongrid")
        case "edit_object": return ("Objekt bearbeitet", "rotate.3d")
        case "apply_recommendation": return ("Empfehlung übernommen", "checkmark.seal")
        case "slice": return ("Slicen", "square.stack.3d.up")
        case "select_printer": return ("Drucker ausgewählt", "printer")
        case "printer_command": return ("Druckerbefehl", "bolt")
        case "send_to_printer": return ("An Drucker senden", "paperplane")
        case "get_event_log": return ("Protokoll gelesen", "list.bullet.rectangle")
        case "list_library": return ("Bibliothek gelesen", "books.vertical")
        case "open_library_item": return ("Modell geöffnet", "folder")
        case "search_models": return ("Modelle gesucht", "magnifyingglass")
        case "download_model": return ("Modell geladen", "arrow.down.circle")
        default: return (tool, "wrench")
        }
    }
}
