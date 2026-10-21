import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where cloud slicing runs: the user's own GitHub repository with the cloud-slice workflow.
public struct CloudSliceConfig: Codable, Equatable, Sendable {
    /// "owner/repo"
    public var repository: String
    /// Fine-grained token with Contents + Actions read/write on that repository.
    public var token: String
    /// Branch that contains .github/workflows/cloud-slice.yml (empty = repository default).
    public var workflowBranch: String

    public init(repository: String = "", token: String = "", workflowBranch: String = "") {
        self.repository = repository
        self.token = token
        self.workflowBranch = workflowBranch
    }

    public var isComplete: Bool {
        repository.split(separator: "/").count == 2 && !token.isEmpty
    }
}

public enum CloudSliceError: Error, LocalizedError, Equatable {
    case notConfigured
    case http(Int, String)
    case workflowMissing
    case failed(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Cloud-Slicing ist nicht eingerichtet (Einstellungen → Cloud-Slicing)."
        case .http(401, _), .http(403, _):
            return "GitHub verweigert den Zugriff. Token prüfen: Rechte „Contents“ und „Actions“ (Lesen & Schreiben) für das Repository."
        case .http(404, let what): return "Nicht gefunden auf GitHub: \(what)"
        case .http(let code, let message): return "GitHub-Fehler \(code): \(message)"
        case .workflowMissing: return "Im Repository fehlt der Workflow „cloud-slice.yml“ (auf dem gewählten Branch)."
        case .failed(let message): return message
        case .timeout: return "Der Cloud-Slicer hat nicht rechtzeitig geantwortet."
        }
    }
}

public struct CloudSliceResult: Sendable {
    public var gcode: Data
    public var seconds: Double?
    public var filamentGrams: Double?
    public var warnings: [String]
    public var runURL: String?
}

/// Uploads a job to the `slice-jobs` branch, starts the workflow and downloads the G-code.
public final class CloudSliceClient: @unchecked Sendable {
    public static let jobsBranch = "slice-jobs"
    public static let workflowFile = "cloud-slice.yml"

    public enum Phase: Sendable, Equatable {
        case uploading, queued, slicing(String?), downloading
        public var description: String {
            switch self {
            case .uploading: return "Modell wird hochgeladen …"
            case .queued: return "Warte auf GitHub-Rechner …"
            case .slicing: return "OrcaSlicer rechnet …"
            case .downloading: return "G-Code wird geladen …"
            }
        }
    }

    let config: CloudSliceConfig
    let session: URLSession
    let api: URL
    /// Seconds between status checks.
    var pollInterval: Double = 8

    public init(config: CloudSliceConfig, session: URLSession = .shared,
                api: URL = URL(string: "https://api.github.com")!) {
        self.config = config
        self.session = session
        self.api = api
    }

    // MARK: - Public

    /// Checks token, repository and workflow; returns the branch the workflow runs on.
    public func verify() async throws -> String {
        guard config.isComplete else { throw CloudSliceError.notConfigured }
        let repo = try await json("GET", "repos/\(config.repository)")
        let branch = config.workflowBranch.isEmpty ? (repo["default_branch"] as? String ?? "main") : config.workflowBranch
        do {
            _ = try await json("GET", "repos/\(config.repository)/contents/.github/workflows/\(Self.workflowFile)?ref=\(branch)")
        } catch CloudSliceError.http(404, _) {
            throw CloudSliceError.workflowMissing
        }
        return branch
    }

    /// Runs one job end to end.
    public func slice(jobID: String, files: [(name: String, data: Data)], timeout: Double = 1800,
                      progress: @escaping @Sendable (Phase) -> Void = { _ in }) async throws -> CloudSliceResult {
        let branch = try await verify()
        progress(.uploading)
        try await ensureJobsBranch(from: branch)
        try await commit(files.map { ("jobs/\(jobID)/\($0.name)", $0.data) }, message: "Cloud slice job \(jobID)")
        try await dispatch(jobID: jobID, branch: branch)
        progress(.queued)

        let deadline = Date().addingTimeInterval(timeout)
        var runURL: String?
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            try Task.checkCancellation()
            guard let run = try await findRun(jobID: jobID) else { continue }
            runURL = run["html_url"] as? String
            let status = run["status"] as? String ?? ""
            if status == "completed" {
                let conclusion = run["conclusion"] as? String ?? ""
                let info = try? await jsonFile("jobs/\(jobID)/result.json")
                guard conclusion == "success", (info?["ok"] as? Bool) == true else {
                    let message = info?["error"] as? String ?? "Der Cloud-Lauf ist fehlgeschlagen (\(conclusion))."
                    throw CloudSliceError.failed(message + (runURL.map { "\n\($0)" } ?? ""))
                }
                progress(.downloading)
                let gcode = try await raw("jobs/\(jobID)/result.gcode")
                return CloudSliceResult(
                    gcode: gcode,
                    seconds: (info?["seconds"] as? NSNumber)?.doubleValue,
                    filamentGrams: (info?["filament_g"] as? String).flatMap { s in
                        s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.reduce(0, +)
                    },
                    warnings: info?["warnings"] as? [String] ?? [],
                    runURL: runURL)
            }
            progress(status == "in_progress" ? .slicing(runURL) : .queued)
        }
        throw CloudSliceError.timeout
    }

    // MARK: - Git data API

    func ensureJobsBranch(from base: String) async throws {
        do {
            _ = try await json("GET", "repos/\(config.repository)/git/ref/heads/\(Self.jobsBranch)")
        } catch CloudSliceError.http(404, _) {
            let ref = try await json("GET", "repos/\(config.repository)/git/ref/heads/\(base)")
            guard let sha = (ref["object"] as? [String: Any])?["sha"] as? String else { throw CloudSliceError.failed("Branch \(base) nicht lesbar.") }
            _ = try await json("POST", "repos/\(config.repository)/git/refs",
                               body: ["ref": "refs/heads/\(Self.jobsBranch)", "sha": sha])
        }
    }

    /// Adds files to the jobs branch in a single commit (retries if the branch moved meanwhile).
    func commit(_ files: [(path: String, data: Data)], message: String) async throws {
        var blobs: [(String, String)] = []
        for file in files {
            let blob = try await json("POST", "repos/\(config.repository)/git/blobs",
                                      body: ["content": file.data.base64EncodedString(), "encoding": "base64"])
            guard let sha = blob["sha"] as? String else { throw CloudSliceError.failed("Upload fehlgeschlagen.") }
            blobs.append((file.path, sha))
        }
        for attempt in 0..<4 {
            let ref = try await json("GET", "repos/\(config.repository)/git/ref/heads/\(Self.jobsBranch)")
            guard let head = (ref["object"] as? [String: Any])?["sha"] as? String else { throw CloudSliceError.failed("Branch nicht lesbar.") }
            let parent = try await json("GET", "repos/\(config.repository)/git/commits/\(head)")
            guard let baseTree = (parent["tree"] as? [String: Any])?["sha"] as? String else { throw CloudSliceError.failed("Commit nicht lesbar.") }
            let tree = try await json("POST", "repos/\(config.repository)/git/trees", body: [
                "base_tree": baseTree,
                "tree": blobs.map { ["path": $0.0, "mode": "100644", "type": "blob", "sha": $0.1] },
            ])
            guard let treeSHA = tree["sha"] as? String else { throw CloudSliceError.failed("Tree fehlgeschlagen.") }
            let commit = try await json("POST", "repos/\(config.repository)/git/commits",
                                        body: ["message": message, "tree": treeSHA, "parents": [head]])
            guard let commitSHA = commit["sha"] as? String else { throw CloudSliceError.failed("Commit fehlgeschlagen.") }
            do {
                _ = try await json("PATCH", "repos/\(config.repository)/git/refs/heads/\(Self.jobsBranch)",
                                   body: ["sha": commitSHA, "force": false])
                return
            } catch CloudSliceError.http(422, _) where attempt < 3 {
                continue // someone else pushed; rebuild on the new head
            }
        }
    }

    func dispatch(jobID: String, branch: String) async throws {
        do {
            _ = try await json("POST", "repos/\(config.repository)/actions/workflows/\(Self.workflowFile)/dispatches",
                               body: ["ref": branch, "inputs": ["job_id": jobID]])
        } catch CloudSliceError.http(404, _) {
            throw CloudSliceError.workflowMissing
        }
    }

    /// The run is named "Cloud slice <job id>" (run-name in the workflow).
    func findRun(jobID: String) async throws -> [String: Any]? {
        let list = try await json("GET", "repos/\(config.repository)/actions/workflows/\(Self.workflowFile)/runs?event=workflow_dispatch&per_page=30")
        let runs = list["workflow_runs"] as? [[String: Any]] ?? []
        return runs.first { ($0["display_title"] as? String ?? $0["name"] as? String ?? "").contains(jobID) }
    }

    func jsonFile(_ path: String) async throws -> [String: Any] {
        let data = try await raw(path)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func raw(_ path: String) async throws -> Data {
        let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return try await request("GET", "repos/\(config.repository)/contents/\(encoded)?ref=\(Self.jobsBranch)",
                                 accept: "application/vnd.github.raw")
    }

    // MARK: - HTTP

    func json(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let data = try await request(method, path, body: body)
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func request(_ method: String, _ path: String, body: [String: Any]? = nil,
                 accept: String = "application/vnd.github+json") async throws -> Data {
        guard config.isComplete, let url = URL(string: path, relativeTo: api) else { throw CloudSliceError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 120
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("MakerSlice", forHTTPHeaderField: "User-Agent")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String
            throw CloudSliceError.http(code, message ?? path)
        }
        return data
    }
}
