import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Models offered in the app. Opus 5.5 is the default.
public enum ClaudeModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .opus: return "Claude Opus 5.5"
        case .sonnet: return "Claude Sonnet 5.5"
        case .haiku: return "Claude Haiku 5.5"
        }
    }

    public var note: String {
        switch self {
        case .opus: return "Am klügsten – Standard"
        case .sonnet: return "Schneller und günstiger"
        case .haiku: return "Am schnellsten und günstigsten"
        }
    }

    /// Server-side fallback on a safety decline (`fallbacks: "default"`); Haiku has none.
    var supportsServerFallback: Bool { self != .haiku }
}

public struct ClaudeConfig: Sendable, Equatable {
    public var apiKey: String
    public var model: ClaudeModel
    /// "low" … "max". Medium keeps chat answers quick.
    public var effort: String
    public var maxTokens: Int
    public var baseURL: URL

    public init(apiKey: String, model: ClaudeModel = .opus, effort: String = "medium", maxTokens: Int = 16000,
                baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
        self.baseURL = baseURL
    }

    public var isComplete: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public struct ClaudeResponse: Sendable, Equatable {
    public var id: String
    public var model: String
    public var stopReason: String?
    /// Content blocks exactly as returned (sent back unchanged in the next request).
    public var content: [JSONValue]
    public var stopDetails: JSONValue?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int

    public var text: String {
        content.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n\n")
    }

    public var toolUses: [(id: String, name: String, input: JSONValue)] {
        content.compactMap { block in
            guard block["type"]?.string == "tool_use", let id = block["id"]?.string, let name = block["name"]?.string else { return nil }
            return (id, name, block["input"] ?? .object([:]))
        }
    }
}

public enum ClaudeError: LocalizedError, Equatable, Sendable {
    case missingKey
    case unauthorized
    case rateLimited
    case overloaded
    case badRequest(String)
    case server(Int, String)
    case network(String)
    case refused(String?)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "Kein API-Schlüssel hinterlegt. Trage ihn unter Einstellungen → Claude-Assistent ein."
        case .unauthorized: return "Der API-Schlüssel wurde abgelehnt. Bitte in den Einstellungen prüfen."
        case .rateLimited: return "Zu viele Anfragen – bitte kurz warten und erneut versuchen."
        case .overloaded: return "Claude ist gerade überlastet. Bitte gleich noch einmal versuchen."
        case .badRequest(let m): return "Anfrage abgelehnt: \(m)"
        case .server(let code, let m): return "Serverfehler \(code): \(m)"
        case .network(let m): return "Keine Verbindung zu Claude: \(m)"
        case .refused(let category):
            return "Claude hat diese Anfrage aus Sicherheitsgründen nicht beantwortet" + (category.map { " (\($0))" } ?? "") + "."
        case .invalidResponse: return "Unerwartete Antwort von Claude."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .network: return true
        case .server(let code, _): return code >= 500
        default: return false
        }
    }
}

/// Minimal client for the Claude Messages API (`POST /v1/messages`).
/// Swift has no official Anthropic SDK, so this speaks the REST API directly.
public final class ClaudeClient: @unchecked Sendable {
    public static let apiVersion = "2026-10-21"
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    public var config: ClaudeConfig
    private let session: URLSession
    /// Delays before retrying 429 / 5xx / network errors.
    public var retryDelays: [Double] = [1, 4]

    public init(config: ClaudeConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Builds the request body. `system` and `tools` are kept byte-stable so the prefix is cached.
    public func body(system: String, tools: [JSONValue], messages: [JSONValue]) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(config.model.rawValue),
            "max_tokens": .number(Double(config.maxTokens)),
            "system": [["type": "text", "text": .string(system)]],
            "messages": .array(messages),
            "output_config": ["effort": .string(config.effort)],
            // Caches the growing conversation automatically (last cacheable block).
            "cache_control": ["type": "ephemeral"],
        ]
        if !tools.isEmpty { body["tools"] = .array(tools) }
        if config.model.supportsServerFallback { body["fallbacks"] = "default" }
        return .object(body)
    }

    public func send(system: String, tools: [JSONValue], messages: [JSONValue]) async throws -> ClaudeResponse {
        guard config.isComplete else { throw ClaudeError.missingKey }
        var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if config.model.supportsServerFallback { request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.httpBody = try encoder.encode(body(system: system, tools: tools, messages: messages))

        var attempt = 0
        while true {
            do {
                return try await perform(request)
            } catch let error as ClaudeError where error.isRetryable && attempt < retryDelays.count {
                try await Task.sleep(nanoseconds: UInt64(retryDelays[attempt] * 1_000_000_000))
                attempt += 1
            }
        }
    }

    private func perform(_ request: URLRequest) async throws -> ClaudeResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw ClaudeError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        guard (200..<300).contains(status) else {
            let message = json["error"]?["message"]?.string ?? String(decoding: data.prefix(300), as: UTF8.self)
            switch status {
            case 401, 403: throw ClaudeError.unauthorized
            case 429: throw ClaudeError.rateLimited
            case 529: throw ClaudeError.overloaded
            case 400..<500: throw ClaudeError.badRequest(message)
            default: throw ClaudeError.server(status, message)
            }
        }
        guard let content = json["content"]?.array else { throw ClaudeError.invalidResponse }
        let usage = json["usage"]
        return ClaudeResponse(id: json["id"]?.string ?? "", model: json["model"]?.string ?? "",
                              stopReason: json["stop_reason"]?.string, content: content,
                              stopDetails: json["stop_details"],
                              inputTokens: usage?["input_tokens"]?.int ?? 0,
                              outputTokens: usage?["output_tokens"]?.int ?? 0,
                              cacheReadTokens: usage?["cache_read_input_tokens"]?.int ?? 0)
    }
}
