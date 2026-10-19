import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum PrinterError: Error, LocalizedError, Equatable {
    case invalidAddress
    case http(Int, String)
    case unreachable(String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Ungültige Drucker-Adresse."
        case .http(let code, let message): return "Drucker meldet Fehler \(code): \(message)"
        case .unreachable(let reason): return "Drucker nicht erreichbar: \(reason)"
        case .badResponse: return "Unerwartete Antwort vom Drucker."
        }
    }
}

/// A configured printer.
public struct PrinterConnection: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Host or IP, optionally with port ("192.168.1.50" or "u1.local:7125").
    public var host: String
    public var apiKey: String?

    public init(id: UUID = UUID(), name: String, host: String, apiKey: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.apiKey = apiKey
    }

    public var baseURL: URL? {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !h.hasPrefix("http://") && !h.hasPrefix("https://") { h = "http://" + h }
        guard var comps = URLComponents(string: h), let host = comps.host, !host.isEmpty else { return nil }
        if comps.port == nil { comps.port = 7125 }
        comps.path = ""
        return comps.url
    }
}

/// Talks to Moonraker, which the Snapmaker U1 firmware runs on port 7125.
public final class MoonrakerClient: @unchecked Sendable {
    public let connection: PrinterConnection
    private let session: URLSession

    public init(connection: PrinterConnection, session: URLSession? = nil) {
        self.connection = connection
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Info & status

    public struct ServerInfo: Sendable {
        public var klippyState: String
        public var moonrakerVersion: String?
        public var hostname: String?
    }

    public func serverInfo() async throws -> ServerInfo {
        let json = try await getJSON("/server/info")
        guard let result = json["result"] as? [String: Any] else { throw PrinterError.badResponse }
        var info = ServerInfo(klippyState: result["klippy_state"] as? String ?? "unknown",
                              moonrakerVersion: result["moonraker_version"] as? String)
        if let sys = try? await getJSON("/machine/system_info"),
           let r = sys["result"] as? [String: Any], let si = r["system_info"] as? [String: Any],
           let net = si["network"] as? [String: Any] {
            info.hostname = net.keys.first
        }
        return info
    }

    public func status() async throws -> PrinterStatus {
        let query = PrinterStatus.queryObjects.joined(separator: "&")
        let json = try await getJSON("/printer/objects/query?\(query)")
        guard let result = json["result"] as? [String: Any], let status = result["status"] as? [String: Any] else {
            throw PrinterError.badResponse
        }
        var s = PrinterStatus()
        s.apply(status)
        return s
    }

    // MARK: - Jobs

    /// Uploads G-code into the printer's `gcodes` root and optionally starts it.
    public func upload(gcode: Data, fileName: String, startPrint: Bool,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let boundary = "MakerSlice-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("root", "gcodes")
        field("print", startPrint ? "true" : "false")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(Self.sanitize(fileName))\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(gcode)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = try makeRequest("/server/files/upload", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        progress?(0)
        let (data, response) = try await perform { try await self.session.upload(for: request, from: body) }
        try check(response, data)
        progress?(1)
    }

    public func startPrint(fileName: String) async throws {
        let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fileName
        _ = try await postJSON("/printer/print/start?filename=\(encoded)")
    }

    public func pause() async throws { _ = try await postJSON("/printer/print/pause") }
    public func resume() async throws { _ = try await postJSON("/printer/print/resume") }
    public func cancel() async throws { _ = try await postJSON("/printer/print/cancel") }

    /// Runs arbitrary G-code (e.g. "M140 S60").
    public func runGCode(_ script: String) async throws {
        let encoded = script.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? script
        _ = try await postJSON("/printer/gcode/script?script=\(encoded)")
    }

    public func setBedTemperature(_ t: Int) async throws { try await runGCode("M140 S\(t)") }
    public func setToolTemperature(tool: Int, _ t: Int) async throws { try await runGCode("M104 T\(tool) S\(t)") }

    public struct RemoteFile: Sendable, Identifiable, Hashable {
        public var id: String { path }
        public var path: String
        public var modified: Date
        public var size: Int
    }

    public func files() async throws -> [RemoteFile] {
        let json = try await getJSON("/server/files/list?root=gcodes")
        guard let list = json["result"] as? [[String: Any]] else { throw PrinterError.badResponse }
        return list.compactMap { item in
            guard let path = item["path"] as? String else { return nil }
            let modified = (item["modified"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            return RemoteFile(path: path, modified: modified, size: item["size"] as? Int ?? 0)
        }.sorted { $0.modified > $1.modified }
    }

    /// Snapshot URL of the first configured webcam, if any.
    public func webcamSnapshotURL() async throws -> URL? {
        let json = try await getJSON("/server/webcams/list")
        guard let result = json["result"] as? [String: Any], let cams = result["webcams"] as? [[String: Any]],
              let cam = cams.first(where: { ($0["enabled"] as? Bool) ?? true }),
              let snapshot = cam["snapshot_url"] as? String, !snapshot.isEmpty,
              let base = connection.baseURL else { return nil }
        if snapshot.hasPrefix("http") { return URL(string: snapshot) }
        // Relative URLs are served by the web frontend on port 80.
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.port = nil
        comps?.path = ""
        return comps?.url.flatMap { URL(string: snapshot, relativeTo: $0)?.absoluteURL }
    }

    // MARK: - Plumbing

    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_. ")
        var cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        if !cleaned.lowercased().hasSuffix(".gcode") { cleaned += ".gcode" }
        return cleaned
    }

    private func makeRequest(_ pathAndQuery: String, method: String) throws -> URLRequest {
        guard let base = connection.baseURL, let url = URL(string: pathAndQuery, relativeTo: base) else {
            throw PrinterError.invalidAddress
        }
        var request = URLRequest(url: url.absoluteURL)
        request.httpMethod = method
        if let key = connection.apiKey, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-Api-Key") }
        return request
    }

    private func getJSON(_ path: String) async throws -> [String: Any] {
        let request = try makeRequest(path, method: "GET")
        let (data, response) = try await perform { try await self.session.data(for: request) }
        try check(response, data)
        return try parse(data)
    }

    private func postJSON(_ path: String) async throws -> [String: Any] {
        let request = try makeRequest(path, method: "POST")
        let (data, response) = try await perform { try await self.session.data(for: request) }
        try check(response, data)
        return try parse(data)
    }

    private func perform(_ op: () async throws -> (Data, URLResponse)) async throws -> (Data, URLResponse) {
        do {
            return try await op()
        } catch let error as URLError {
            throw PrinterError.unreachable(error.localizedDescription)
        }
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw PrinterError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            var message = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? [String: Any], let m = err["message"] as? String {
                message = m
            }
            throw PrinterError.http(http.statusCode, message)
        }
    }

    private func parse(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PrinterError.badResponse }
        return json
    }
}
