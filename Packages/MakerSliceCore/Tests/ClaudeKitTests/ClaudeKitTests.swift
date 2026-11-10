@testable import ClaudeKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

/// Runs the client and the tool loop against an in-memory fake of the Messages API.
final class ClaudeKitTests: XCTestCase {
    override func tearDown() {
        FakeClaude.reset()
    }

    func client(model: ClaudeModel = .opus) -> ClaudeClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeClaude.self]
        let c = ClaudeClient(config: ClaudeConfig(apiKey: "sk-test", model: model), session: URLSession(configuration: config))
        c.retryDelays = [0.01, 0.01]
        return c
    }

    func testRequestShape() async throws {
        FakeClaude.enqueue(200, FakeClaude.reply([["type": "text", "text": "Hallo!"]]))
        let response = try await client().send(system: "sys", tools: [], messages: [["role": "user", "content": "Hi"]])
        XCTAssertEqual(response.text, "Hallo!")
        let req = try XCTUnwrap(FakeClaude.requests.first)
        XCTAssertEqual(req.headers["x-api-key"], "sk-test")
        XCTAssertEqual(req.headers["anthropic-version"], "2026-10-21")
        XCTAssertEqual(req.headers["anthropic-beta"], "server-side-fallback-2026-07-01")
        XCTAssertEqual(req.body["model"]?.string, "claude-opus-5-5")
        XCTAssertEqual(req.body["max_tokens"]?.int, 16000)
        XCTAssertEqual(req.body["fallbacks"]?.string, "default")
        XCTAssertEqual(req.body["output_config"]?["effort"]?.string, "medium")
        XCTAssertEqual(req.body["cache_control"]?["type"]?.string, "ephemeral")
        XCTAssertNil(req.body["thinking"], "Opus 5.5 thinks adaptively; disabling it is a 400")
        XCTAssertNil(req.body["tools"])
        XCTAssertTrue(req.raw.contains("\"max_tokens\":16000"), "integers must not be sent as 16000.0")
    }

    func testHaikuHasNoFallback() async throws {
        FakeClaude.enqueue(200, FakeClaude.reply([["type": "text", "text": "ok"]]))
        _ = try await client(model: .haiku).send(system: "s", tools: [], messages: [["role": "user", "content": "x"]])
        let req = try XCTUnwrap(FakeClaude.requests.first)
        XCTAssertNil(req.body["fallbacks"])
        XCTAssertNil(req.headers["anthropic-beta"])
    }

    func testErrorsAndRetry() async throws {
        FakeClaude.enqueue(529, ["type": "error", "error": ["type": "overloaded_error", "message": "busy"]])
        FakeClaude.enqueue(200, FakeClaude.reply([["type": "text", "text": "zweiter Versuch"]]))
        let r = try await client().send(system: "s", tools: [], messages: [["role": "user", "content": "x"]])
        XCTAssertEqual(r.text, "zweiter Versuch")
        XCTAssertEqual(FakeClaude.requests.count, 2)

        FakeClaude.reset()
        FakeClaude.enqueue(401, ["type": "error", "error": ["type": "authentication_error", "message": "bad key"]])
        do {
            _ = try await client().send(system: "s", tools: [], messages: [["role": "user", "content": "x"]])
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? ClaudeError, .unauthorized)
        }
        XCTAssertEqual(FakeClaude.requests.count, 1, "401 is not retried")
    }

    func testMissingKey() async {
        let c = ClaudeClient(config: ClaudeConfig(apiKey: "  "))
        do {
            _ = try await c.send(system: "s", tools: [], messages: [])
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? ClaudeError, .missingKey)
        }
    }

    @MainActor
    func testToolLoopKeepsHistoryVerbatim() async throws {
        let thinking: JSONValue = ["type": "thinking", "thinking": "", "signature": "sig-123"]
        FakeClaude.enqueue(200, FakeClaude.reply([
            thinking,
            ["type": "text", "text": "Ich schaue nach."],
            ["type": "tool_use", "id": "toolu_1", "name": "get_temp", "input": ["printer": "U1"]],
            ["type": "tool_use", "id": "toolu_2", "name": "get_temp", "input": ["printer": "Kobra"]],
        ], stop: "tool_use"))
        FakeClaude.enqueue(200, FakeClaude.reply([["type": "text", "text": "U1: 60 °C, Kobra: 25 °C"]]))

        let tool = ClaudeTool(name: "get_temp", description: "d", inputSchema: ["type": "object"])
        let conv = ClaudeConversation(client: client(), system: "sys", tools: [tool])
        var events: [ConversationEvent] = []
        try await conv.send("Wie warm sind die Betten?", runTool: { name, input in
            XCTAssertEqual(name, "get_temp")
            return input["printer"]?.string == "U1" ? ToolOutput("60") : ToolOutput("25")
        }, onEvent: { events.append($0) })

        XCTAssertEqual(FakeClaude.requests.count, 2)
        let second = try XCTUnwrap(FakeClaude.requests.last?.body["messages"]?.array)
        XCTAssertEqual(second.count, 3)
        // The assistant turn is sent back unchanged, thinking block included.
        XCTAssertEqual(second[1]["content"]?.array?.first, thinking)
        // Both results in ONE user message, in order.
        let results = try XCTUnwrap(second[2]["content"]?.array)
        XCTAssertEqual(results.map { $0["tool_use_id"]?.string }, ["toolu_1", "toolu_2"])
        XCTAssertEqual(results.map { $0["content"]?.string }, ["60", "25"])
        XCTAssertEqual(FakeClaude.requests.last?.body["tools"]?.array?.first?["name"]?.string, "get_temp")

        XCTAssertEqual(conv.messages.count, 4)
        XCTAssertTrue(events.contains(.text("U1: 60 °C, Kobra: 25 °C")))
        XCTAssertEqual(events.filter { if case .toolFinished = $0 { return true } else { return false } }.count, 2)
    }

    @MainActor
    func testFailedTurnIsForgotten() async throws {
        FakeClaude.enqueue(400, ["type": "error", "error": ["type": "invalid_request_error", "message": "nope"]])
        let conv = ClaudeConversation(client: client(), system: "s", tools: [])
        do {
            try await conv.send("Hallo", runTool: { _, _ in ToolOutput("") }, onEvent: { _ in })
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? ClaudeError, .badRequest("nope"))
        }
        XCTAssertTrue(conv.messages.isEmpty)
    }

    @MainActor
    func testRefusalIsReported() async throws {
        FakeClaude.enqueue(200, ["id": "m", "model": "claude-opus-5-5", "content": [], "stop_reason": "refusal",
                                 "stop_details": ["type": "refusal", "category": "cyber"], "usage": ["input_tokens": 1, "output_tokens": 0]])
        let conv = ClaudeConversation(client: client(), system: "s", tools: [])
        do {
            try await conv.send("x", runTool: { _, _ in ToolOutput("") }, onEvent: { _ in })
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? ClaudeError, .refused("cyber"))
        }
        XCTAssertTrue(conv.messages.isEmpty)
    }

    @MainActor
    func testStepLimitThenContinue() async throws {
        let call: JSONValue = ["type": "tool_use", "id": "t", "name": "x", "input": [:]]
        FakeClaude.enqueue(200, FakeClaude.reply([call], stop: "tool_use"))
        FakeClaude.enqueue(200, FakeClaude.reply([["type": "text", "text": "fertig"]]))
        let conv = ClaudeConversation(client: client(), system: "s", tools: [ClaudeTool(name: "x", description: "", inputSchema: ["type": "object"])])
        conv.maxSteps = 1
        try await conv.send("los", runTool: { _, _ in ToolOutput("ok") }, onEvent: { _ in })
        // History ends with the pending tool result; the next message is merged into it.
        XCTAssertEqual(conv.messages.last?["role"]?.string, "user")
        try await conv.send("weiter", runTool: { _, _ in ToolOutput("ok") }, onEvent: { _ in })
        let sent = try XCTUnwrap(FakeClaude.requests.last?.body["messages"]?.array)
        XCTAssertEqual(sent.map { $0["role"]?.string }, ["user", "assistant", "user"])
        XCTAssertEqual(sent[2]["content"]?.array?.map { $0["type"]?.string }, ["tool_result", "text"])
    }

    func testJSONValueRoundTrip() throws {
        let json = #"{"a":[1,2.5,true,null,"x"],"b":{"c":false}}"#
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(v["a"]?.array?[0], .number(1))
        XCTAssertEqual(v["a"]?.array?[2], .bool(true))
        XCTAssertEqual(v["b"]?["c"], .bool(false))
        XCTAssertEqual(v.jsonString, json)
    }
}

// MARK: - Fake API

final class FakeClaude: URLProtocol {
    struct Recorded {
        var headers: [String: String]
        var body: JSONValue
        var raw: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [(Int, JSONValue)] = []
    nonisolated(unsafe) private static var recorded: [Recorded] = []

    static var requests: [Recorded] { lock.lock(); defer { lock.unlock() }; return recorded }

    static func enqueue(_ status: Int, _ body: JSONValue) {
        lock.lock(); queue.append((status, body)); lock.unlock()
    }

    static func reset() {
        lock.lock(); queue = []; recorded = []; lock.unlock()
    }

    static func reply(_ content: [JSONValue], stop: String = "end_turn") -> JSONValue {
        ["id": "msg_1", "type": "message", "role": "assistant", "model": "claude-opus-5-5", "content": .array(content),
         "stop_reason": .string(stop), "usage": ["input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 3]]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
        }
        var headers: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] { headers[k.lowercased()] = v }
        let body = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        Self.lock.lock()
        Self.recorded.append(Recorded(headers: headers, body: body, raw: String(decoding: data, as: UTF8.self)))
        let next = Self.queue.isEmpty ? (500, ["error": ["message": "no fake response queued"]] as JSONValue) : Self.queue.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.0, httpVersion: "HTTP/1.1",
                                       headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONEncoder().encode(next.1)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
