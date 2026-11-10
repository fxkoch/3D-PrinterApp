import Foundation

/// A tool Claude may call. The app executes it and returns the result.
public struct ClaudeTool: Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    var definition: JSONValue {
        ["name": .string(name), "description": .string(description), "input_schema": inputSchema]
    }
}

public struct ToolOutput: Sendable, Equatable {
    public var content: String
    public var isError: Bool

    public init(_ content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func error(_ message: String) -> ToolOutput { ToolOutput(message, isError: true) }
}

/// What happens during one turn, for the chat UI.
public enum ConversationEvent: Sendable, Equatable {
    case text(String)
    case toolStarted(id: String, name: String, input: JSONValue)
    case toolFinished(id: String, name: String, output: ToolOutput)
    case usage(input: Int, output: Int, cacheRead: Int)
}

/// A chat with Claude that can use the app's tools. The message history is append-only:
/// every assistant turn is stored exactly as returned (including thinking blocks), which
/// keeps prompt caching effective and satisfies the API's history checks.
@MainActor
public final class ClaudeConversation {
    public typealias ToolRunner = @MainActor (_ name: String, _ input: JSONValue) async -> ToolOutput

    public let client: ClaudeClient
    public var system: String
    public let tools: [ClaudeTool]
    /// Maximum API calls per user message (each tool round is one call).
    public var maxSteps = 16
    public private(set) var messages: [JSONValue] = []

    public init(client: ClaudeClient, system: String, tools: [ClaudeTool]) {
        self.client = client
        self.system = system
        self.tools = tools
    }

    public func reset() {
        messages = []
    }

    /// Sends a user message and runs tool calls until Claude has answered.
    public func send(_ text: String, runTool: ToolRunner, onEvent: @MainActor (ConversationEvent) -> Void) async throws {
        let before = messages
        var answered = false
        appendUser([["type": "text", "text": .string(text)]])
        let toolDefs = tools.map(\.definition)

        do {
            for _ in 0..<maxSteps {
                try Task.checkCancellation()
                let response = try await client.send(system: system, tools: toolDefs, messages: messages)
                onEvent(.usage(input: response.inputTokens, output: response.outputTokens, cacheRead: response.cacheReadTokens))

                if response.stopReason == "refusal" {
                    throw ClaudeError.refused(response.stopDetails?["category"]?.string)
                }
                guard !response.content.isEmpty else { return }
                messages.append(["role": "assistant", "content": .array(response.content)])
                answered = true
                let said = response.text
                if !said.isEmpty { onEvent(.text(said)) }

                let calls = response.toolUses
                if calls.isEmpty {
                    if response.stopReason == "pause_turn" { continue }
                    return
                }
                // Every tool_use needs a tool_result in the next (single) user message.
                var results: [JSONValue] = []
                for call in calls {
                    onEvent(.toolStarted(id: call.id, name: call.name, input: call.input))
                    let output: ToolOutput
                    if response.stopReason == "tool_use" {
                        output = await runTool(call.name, call.input)
                    } else {
                        output = .error("Der Aufruf wurde abgeschnitten (\(response.stopReason ?? "?")). Bitte erneut aufrufen.")
                    }
                    onEvent(.toolFinished(id: call.id, name: call.name, output: output))
                    var block: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(call.id),
                                                      "content": .string(output.content)]
                    if output.isError { block["is_error"] = true }
                    results.append(.object(block))
                }
                appendUser(results)
            }
            onEvent(.text("(Ich habe die maximale Anzahl an Schritten erreicht. Schreib „weiter“, dann mache ich weiter.)"))
        } catch {
            // Nothing was answered: forget the message so a retry starts clean.
            if !answered { messages = before }
            throw error
        }
    }

    /// Adds user content; merges into a trailing user message (pending tool results) if there is one.
    private func appendUser(_ blocks: [JSONValue]) {
        if let last = messages.last, last["role"]?.string == "user", case .array(let existing)? = last["content"] {
            messages[messages.count - 1] = ["role": "user", "content": .array(existing + blocks)]
        } else {
            messages.append(["role": "user", "content": .array(blocks)])
        }
    }
}
