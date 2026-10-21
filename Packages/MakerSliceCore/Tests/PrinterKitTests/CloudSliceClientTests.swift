import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PrinterKit
import XCTest

/// Runs the cloud-slice client against an in-memory fake of the GitHub API, including a fake
/// workflow run that "slices" the uploaded job.
final class CloudSliceClientTests: XCTestCase {
    override func tearDown() {
        FakeGitHub.reset()
    }

    func client() -> CloudSliceClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGitHub.self]
        let c = CloudSliceClient(config: CloudSliceConfig(repository: "me/printer", token: "t0k"),
                                 session: URLSession(configuration: config))
        c.pollInterval = 0.01
        return c
    }

    func testFullRoundTrip() async throws {
        let result = try await client().slice(jobID: "job-1", files: [("job.json", Data("{}".utf8)), ("model.3mf", Data([1, 2, 3]))])
        XCTAssertEqual(String(decoding: result.gcode, as: UTF8.self), "; sliced job-1\nG1 X1\n")
        XCTAssertEqual(result.seconds, 3723)
        XCTAssertEqual(result.filamentGrams ?? 0, 12.5, accuracy: 0.001)
        let files = FakeGitHub.state.withLock { $0.files }
        XCTAssertEqual(files["jobs/job-1/model.3mf"], Data([1, 2, 3]))
        XCTAssertTrue(FakeGitHub.state.withLock { $0.authorized })
    }

    func testFailedRunReportsOrcaError() async throws {
        FakeGitHub.state.withLock { $0.failSlice = true }
        do {
            _ = try await client().slice(jobID: "job-2", files: [("job.json", Data("{}".utf8))])
            XCTFail("should fail")
        } catch let error as CloudSliceError {
            XCTAssertTrue(error.localizedDescription.contains("OrcaSlicer hat keinen G-Code"), error.localizedDescription)
        }
    }

    func testMissingWorkflow() async {
        FakeGitHub.state.withLock { $0.hasWorkflow = false }
        do {
            _ = try await client().verify()
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? CloudSliceError, .workflowMissing)
        }
    }
}

final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

final class FakeGitHub: URLProtocol {
    struct State {
        var refs: [String: String] = ["main": "c0"]
        var commits: [String: (tree: String, files: [String: Data])] = ["c0": ("t0", [:])]
        var trees: [String: [String: Data]] = ["t0": [:]]
        var blobs: [String: Data] = [:]
        var files: [String: Data] = [:]
        var runs: [[String: Any]] = []
        var hasWorkflow = true
        var failSlice = false
        var authorized = false
        var counter = 0
        mutating func id(_ prefix: String) -> String { counter += 1; return "\(prefix)\(counter)" }
    }
    static let state = Locked(State())
    static func reset() { state.withLock { $0 = State() } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (code, body) = Self.handle(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    static func bodyJSON(_ request: URLRequest) -> [String: Any] {
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
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func json(_ object: Any, _ code: Int = 200) -> (Int, Data) {
        (code, (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    static func handle(_ request: URLRequest) -> (Int, Data) {
        let url = request.url!
        let path = url.path.replacingOccurrences(of: "/repos/me/printer", with: "")
        let method = request.httpMethod ?? "GET"
        let query = url.query ?? ""
        return state.withLock { s -> (Int, Data) in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k" { s.authorized = true } else { return json(["message": "Bad credentials"], 401) }
            switch (method, path) {
            case ("GET", ""):
                return json(["default_branch": "main"])
            case ("GET", "/contents/.github/workflows/cloud-slice.yml"):
                return s.hasWorkflow ? json(["name": "cloud-slice.yml"]) : json(["message": "Not Found"], 404)
            case ("GET", let p) where p.hasPrefix("/git/ref/heads/"):
                let name = String(p.dropFirst("/git/ref/heads/".count))
                guard let sha = s.refs[name] else { return json(["message": "Not Found"], 404) }
                return json(["object": ["sha": sha]])
            case ("POST", "/git/refs"):
                let b = bodyJSON(request)
                let ref = (b["ref"] as! String).replacingOccurrences(of: "refs/heads/", with: "")
                s.refs[ref] = b["sha"] as? String
                return json(["ref": ref], 201)
            case ("POST", "/git/blobs"):
                let b = bodyJSON(request)
                let sha = s.id("b")
                s.blobs[sha] = Data(base64Encoded: b["content"] as! String)
                return json(["sha": sha], 201)
            case ("GET", let p) where p.hasPrefix("/git/commits/"):
                let sha = String(p.dropFirst("/git/commits/".count))
                return json(["tree": ["sha": s.commits[sha]!.tree]])
            case ("POST", "/git/trees"):
                let b = bodyJSON(request)
                var files = s.trees[b["base_tree"] as! String] ?? [:]
                for entry in b["tree"] as! [[String: Any]] {
                    files[entry["path"] as! String] = s.blobs[entry["sha"] as! String]
                }
                let sha = s.id("t")
                s.trees[sha] = files
                return json(["sha": sha], 201)
            case ("POST", "/git/commits"):
                let b = bodyJSON(request)
                let sha = s.id("c")
                let tree = b["tree"] as! String
                s.commits[sha] = (tree, s.trees[tree] ?? [:])
                return json(["sha": sha], 201)
            case ("PATCH", "/git/refs/heads/slice-jobs"):
                let sha = bodyJSON(request)["sha"] as! String
                s.refs["slice-jobs"] = sha
                s.files = s.commits[sha]!.files
                return json(["ok": true])
            case ("POST", "/actions/workflows/cloud-slice.yml/dispatches"):
                let b = bodyJSON(request)
                guard b["ref"] as? String == "main", let job = (b["inputs"] as? [String: Any])?["job_id"] as? String else {
                    return json(["message": "bad dispatch"], 422)
                }
                // The "workflow": slices immediately.
                if s.failSlice {
                    s.files["jobs/\(job)/result.json"] = Data(#"{"ok": false, "error": "OrcaSlicer hat keinen G-Code erzeugt (Code 1)."}"#.utf8)
                } else {
                    s.files["jobs/\(job)/result.gcode"] = Data("; sliced \(job)\nG1 X1\n".utf8)
                    s.files["jobs/\(job)/result.json"] = Data(#"{"ok": true, "seconds": 3723, "filament_g": "10.0, 2.5"}"#.utf8)
                }
                s.runs.insert(["display_title": "Cloud slice \(job)", "status": "completed",
                               "conclusion": s.failSlice ? "failure" : "success", "html_url": "https://example/run"], at: 0)
                return (204, Data())
            case ("GET", "/actions/workflows/cloud-slice.yml/runs"):
                return json(["workflow_runs": s.runs])
            case ("GET", let p) where p.hasPrefix("/contents/jobs/"):
                guard query.contains("ref=slice-jobs"), request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw",
                      let data = s.files[String(p.dropFirst("/contents/".count))] else { return json(["message": "Not Found"], 404) }
                return (200, data)
            default:
                return json(["message": "unexpected \(method) \(path)"], 500)
            }
        }
    }
}
