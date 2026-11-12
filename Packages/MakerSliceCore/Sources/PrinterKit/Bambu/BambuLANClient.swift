#if canImport(Network)
import Foundation
import Network

/// Bambu Lab printers (P1S, P1P, X1 …) in LAN mode: MQTT over TLS on port 8883 (user "bblp", the access code as
/// password) for status and commands, FTPS on port 990 for the print file. Protocol as documented by the community
/// (OpenBambuAPI, bambulabs_api, ha-bambulab).
public final class BambuLANClient: PrinterDriver, @unchecked Sendable {
    public let connection: PrinterConnection
    /// Standard ports of the printer; other values are only used with the virtual printer.
    public var mqttPort: UInt16 = 8883
    public var ftpsPort: UInt16 = 990

    private let queue = DispatchQueue(label: "BambuLANClient")
    private let lock = NSLock()
    private var mqtt: NWConnection?
    private var decoder = MQTTCodec.Decoder()
    private var connected = false
    private var connAck: CheckedContinuation<Void, Error>?
    private var waiters: [String: CheckedContinuation<(result: String, reason: String), Error>] = [:]
    private var raw: [String: Any] = [:]
    private var cachedStatus = PrinterStatus()
    private var gotReport = false
    private var events: [PrinterEvent] = []
    private var lastPushAll = Date.distantPast
    private var pingTimer: DispatchSourceTimer?
    private var packetID: UInt16 = 1
    private var sequence = 100

    public init(connection: PrinterConnection) {
        self.connection = connection
    }

    deinit {
        pingTimer?.cancel()
        mqtt?.cancel()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private var serial: String { (connection.serial ?? "").trimmingCharacters(in: .whitespaces).uppercased() }
    private var accessCode: String { (connection.apiKey ?? "").trimmingCharacters(in: .whitespaces) }

    private func log(_ level: PrinterEvent.Level, _ message: String) {
        locked {
            events.append(PrinterEvent(level: level, message: message, source: "Bambu Lab"))
            if events.count > 300 { events.removeFirst(events.count - 300) }
        }
    }

    // MARK: Connection

    private func ensureConnected() async throws {
        if locked({ connected && mqtt != nil }) { return }
        guard !serial.isEmpty else { throw PrinterError.http(0, "Bitte die Seriennummer des Druckers eintragen (steht auf dem Typenschild).") }
        guard !accessCode.isEmpty else { throw PrinterError.http(0, "Bitte den Zugangscode eintragen (Drucker: Einstellungen → WLAN / LAN-Modus).") }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let conn = NWConnection(host: NWEndpoint.Host(connection.hostOnly), port: NWEndpoint.Port(rawValue: mqttPort) ?? 8883, using: NWParameters(tls: tls))
        locked { mqtt?.cancel(); mqtt = conn; decoder = MQTTCodec.Decoder() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            locked { connAck = cont }
            conn.stateUpdateHandler = { [weak self, weak conn] state in
                guard let self, let conn else { return }
                switch state {
                case .ready:
                    self.send(MQTTCodec.connect(clientID: "makerslice-\(UUID().uuidString.prefix(8))", username: "bblp", password: self.accessCode, keepAlive: 60))
                    self.receiveLoop(conn)
                case .failed(let error): self.handleDisconnect(error.localizedDescription, from: conn)
                case .cancelled: self.handleDisconnect(nil, from: conn)
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self else { return }
                let pending: CheckedContinuation<Void, Error>? = self.locked { let c = self.connAck; self.connAck = nil; return c }
                pending?.resume(throwing: PrinterError.unreachable("Keine Antwort vom Drucker – LAN-Modus an? Gleiches WLAN?"))
            }
        }
        send(MQTTCodec.subscribe(topic: "device/\(serial)/report", packetID: nextPacketID()))
        startPing()
        log(.info, "Verbunden mit dem Drucker (LAN-Modus)")
        pushAll()
    }

    private func nextPacketID() -> UInt16 {
        locked { packetID = packetID == UInt16.max ? 1 : packetID + 1; return packetID }
    }

    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.send(MQTTCodec.pingReq) }
        timer.resume()
        locked { pingTimer?.cancel(); pingTimer = timer }
    }

    private func handleDisconnect(_ reason: String?, from conn: NWConnection) {
        let (wasConnected, ack, pending): (Bool, CheckedContinuation<Void, Error>?, [CheckedContinuation<(result: String, reason: String), Error>]) = locked {
            guard mqtt === conn else { return (false, nil, []) }
            let w = connected
            connected = false
            mqtt = nil
            let a = connAck
            connAck = nil
            let ws = Array(waiters.values)
            waiters.removeAll()
            return (w, a, ws)
        }
        let error = PrinterError.unreachable(reason ?? "Verbindung getrennt")
        ack?.resume(throwing: error)
        pending.forEach { $0.resume(throwing: error) }
        if wasConnected { log(.warning, "Verbindung zum Drucker getrennt" + (reason.map { ": \($0)" } ?? "")) }
    }

    public func disconnect() {
        let conn: NWConnection? = locked { pingTimer?.cancel(); pingTimer = nil; let c = mqtt; mqtt = nil; connected = false; return c }
        conn?.send(content: MQTTCodec.disconnect, completion: .contentProcessed { _ in conn?.cancel() })
    }

    private func send(_ data: Data) {
        let conn = locked { mqtt }
        conn?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var packets: [MQTTPacket] = []
                self.locked {
                    self.decoder.append(data)
                    while let p = self.decoder.next() { packets.append(p) }
                }
                packets.forEach(self.handle)
            }
            if error != nil || isComplete { self.handleDisconnect(error?.localizedDescription, from: conn); return }
            self.receiveLoop(conn)
        }
    }

    private func handle(_ packet: MQTTPacket) {
        switch packet {
        case .connAck(let code):
            let cont: CheckedContinuation<Void, Error>? = locked { let c = connAck; connAck = nil; if code == 0 { connected = true }; return c }
            if code == 0 { cont?.resume() }
            else {
                let why = (code == 4 || code == 5) ? "Zugangscode falsch." : "MQTT-Code \(code)"
                cont?.resume(throwing: PrinterError.http(Int(code), why))
            }
        case .publish(_, let payload, let qos, let id):
            if qos > 0, let id { send(MQTTCodec.pubAck(packetID: id)) }
            handleReport(payload)
        default: break
        }
    }

    private func handleReport(_ payload: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
        if let print = json["print"] as? [String: Any] {
            // Acknowledgement of a command.
            if let seq = print["sequence_id"] as? String, let result = print["result"] as? String, print["command"] != nil, print["gcode_state"] == nil || print["command"] as? String != "push_status" {
                let waiter: CheckedContinuation<(result: String, reason: String), Error>? = locked { waiters.removeValue(forKey: seq) }
                waiter?.resume(returning: (result, print["reason"] as? String ?? ""))
            }
            locked {
                let before = cachedStatus.state
                cachedStatus.applyBambu(print)
                if print["gcode_state"] != nil { gotReport = true }
                if before != cachedStatus.state, before != .unknown {
                    events.append(PrinterEvent(level: cachedStatus.state == .error ? .error : .info, message: "Status: \(cachedStatus.state.displayName)", source: "Bambu Lab"))
                }
                if let code = jsonNumber(print["print_error"]), code != 0, let text = cachedStatus.stateMessage { events.append(PrinterEvent(level: .error, message: text, source: "Bambu Lab")) }
            }
        }
        if let info = json["info"] as? [String: Any], let modules = info["module"] as? [[String: Any]] {
            locked {
                if let ota = modules.first(where: { ($0["name"] as? String) == "ota" }) { cachedStatus.firmware = ota["sw_ver"] as? String }
            }
        }
    }

    // MARK: Commands

    private func nextSequence() -> String {
        locked { sequence += 1; return String(sequence) }
    }

    private func publish(_ object: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }
        send(MQTTCodec.publish(topic: "device/\(serial)/request", payload: body))
    }

    private func pushAll() {
        locked { lastPushAll = Date() }
        publish(["pushing": ["sequence_id": nextSequence(), "command": "pushall"]])
        publish(["info": ["sequence_id": nextSequence(), "command": "get_version"]])
    }

    /// Sends a `print` command and waits for the printer's answer.
    private func printCommand(_ command: String, extra: [String: Any] = [:]) async throws {
        try await ensureConnected()
        let seq = nextSequence()
        var body: [String: Any] = ["sequence_id": seq, "command": command]
        extra.forEach { body[$0.key] = $0.value }
        let answer: (result: String, reason: String) = try await withCheckedThrowingContinuation { cont in
            locked { waiters[seq] = cont }
            publish(["print": body])
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                let w: CheckedContinuation<(result: String, reason: String), Error>? = self?.locked { self?.waiters.removeValue(forKey: seq) }
                w?.resume(throwing: PrinterError.unreachable("Keine Bestätigung vom Drucker"))
            }
        }
        if answer.result != "success" {
            log(.error, "\(command) abgelehnt: \(answer.reason)")
            throw PrinterError.http(0, "Befehl \(command) abgelehnt\(answer.reason.isEmpty ? "" : " (\(answer.reason))")")
        }
    }

    // MARK: PrinterDriver

    public func status() async throws -> PrinterStatus {
        try await ensureConnected()
        if Date().timeIntervalSince(locked { lastPushAll }) > 20 { pushAll() }
        for _ in 0..<40 where !locked({ gotReport }) { try await Task.sleep(nanoseconds: 100_000_000) }
        return locked { cachedStatus }
    }

    public func upload(gcode: Data, fileName: String, startPrint: Bool, mapping: [SlotMapping]) async throws {
        try await ensureConnected()
        let base = (fileName as NSString).deletingPathExtension.replacingOccurrences(of: ".gcode", with: "")
        let safe = base.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let package = BambuPackage.make(gcode: gcode, name: base)
        let remote = "\(safe).gcode.3mf"
        try await BambuFTPS(host: connection.hostOnly, port: ftpsPort, accessCode: accessCode).upload(package, name: remote)
        log(.info, "Datei \(remote) hochgeladen (\(package.count / 1024) KB)")
        guard startPrint else { return }

        let md5 = LANCrypto.md5([UInt8](gcode)).map { String(format: "%02X", $0) }.joined()
        let hasAMS = !(locked { cachedStatus.filaments }).isEmpty
        // Filament index in the file → AMS slot (254 = external spool).
        let tools = mapping.map(\.tool)
        var amsMapping = [Int](repeating: -1, count: (tools.max() ?? 0) + 1)
        for m in mapping where amsMapping.indices.contains(m.tool) { amsMapping[m.tool] = hasAMS ? m.slot : 254 }
        if amsMapping.isEmpty { amsMapping = [hasAMS ? 0 : 254] }
        try await printCommand("project_file", extra: [
            "param": "Metadata/plate_1.gcode",
            "project_id": "0", "profile_id": "0", "task_id": "0", "subtask_id": "0",
            "subtask_name": base,
            "file": "", "url": "file:///sdcard/\(remote)", "md5": md5,
            "timelapse": false, "bed_type": "auto", "bed_leveling": true, "flow_cali": false,
            "vibration_cali": true, "layer_inspect": false, "use_ams": hasAMS, "ams_mapping": amsMapping,
        ])
        log(.info, "Druck von \(base) gestartet")
    }

    public func pause() async throws { try await printCommand("pause", extra: ["param": ""]) }
    public func resume() async throws { try await printCommand("resume", extra: ["param": ""]) }
    public func cancel() async throws { try await printCommand("stop", extra: ["param": ""]) }

    private func gcodeLine(_ line: String) async throws { try await printCommand("gcode_line", extra: ["param": line + "\n"]) }

    public var speedControl: SpeedControl { .modes }
    /// "print_speed": 1 silent, 2 standard, 3 sport (4 "ludicrous" is not offered).
    public func setSpeedMode(_ mode: Int) async throws {
        try await printCommand("print_speed", extra: ["param": String(min(max(mode, 1), 3))])
    }

    public func setBedTemperature(_ t: Int) async throws { try await gcodeLine("M140 S\(t)") }
    public func setToolTemperature(tool: Int, _ t: Int) async throws { try await gcodeLine("M104 S\(t)") }

    public var filamentControl: FilamentControlSupport {
        FilamentControlSupport(extrude: true, loadSlot: true, unload: true,
                               note: "Laden und Entladen heizt die Düse selbst auf. Das AMS muss angeschlossen sein; ohne AMS geht nur Vorschieben und Zurückziehen.")
    }

    public func extrude(millimetres: Double) async throws {
        try await requireHotNozzle()
        try await gcodeLine(FilamentMove.script(millimetres: millimetres))
    }

    /// "ams_change_filament": the printer heats the nozzle, unloads the old filament and feeds the slot (255 = unload only).
    private func changeFilament(target: Int) async throws {
        let s = try await status()
        guard s.state != .printing && s.state != .paused else { throw PrinterError.unsupported("Während eines Drucks lässt sich das Filament nicht wechseln.") }
        let temp = Int(max(s.tools.first?.target ?? 0, 220))
        try await printCommand("ams_change_filament", extra: ["target": target, "curr_temp": Int(s.tools.first?.temperature ?? 0), "tar_temp": temp])
    }

    public func loadSlot(_ slot: Int) async throws {
        guard (0..<4).contains(slot) else { throw PrinterError.unsupported("Ungültiger Slot.") }
        try await changeFilament(target: slot)
    }

    public func unloadFilament() async throws { try await changeFilament(target: 255) }

    public func setLight(_ on: Bool) async throws {
        try await ensureConnected()
        publish(["system": ["sequence_id": nextSequence(), "command": "ledctrl", "led_node": "chamber_light", "led_mode": on ? "on" : "off",
                            "led_on_time": 500, "led_off_time": 500, "loop_times": 0, "interval_time": 0]])
    }

    public func calibration() async throws -> CalibrationData {
        let s = try await status()
        var cal = CalibrationData()
        if let fw = s.firmware { cal.notes.append(("Firmware", fw)) }
        cal.notes.append(("Hinweis", "Der P1S legt Bett-Kalibrierung und Pressure Advance selbst im Drucker ab; über den LAN-Modus werden sie nicht übertragen."))
        return cal
    }

    public func recentEvents() async throws -> [PrinterEvent] { locked { events } }
}
#endif
