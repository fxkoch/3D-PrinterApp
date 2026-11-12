import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum PrinterError: Error, LocalizedError, Equatable {
    case invalidAddress
    case http(Int, String)
    case unreachable(String)
    case badResponse
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Ungültige Drucker-Adresse."
        case .http(let code, let message): return "Drucker meldet Fehler \(code): \(message)"
        case .unreachable(let reason): return "Drucker nicht erreichbar: \(reason)"
        case .badResponse: return "Unerwartete Antwort vom Drucker."
        case .unsupported(let why): return why
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
    /// "snapmakerU1" or "kobraS1" (matches SliceKit's PrinterModel).
    public var model: String
    public var kind: ConnectionKind
    /// Serial number (Bambu Lab LAN mode: the MQTT topics contain it; the access code is stored in `apiKey`).
    public var serial: String?

    public init(id: UUID = UUID(), name: String, host: String, apiKey: String? = nil,
                model: String = "snapmakerU1", kind: ConnectionKind = .moonraker, serial: String? = nil) {
        self.serial = serial
        self.id = id
        self.name = name
        self.host = host
        self.apiKey = apiKey
        self.model = model
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case id, name, host, apiKey, model, kind, serial }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "snapmakerU1"
        kind = try c.decodeIfPresent(ConnectionKind.self, forKey: .kind) ?? .moonraker
        serial = try c.decodeIfPresent(String.self, forKey: .serial)
    }

    /// Bare host name or IP without scheme/port.
    public var hostOnly: String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if h.hasPrefix("[") , let end = h.firstIndex(of: "]") { return String(h[...end]) }
        return String(h.split(separator: "/").first?.split(separator: ":").first ?? "")
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
public final class MoonrakerClient: PrinterDriver, @unchecked Sendable {
    public let connection: PrinterConnection
    private let session: URLSession
    private let aceLock = NSLock()
    private var aceSeen = false

    /// True once the printer has reported the multiACE add-on (Anycubic ACE Pro 2 on the U1).
    public var hasMultiACE: Bool {
        aceLock.lock(); defer { aceLock.unlock() }
        return aceSeen
    }

    private func setACESeen(_ seen: Bool) {
        aceLock.lock(); defer { aceLock.unlock() }
        aceSeen = seen
    }

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
        setACESeen(s.ace != nil)
        return s
    }

    // MARK: - Jobs

    /// Uploads G-code into the printer's `gcodes` root and optionally starts it.
    public func upload(gcode: Data, fileName: String, startPrint: Bool, mapping: [SlotMapping] = []) async throws {
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
        let (data, response) = try await perform { try await self.session.upload(for: request, from: body) }
        try check(response, data)
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

    public var filamentControl: FilamentControlSupport {
        if hasMultiACE {
            return FilamentControlSupport(extrude: true, loadSlot: true, retract: true,
                                          note: "Der ACE ist über multiACE angebunden. „Laden“ führt das Filament des ACE-Slots bis in den Druckkopf mit der gleichen Nummer, „Zurückziehen“ zieht es wieder in den ACE. Der Drucker heizt dabei selbst.")
        }
        return FilamentControlSupport(extrude: true, note: "Laden und Entladen ganzer Spulen geht an diesem Drucker am Display; die App kann Filament bei heißer Düse vorschieben und zurückziehen.")
    }

    /// multiACE: loads tool head `slot` (0...3) from its ACE slot.
    public func loadSlot(_ slot: Int) async throws {
        guard hasMultiACE else { throw PrinterError.unsupported(filamentControl.note ?? "Nicht möglich.") }
        try await requireIdleForACE(head: slot)
        try await runGCode(MultiACECommand.load(head: slot))
    }

    /// multiACE: pulls the filament of tool head `slot` back into the ACE.
    public func retractSlot(_ slot: Int) async throws {
        guard hasMultiACE else { throw PrinterError.unsupported(filamentControl.note ?? "Nicht möglich.") }
        try await requireIdleForACE(head: slot)
        try await runGCode(MultiACECommand.unload(head: slot))
    }

    /// multiACE: starts or stops the dryer of ACE `unit`.
    public func setACEDrying(_ on: Bool, unit: Int = 0, temperature: Int = 45, minutes: Int = 240) async throws {
        guard hasMultiACE else { throw PrinterError.unsupported("Der ACE ist an diesem Drucker nicht eingerichtet.") }
        try await requireIdleForACE(head: nil)
        try await runGCode(on ? MultiACECommand.startDrying(unit: unit, temperature: temperature, minutes: minutes)
                              : MultiACECommand.stopDrying(unit: unit))
    }

    /// The ACE commands move filament and heat the nozzle: never during a print.
    private func requireIdleForACE(head: Int?) async throws {
        if let head, !(0..<4).contains(head) { throw PrinterError.unsupported("Werkzeugkopf \(head + 1) gibt es nicht.") }
        let s = try await status()
        if s.state == .printing || s.state == .paused {
            throw PrinterError.unsupported("Während eines Drucks bewegt die App kein Filament.")
        }
    }

    public func extrude(millimetres: Double) async throws {
        try await requireHotNozzle()
        try await runGCode(FilamentMove.script(millimetres: millimetres))
    }

    public var speedControl: SpeedControl { .percent }
    /// `M220` scales every move of the running job; it does not change accelerations or fans.
    public func setSpeedPercent(_ percent: Int) async throws {
        try await runGCode("M220 S\(min(max(percent, SpeedControl.percentRange.lowerBound), SpeedControl.percentRange.upperBound))")
    }
    public func setSpeedMode(_ mode: Int) async throws {
        try await setSpeedPercent(SpeedControl.percentPresets[min(max(mode, 1), 3) - 1].percent)
    }

    public func setBedTemperature(_ t: Int) async throws { try await runGCode("M140 S\(t)") }
    public func setToolTemperature(tool: Int, _ t: Int) async throws { try await runGCode("M104 T\(tool) S\(t)") }

    public func setLight(_ on: Bool) async throws {
        // Klipper has no standard light object; most machines (incl. the U1) expose a cavity LED macro.
        try await runGCode(on ? "SET_LED LED=cavity_led WHITE=1" : "SET_LED LED=cavity_led WHITE=0")
    }

    public func calibration() async throws -> CalibrationData {
        let json = try await getJSON("/printer/objects/query?bed_mesh&gcode_move&extruder&extruder1&extruder2&extruder3&configfile=settings")
        guard let result = json["result"] as? [String: Any], let status = result["status"] as? [String: Any] else {
            throw PrinterError.badResponse
        }
        return MoonrakerClient.parseCalibration(status)
    }

    static func parseCalibration(_ status: [String: Any]) -> CalibrationData {
        let num = jsonNumber
        var cal = CalibrationData()
        if let mesh = status["bed_mesh"] as? [String: Any], let matrix = mesh["probed_matrix"] as? [[Any]], !matrix.isEmpty,
           let mn = mesh["mesh_min"] as? [Any], let mx = mesh["mesh_max"] as? [Any], mn.count >= 2, mx.count >= 2 {
            let points = matrix.map { $0.compactMap(num) }
            if points.first?.isEmpty == false {
                cal.bedMesh = CalibrationData.BedMesh(profile: mesh["profile_name"] as? String ?? "default",
                                                      min: (num(mn[0]) ?? 0, num(mn[1]) ?? 0),
                                                      max: (num(mx[0]) ?? 0, num(mx[1]) ?? 0), points: points)
            }
        }
        if let gm = status["gcode_move"] as? [String: Any], let origin = gm["homing_origin"] as? [Any], origin.count >= 3 {
            cal.zOffset = num(origin[2])
        }
        for name in ["extruder", "extruder1", "extruder2", "extruder3"] {
            if let e = status[name] as? [String: Any], let pa = num(e["pressure_advance"]) { cal.pressureAdvance[name] = pa }
        }
        if let cfg = status["configfile"] as? [String: Any], let settings = cfg["settings"] as? [String: Any],
           let shaper = settings["input_shaper"] as? [String: Any] {
            for key in ["shaper_type_x", "shaper_freq_x", "shaper_type_y", "shaper_freq_y"] {
                if let v = shaper[key] { cal.inputShaper[key] = "\(v)" }
            }
        }
        return cal
    }

    public func recentEvents() async throws -> [PrinterEvent] {
        let json = try await getJSON("/server/gcode_store?count=100")
        guard let result = json["result"] as? [String: Any], let store = result["gcode_store"] as? [[String: Any]] else {
            throw PrinterError.badResponse
        }
        return store.compactMap { item in
            guard let message = item["message"] as? String, item["type"] as? String == "response" else { return nil }
            let time = jsonNumber(item["time"]) ?? Date().timeIntervalSince1970
            let level: PrinterEvent.Level = message.hasPrefix("!!") ? .error : message.lowercased().contains("warn") ? .warning : .info
            return PrinterEvent(date: Date(timeIntervalSince1970: time), level: level,
                                message: message.trimmingCharacters(in: CharacterSet(charactersIn: "!/ ")), source: "Konsole")
        }
    }

    public func disconnect() {}

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
    /// The U1's own camera service only delivers pictures while it is asked for them every few seconds
    /// (`camera.start_monitor`, the same call Snapmaker's apps make). About one picture per second is all it produces.
    public func wakeCamera() async {
        #if !canImport(FoundationNetworking)
        guard let base = connection.baseURL, var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        comps.scheme = base.scheme == "https" ? "wss" : "ws"
        comps.path = "/websocket"
        guard let url = comps.url else { return }
        let task = session.webSocketTask(with: url)
        task.resume()
        let request = #"{"jsonrpc":"2.0","id":1,"method":"camera.start_monitor","params":{"domain":"lan","interval":0}}"#
        try? await task.send(.string(request))
        _ = try? await task.receive()
        task.cancel(with: .normalClosure, reason: nil)
        #endif
    }

    public func webcamSnapshotURL() async throws -> URL? {
        let json = try await getJSON("/server/webcams/list")
        guard let base = connection.baseURL else { return nil }
        guard let result = json["result"] as? [String: Any], let cams = result["webcams"] as? [[String: Any]],
              let cam = cams.first(where: { ($0["enabled"] as? Bool) ?? true }),
              let snapshot = cam["snapshot_url"] as? String, !snapshot.isEmpty else {
            // Stock U1 software: no webcam entry, but its camera service writes this picture once it was woken (`wakeCamera`).
            return URL(string: "/server/files/camera/monitor.jpg", relativeTo: base)?.absoluteURL
        }
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

    // MARK: - Notes stored in the printer (calibration results)

    /// Moonraker database namespace the app uses.
    public static let databaseNamespace = "makerslice"

    /// A JSON value the app stored in this printer's Moonraker database, as JSON data (nil if nothing is stored).
    public func storedValue(key: String) async throws -> Data? {
        do {
            let json = try await getJSON("/server/database/item?namespace=\(Self.databaseNamespace)&key=\(key)")
            guard let result = json["result"] as? [String: Any], let value = result["value"] else { return nil }
            return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        } catch PrinterError.http(404, _) {
            return nil
        }
    }

    /// Stores a JSON value in the printer's database (namespace "makerslice"). This only writes a small note into
    /// Moonraker's database – it does not change the printer's configuration or start anything.
    public func store(value: Data, key: String) async throws {
        let json = try JSONSerialization.jsonObject(with: value, options: [.fragmentsAllowed])
        var request = try makeRequest("/server/database/item", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["namespace": Self.databaseNamespace, "key": key, "value": json])
        let (body, response) = try await perform { try await self.session.data(for: request) }
        try check(response, body)
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

/// Reads a JSON number regardless of how the platform bridged it.
func jsonNumber(_ any: Any?) -> Double? {
    switch any {
    case let d as Double: return d
    case let i as Int: return Double(i)
    case let b as Bool: return b ? 1 : 0
    case let n as NSNumber: return n.doubleValue
    case let s as String: return Double(s)
    default: return nil
    }
}
