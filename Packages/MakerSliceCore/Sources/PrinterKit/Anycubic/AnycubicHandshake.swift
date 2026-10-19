import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// LAN-mode handshake of Anycubic printers (Kobra S1 & co.), as documented by the
/// community projects anycubic-lan and anycubic_ha_local:
/// GET :18910/info → signed POST to ctrlInfoUrl → AES-decrypt the MQTT credentials.
public enum AnycubicHandshake {
    public static let discoveryPort = 18910
    public static let topicPrefix = "anycubic/anycubicCloud/v1"

    public struct Discovery: Sendable, Equatable {
        public var token: String
        public var ctrlInfoURL: String
        public var modelID: Int
        public var modelName: String?
        public var serial: String?
    }

    public struct Credentials: Sendable, Equatable {
        public var host: String
        public var port: Int
        public var username: String
        public var password: String
        public var deviceID: String
        public var modelID: Int
        public var modelName: String?
    }

    public enum HandshakeError: Error, LocalizedError, Equatable {
        case lanModeOff
        case unsupported(String)
        case rejected(String)
        case badResponse(String)

        public var errorDescription: String? {
            switch self {
            case .lanModeOff: return "Der LAN-Modus ist am Drucker ausgeschaltet. Einstellungen → Netzwerk → LAN-Modus einschalten."
            case .unsupported(let why): return "Drucker wird nicht unterstützt: \(why)"
            case .rejected(let why): return "Der Drucker hat die Verbindung abgelehnt: \(why)"
            case .badResponse(let why): return "Unerwartete Antwort vom Drucker: \(why)"
            }
        }
    }

    static func parseDiscovery(_ json: [String: Any]) throws -> Discovery {
        if json["ctrlType"] as? String == "cloud" { throw HandshakeError.lanModeOff }
        guard let token = json["token"] as? String, token.count == 32,
              let ctrl = json["ctrlInfoUrl"] as? String, !ctrl.isEmpty else {
            throw HandshakeError.unsupported("Token oder Steuer-URL fehlen")
        }
        let model: Int
        if let m = json["modelId"] as? Int { model = m } else if let s = json["modelId"] as? String, let m = Int(s) { model = m } else {
            throw HandshakeError.unsupported("modelId fehlt")
        }
        return Discovery(token: token, ctrlInfoURL: ctrl, modelID: model, modelName: json["modelName"] as? String,
                         serial: json["cn"] as? String)
    }

    /// `md5_hex(md5_hex(token[:16]) + ts + nonce)`.
    static func signature(token: String, ts: Int64, nonce: String) -> String {
        let key = String(token.prefix(16))
        return LANCrypto.md5Hex(LANCrypto.md5Hex(key) + String(ts) + nonce)
    }

    static func controlURL(_ d: Discovery, ts: Int64, nonce: String, did: String) -> String {
        let sep = d.ctrlInfoURL.contains("?") ? "&" : "?"
        return "\(d.ctrlInfoURL)\(sep)ts=\(ts)&nonce=\(nonce)&sign=\(signature(token: d.token, ts: ts, nonce: nonce))&did=\(did)"
    }

    static func parseControlResponse(_ json: [String: Any], discovery d: Discovery) throws -> Credentials {
        let code = jsonNumber(json["code"]).map(Int.init)
        guard code == 200 else { throw HandshakeError.rejected(json["message"] as? String ?? "Code \(code ?? -1)") }
        guard let data = json["data"] as? [String: Any], let info = data["info"] as? String,
              let ivSource = data["token"] as? String, let cipher = Data(base64Encoded: info) else {
            throw HandshakeError.badResponse("Zugangsdaten fehlen")
        }
        let key = Array(d.token.utf8.dropFirst(16).prefix(16))
        var iv = Array(ivSource.utf8.prefix(16))
        while iv.count < 16 { iv.append(0) }
        let plain: [UInt8]
        do {
            plain = try LANCrypto.aes128CBCDecrypt([UInt8](cipher), key: key, iv: iv)
        } catch {
            throw HandshakeError.badResponse("Entschlüsselung fehlgeschlagen")
        }
        guard let creds = try? JSONSerialization.jsonObject(with: Data(plain)) as? [String: Any],
              let broker = creds["broker"] as? String, let user = creds["username"] as? String,
              let pass = creds["password"] as? String, let device = creds["deviceId"] as? String,
              !device.contains("/"), !device.contains("#"), !device.contains("+") else {
            throw HandshakeError.badResponse("Zugangsdaten unvollständig")
        }
        guard let url = URLComponents(string: broker), let host = url.host else {
            throw HandshakeError.badResponse("Broker-Adresse ungültig")
        }
        return Credentials(host: host, port: url.port ?? 9883, username: user, password: pass, deviceID: device,
                           modelID: d.modelID, modelName: d.modelName)
    }

    /// Runs the full handshake against `host` (IP or name).
    public static func perform(host: String, session: URLSession = .shared) async throws -> Credentials {
        guard let infoURL = URL(string: "http://\(host):\(discoveryPort)/info") else { throw PrinterError.invalidAddress }
        var request = URLRequest(url: infoURL)
        request.timeoutInterval = 8
        let (infoData, _) = try await fetch(request, session: session)
        guard let infoJSON = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any] else {
            throw HandshakeError.badResponse("Info ist kein JSON")
        }
        let discovery = try parseDiscovery(infoJSON)
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let alnum = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        let nonce = String((0..<6).map { _ in alnum.randomElement()! })
        let did = String((0..<32).map { _ in Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").randomElement()! })
        guard let ctrlURL = URL(string: controlURL(discovery, ts: ts, nonce: nonce, did: did)),
              ctrlURL.scheme == "http" || ctrlURL.scheme == "https" else {
            throw HandshakeError.badResponse("Steuer-URL ungültig")
        }
        var post = URLRequest(url: ctrlURL)
        post.httpMethod = "POST"
        post.timeoutInterval = 8
        let (ctrlData, _) = try await fetch(post, session: session)
        guard let ctrlJSON = try? JSONSerialization.jsonObject(with: ctrlData) as? [String: Any] else {
            throw HandshakeError.badResponse("Antwort ist kein JSON")
        }
        return try parseControlResponse(ctrlJSON, discovery: discovery)
    }

    private static func fetch(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw HandshakeError.badResponse("HTTP \(http.statusCode)")
            }
            return (data, response)
        } catch let error as URLError {
            throw PrinterError.unreachable(error.localizedDescription)
        }
    }

    /// Body for `/gcode_upload?s=…` (field names as used by Anycubic Slicer Next).
    static func uploadBody(gcode: Data, fileName: String, boundary: String) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"filename\"\r\n\r\n\(fileName)\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"gcode\"; filename=\"\(fileName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(gcode)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// MQTT payload that starts an uploaded file, with ACE slot mapping.
    static func startPayload(fileName: String, md5: String, size: Int, mapping: [SlotMapping], msgID: String, now: Int64) -> [String: Any] {
        let boxMapping: [[String: Any]] = mapping.map { m in
            let rgba = m.color.count >= 4 ? Array(m.color.prefix(4)) : m.color + [255]
            return ["paint_index": m.tool, "ams_index": m.slot, "paint_color": rgba, "ams_color": rgba,
                    "material_type": m.materialType]
        }
        var data: [String: Any] = [
            "taskid": "-1", "url": "", "filename": fileName, "md5": md5, "filepath": NSNull(),
            "filetype": 1, "project_type": 1, "filesize": size,
            "task_settings": [
                "auto_leveling": 1, "vibration_compensation": 0, "flow_calibration": 0, "dry_mode": 0,
                "ai_settings": ["status": 0, "count": 0, "type": 0],
                "timelapse": ["status": 0, "count": 0, "type": 0],
                "drying_settings": ["status": 0, "target_temp": 0, "duration": 0, "remain_time": 0],
                "model_objects_skip_parts": [Any](),
            ] as [String: Any],
        ]
        if !boxMapping.isEmpty {
            data["ams_settings"] = ["use_ams": true, "ams_box_mapping": boxMapping] as [String: Any]
        }
        return ["type": "print", "action": "start", "msgid": msgID, "timestamp": now, "data": data]
    }
}
