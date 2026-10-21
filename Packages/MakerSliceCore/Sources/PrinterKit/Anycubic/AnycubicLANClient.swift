#if canImport(Network)
import Foundation
import Network

/// Anycubic Kobra S1 (stock firmware) in LAN mode: MQTT over TLS for status and
/// commands, HTTP for uploading G-code. Protocol per the community projects
/// anycubic-lan, anycubic_ha_local and kobra-lan-cli.
public final class AnycubicLANClient: PrinterDriver, @unchecked Sendable {
    public let connection: PrinterConnection

    private let queue = DispatchQueue(label: "AnycubicLANClient")
    private let lock = NSLock()
    private var mqtt: NWConnection?
    private var decoder = MQTTCodec.Decoder()
    private var credentials: AnycubicHandshake.Credentials?
    private var connected = false
    private var connAck: CheckedContinuation<Void, Error>?
    private var responseWaiters: [String: CheckedContinuation<(code: Int, message: String), Error>] = [:]
    private var cachedStatus = PrinterStatus()
    private var infoReceived = false
    private var uploadURL: String?
    private var features: [String: Any] = [:]
    private var events: [PrinterEvent] = []
    private var lastQuery = Date.distantPast
    private var pingTimer: DispatchSourceTimer?
    private var packetID: UInt16 = 1
    private var rawReports: [String: Data] = [:]

    public init(connection: PrinterConnection) {
        self.connection = connection
    }

    deinit {
        pingTimer?.cancel()
        mqtt?.cancel()
    }

    // MARK: - Connection

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func log(_ level: PrinterEvent.Level, _ message: String) {
        locked {
            events.append(PrinterEvent(level: level, message: message, source: "Kobra S1"))
            if events.count > 300 { events.removeFirst(events.count - 300) }
        }
    }

    private func ensureConnected() async throws {
        if locked({ connected && mqtt != nil }) { return }
        let creds = try await AnycubicHandshake.perform(host: connection.hostOnly)
        locked { credentials = creds }

        let tls = NWProtocolTLS.Options()
        // The broker uses a self-signed certificate that differs per printer; the
        // connection stays encrypted but the certificate cannot be verified.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, queue)
        let params = NWParameters(tls: tls)
        guard let port = NWEndpoint.Port(rawValue: UInt16(creds.port)) else { throw PrinterError.invalidAddress }
        let conn = NWConnection(host: NWEndpoint.Host(creds.host), port: port, using: params)
        locked {
            mqtt?.cancel()
            mqtt = conn
            decoder = MQTTCodec.Decoder()
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            locked { connAck = cont }
            conn.stateUpdateHandler = { [weak self, weak conn] state in
                guard let self, let conn else { return }
                switch state {
                case .ready:
                    let clientID = "makerslice-\(UUID().uuidString.prefix(8))"
                    self.send(MQTTCodec.connect(clientID: clientID, username: creds.username, password: creds.password,
                                                keepAlive: 60))
                    self.receiveLoop(conn)
                case .failed(let error):
                    self.handleDisconnect(error.localizedDescription, from: conn)
                case .cancelled:
                    self.handleDisconnect(nil, from: conn)
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self else { return }
                let pending: CheckedContinuation<Void, Error>? = self.locked {
                    let c = self.connAck
                    self.connAck = nil
                    return c
                }
                pending?.resume(throwing: PrinterError.unreachable("Keine Antwort vom MQTT-Broker"))
            }
        }

        let topic = "\(AnycubicHandshake.topicPrefix)/printer/public/\(creds.modelID)/\(creds.deviceID)/#"
        send(MQTTCodec.subscribe(topic: topic, packetID: nextPacketID()))
        startPing()
        log(.info, "Verbunden mit \(creds.modelName ?? "Anycubic-Drucker")")
        queryAll()
    }

    private func nextPacketID() -> UInt16 {
        locked {
            packetID = packetID == UInt16.max ? 1 : packetID + 1
            return packetID
        }
    }

    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.send(MQTTCodec.pingReq) }
        timer.resume()
        locked {
            pingTimer?.cancel()
            pingTimer = timer
        }
    }

    private func handleDisconnect(_ reason: String?, from conn: NWConnection) {
        let (wasConnected, ack, waiters): (Bool, CheckedContinuation<Void, Error>?, [CheckedContinuation<(code: Int, message: String), Error>]) = locked {
            // A replaced connection reporting late must not tear down the current one.
            guard mqtt === conn else { return (false, nil, []) }
            let w = connected
            connected = false
            mqtt = nil
            let a = connAck
            connAck = nil
            let ws = Array(responseWaiters.values)
            responseWaiters.removeAll()
            return (w, a, ws)
        }
        let error = PrinterError.unreachable(reason ?? "Verbindung getrennt")
        ack?.resume(throwing: error)
        waiters.forEach { $0.resume(throwing: error) }
        if wasConnected { log(.warning, "Verbindung zum Drucker getrennt" + (reason.map { ": \($0)" } ?? "")) }
    }

    public func disconnect() {
        let conn: NWConnection? = locked {
            pingTimer?.cancel()
            pingTimer = nil
            let c = mqtt
            mqtt = nil
            connected = false
            return c
        }
        conn?.send(content: MQTTCodec.disconnect, completion: .contentProcessed { _ in conn?.cancel() })
    }

    private func send(_ data: Data) {
        let conn = locked { mqtt }
        conn?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var packets: [MQTTPacket] = []
                self.locked {
                    self.decoder.append(data)
                    while let p = self.decoder.next() { packets.append(p) }
                }
                packets.forEach(self.handle)
            }
            if error != nil || isComplete {
                self.handleDisconnect(error?.localizedDescription, from: conn)
                return
            }
            self.receiveLoop(conn)
        }
    }

    private func handle(_ packet: MQTTPacket) {
        switch packet {
        case .connAck(let code):
            let cont: CheckedContinuation<Void, Error>? = locked {
                let c = connAck
                connAck = nil
                if code == 0 { connected = true }
                return c
            }
            if code == 0 {
                cont?.resume()
            } else {
                cont?.resume(throwing: AnycubicHandshake.HandshakeError.rejected("MQTT-Code \(code)"))
            }
        case .publish(let topic, let payload, let qos, let id):
            if qos > 0, let id { send(MQTTCodec.pubAck(packetID: id)) }
            handleMessage(topic: topic, payload: payload)
        default:
            break
        }
    }

    private func handleMessage(topic: String, payload: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
        if topic.hasSuffix("/response") {
            if let msgid = json["msgid"] as? String {
                let waiter: CheckedContinuation<(code: Int, message: String), Error>? = locked { responseWaiters.removeValue(forKey: msgid) }
                let code = Int(jsonNumber(json["code"]) ?? -1)
                if code != 0 && code != 200 {
                    log(.warning, "Antwort des Druckers: \(String(decoding: payload.prefix(600), as: UTF8.self))")
                }
                waiter?.resume(returning: (code, json["msg"] as? String ?? ""))
            }
            return
        }
        // …/{type}/report
        let parts = topic.split(separator: "/")
        guard parts.count >= 2, parts.last == "report" else { return }
        let type = String(parts[parts.count - 2])
        let data = json["data"] as? [String: Any] ?? [:]
        locked { rawReports[type] = payload }
        if let code = jsonNumber(json["code"]), code != 200, code != 0 {
            log(.error, "\(type): \(json["msg"] as? String ?? "Fehler") (Code \(Int(code)))")
        }
        if (json["state"] as? String) == "failed" {
            log(.error, "\(type): Befehl abgelehnt – \(json["msg"] as? String ?? "")")
        }
        locked {
            let before = cachedStatus.state
            cachedStatus.applyAnycubic(type: type, data: data)
            if type == "info" {
                infoReceived = true
                if let urls = data["urls"] as? [String: Any], let upload = urls["fileUploadurl"] as? String { uploadURL = upload }
                if let f = data["features"] as? [String: Any] { features = f }
            }
            if before != cachedStatus.state, before != .unknown {
                events.append(PrinterEvent(level: cachedStatus.state == .error ? .error : .info,
                                           message: "Status: \(cachedStatus.state.displayName)", source: "Kobra S1"))
            }
        }
    }

    // MARK: - Messages

    private func webTopic(_ type: String) -> String? {
        guard let c = locked({ credentials }) else { return nil }
        return "\(AnycubicHandshake.topicPrefix)/web/printer/\(c.modelID)/\(c.deviceID)/\(type)"
    }

    private func slicerTopic(_ type: String) -> String? {
        guard let c = locked({ credentials }) else { return nil }
        return "\(AnycubicHandshake.topicPrefix)/slicer/printer/\(c.modelID)/\(c.deviceID)/\(type)"
    }

    @discardableResult
    private func publish(type: String, action: String, data: Any?, topic: String? = nil) -> String {
        let msgid = UUID().uuidString.lowercased()
        let message: [String: Any] = ["type": type, "action": action, "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
                                      "msgid": msgid, "data": data ?? NSNull()]
        if let t = topic ?? webTopic(type), let body = try? JSONSerialization.data(withJSONObject: message) {
            send(MQTTCodec.publish(topic: t, payload: body))
        }
        return msgid
    }

    private func queryAll() {
        locked { lastQuery = Date() }
        for type in ["info", "tempature", "fan", "light"] { publish(type: type, action: "query", data: nil) }
        publish(type: "multiColorBox", action: "getInfo", data: nil)
    }

    /// Publishes and waits for the printer's acknowledgement on /response.
    private func command(type: String, action: String, data: Any?, topic: String? = nil) async throws {
        let answer = try await commandResult(type: type, action: action, data: data, topic: topic)
        if answer.code != 0 && answer.code != 200 {
            log(.error, "\(type)/\(action) abgelehnt (Code \(answer.code)\(answer.message.isEmpty ? "" : ": \(answer.message)"))")
            throw PrinterError.http(answer.code, "Befehl \(action) abgelehnt\(answer.message.isEmpty ? "" : " (\(answer.message))")")
        }
    }

    /// Like `command`, but hands back the printer's answer instead of throwing when it says no.
    private func commandResult(type: String, action: String, data: Any?, topic: String? = nil) async throws -> (code: Int, message: String) {
        try await ensureConnected()
        let msgid = UUID().uuidString.lowercased()
        let answer: (code: Int, message: String) = try await withCheckedThrowingContinuation { cont in
            locked { responseWaiters[msgid] = cont }
            let message: [String: Any] = ["type": type, "action": action, "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
                                          "msgid": msgid, "data": data ?? NSNull()]
            if let t = topic ?? webTopic(type), let body = try? JSONSerialization.data(withJSONObject: message) {
                send(MQTTCodec.publish(topic: t, payload: body))
            }
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                let waiter: CheckedContinuation<(code: Int, message: String), Error>? = self?.locked { self?.responseWaiters.removeValue(forKey: msgid) }
                waiter?.resume(throwing: PrinterError.unreachable("Keine Bestätigung vom Drucker"))
            }
        }
        return answer
    }

    /// After a start: true when the job is still there ~20 s later; false when the printer dropped it again (back to idle).
    private func jobSurvives() async -> Bool {
        var seenPrinting = false
        for second in 0..<20 {
            queryAll()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let state = locked { cachedStatus.state }
            if state == .printing || state == .paused { seenPrinting = true }
            if [.standby, .error, .cancelled].contains(state), seenPrinting || second >= 10 { return false }
        }
        return true
    }

    /// True when the printer really is working on `name` (it can answer a start command with an error code and still start).
    private func startedPrinting(_ name: String) async -> Bool {
        for _ in 0..<20 {
            queryAll()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let s = locked { cachedStatus }
            let sameFile = s.fileName.map { $0.hasPrefix((name as NSString).deletingPathExtension) || name.hasPrefix(($0 as NSString).deletingPathExtension) } ?? false
            let heating = (s.tools.first?.target ?? 0) > 0 || s.bed.target > 0
            if s.state == .printing, sameFile || heating { return true }
        }
        return false
    }

    // MARK: - PrinterDriver

    public func status() async throws -> PrinterStatus {
        try await ensureConnected()
        if Date().timeIntervalSince(locked { lastQuery }) > 10 { queryAll() }
        // Give the first reports a moment to arrive.
        for _ in 0..<15 where !locked({ infoReceived }) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return locked { cachedStatus }
    }

    public func upload(gcode: Data, fileName: String, startPrint: Bool, mapping: [SlotMapping]) async throws {
        try await ensureConnected()
        if locked({ uploadURL }) == nil {
            publish(type: "info", action: "query", data: nil)
            for _ in 0..<30 where locked({ uploadURL }) == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        guard let target = locked({ uploadURL }), var comps = URLComponents(string: target) else {
            throw PrinterError.http(0, "Der Drucker hat keine Upload-Adresse gemeldet")
        }
        // The printer reports its own IP; use the address we reached it under.
        comps.host = connection.hostOnly
        guard let url = comps.url else { throw PrinterError.invalidAddress }

        let name = fileName.hasSuffix(".gcode") ? fileName : fileName + ".gcode"
        let boundary = "------------------------\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("AnycubicSlicerNext/1.3.9.4", forHTTPHeaderField: "User-Agent")
        request.setValue(String(gcode.count), forHTTPHeaderField: "X-File-Length")
        let body = AnycubicHandshake.uploadBody(gcode: gcode, fileName: name, boundary: boundary)
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            log(.error, "Upload fehlgeschlagen")
            throw PrinterError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "Upload fehlgeschlagen")
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = jsonNumber(json["code"]), code != 200, code != 0 {
            throw PrinterError.http(Int(code), json["message"] as? String ?? "Upload abgelehnt")
        }
        log(.info, "Datei \(name) hochgeladen (\(gcode.count / 1024) KB)")
        guard startPrint else { return }
        // The printer writes the file to its storage after the upload; starting at once ends with "SD busy" (code 11535).
        try await Task.sleep(nanoseconds: 5_000_000_000)

        let md5 = LANCrypto.md5([UInt8](gcode)).map { String(format: "%02x", $0) }.joined()
        let payload = AnycubicHandshake.startPayload(fileName: name, md5: md5, size: gcode.count, mapping: mapping,
                                                     msgID: UUID().uuidString.lowercased(),
                                                     now: Int64(Date().timeIntervalSince1970 * 1000))
        // Right after the upload the printer is still busy with the file (SD card write, preview) and may answer
        // "SD busy" (code 11535). Wait and ask again a few times before giving up.
        var attempt = 0
        while true {
            let answer = try await commandResult(type: "print", action: "start", data: payload["data"], topic: slicerTopic("print"))
            var accepted = answer.code == 0 || answer.code == 200
            if !accepted {
                log(.warning, "print/start: Antwortcode \(answer.code)\(answer.message.isEmpty ? "" : " (\(answer.message))") – prüfe, ob der Druck trotzdem läuft")
                accepted = await startedPrinting(name)
            }
            // The printer can accept the start, heat up and then drop the job again (SD still busy).
            if accepted, await jobSurvives() { break }
            attempt += 1
            let busy = accepted || Self.isBusyCode(answer.code, answer.message)
            guard busy, attempt < 4 else {
                log(.error, "print/start abgelehnt (Code \(answer.code))")
                throw PrinterError.http(answer.code, busy
                    ? "Der Drucker ist noch mit der Datei beschäftigt (SD-Karte, Code \(answer.code)). Kurz warten und „Drucken“ erneut tippen – die Datei ist hochgeladen."
                    : "Der Drucker hat den Start abgelehnt\(answer.message.isEmpty ? "" : " (\(answer.message))"). Läuft noch ein anderer Auftrag oder ist einer pausiert?")
            }
            log(.info, "Drucker beschäftigt oder Auftrag verworfen – neuer Startversuch in 6 s (\(attempt)/3)")
            try await Task.sleep(nanoseconds: 6_000_000_000)
        }
        log(.info, "Druck von \(name) gestartet")
    }

    /// "SD busy" and similar: the printer is occupied with a file or another job and will accept the command later.
    static func isBusyCode(_ code: Int, _ message: String) -> Bool {
        code == 11535 || message.lowercased().contains("busy")
    }

    private func taskData() -> [String: Any] {
        ["taskid": locked { cachedStatus.taskID } ?? "-1"]
    }

    public func pause() async throws { try await command(type: "print", action: "pause", data: taskData()) }
    public func resume() async throws { try await command(type: "print", action: "resume", data: taskData()) }
    public func cancel() async throws { try await command(type: "print", action: "stop", data: ["taskid": "-1"]) }

    public func setBedTemperature(_ t: Int) async throws {
        try await command(type: "print", action: "update", data: ["taskid": "-1", "settings": ["target_hotbed_temp": t]])
    }

    public func setToolTemperature(tool: Int, _ t: Int) async throws {
        try await command(type: "print", action: "update", data: ["taskid": "-1", "settings": ["target_nozzle_temp": t]])
    }

    public func setLight(_ on: Bool) async throws {
        try await command(type: "light", action: "control", data: ["type": 2, "status": on ? 1 : 0, "brightness": on ? 100 : 0])
    }

    /// Starts or stops drying in the ACE Pro.
    public func setDrying(_ on: Bool, temperature: Int = 45, minutes: Int = 240) async throws {
        let status: [String: Any] = on ? ["status": 1, "target_temp": temperature, "duration": minutes] : ["status": 0]
        try await command(type: "multiColorBox", action: "setDry", data: ["multi_color_box": [["id": 0, "drying_status": status]]])
    }

    public func calibration() async throws -> CalibrationData {
        let s = try await status()
        var cal = CalibrationData()
        if let fw = s.firmware { cal.notes.append(("Firmware", fw)) }
        if let c = locked({ credentials }) { cal.notes.append(("Modell-ID", "\(c.modelID)")) }
        let f = locked { features }
        for (key, value) in f.sorted(by: { $0.key < $1.key }) {
            let on = (jsonNumber(value) ?? 0) != 0
            cal.notes.append((Self.featureName(key), on ? "ja" : "nein"))
        }
        cal.notes.append(("Hinweis", "Bett-Mesh und Pressure Advance werden im LAN-Modus nicht übertragen. Mit der Rinkhals-Firmware (Moonraker) sind sie sichtbar."))
        return cal
    }

    static func featureName(_ key: String) -> String {
        switch key {
        case "auto_leveling_support": return "Automatisches Leveln"
        case "drying_first_support": return "Trocknen vor Druck"
        case "camera_timelapse_support": return "Zeitraffer"
        case "gcode_3mf_support": return "3MF-Druck"
        case "preheating_support": return "Vorheizen"
        case "fod_support": return "Fremdkörper-Erkennung"
        case "pre_cancel_support": return "Abbruch vor Start"
        default: return key.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Starts the printer's camera so `cameraStreamURL` (FLV over HTTP) delivers video. Does not touch the print.
    public func startCamera() async throws { try await command(type: "video", action: "startCapture", data: nil) }

    /// Stops the camera again.
    public func stopCamera() async throws { try await command(type: "video", action: "stopCapture", data: nil) }

    /// Latest raw JSON report per message type (info, tempature, fan, light, …) – for diagnosing parser differences.
    public func latestRawReports() -> [String: Data] { locked { rawReports } }

    public func recentEvents() async throws -> [PrinterEvent] {
        locked { events }
    }
}
#endif
