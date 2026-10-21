#if canImport(Network)
import Foundation
import Network

/// Implicit FTPS (port 990) as Bambu Lab printers offer it: user "bblp", the access code as password, passive mode,
/// protected data channel. Only what is needed to store one file on the printer's SD card.
final class BambuFTPS: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let accessCode: String
    private let queue = DispatchQueue(label: "BambuFTPS")
    private var control: NWConnection?
    private var buffer = Data()

    init(host: String, port: UInt16 = 990, accessCode: String) {
        self.host = host
        self.port = port
        self.accessCode = accessCode
    }

    private func tlsParameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        // The printer's certificate is self-signed (issued by Bambu Lab's printer CA).
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        return NWParameters(tls: tls)
    }

    private func open(port: UInt16) async throws -> NWConnection {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw PrinterError.invalidAddress }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: tlsParameters())
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NWConnection, Error>) in
            let once = Once()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.fire() { cont.resume(returning: conn) }
                case .failed(let e): if once.fire() { cont.resume(throwing: PrinterError.unreachable(e.localizedDescription)) }
                case .cancelled: if once.fire() { cont.resume(throwing: PrinterError.unreachable("Verbindung abgebrochen")) }
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { if once.fire() { conn.cancel(); cont.resume(throwing: PrinterError.unreachable("Keine Antwort vom FTPS-Server")) } }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    private func receive(_ conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let error { cont.resume(throwing: PrinterError.unreachable(error.localizedDescription)) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if complete { cont.resume(throwing: PrinterError.unreachable("Verbindung vom Drucker geschlossen")) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    private func send(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: PrinterError.unreachable(error.localizedDescription)) } else { cont.resume() }
            })
        }
    }

    /// One complete reply (multi-line replies end with "NNN text").
    private func reply() async throws -> (code: Int, text: String) {
        guard let conn = control else { throw PrinterError.unreachable("Nicht verbunden") }
        var lines: [String] = []
        while true {
            while let range = buffer.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: buffer.subdata(in: buffer.startIndex..<range.lowerBound), as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                lines.append(line)
                if line.count >= 4, let code = Int(line.prefix(3)), line[line.index(line.startIndex, offsetBy: 3)] == " " {
                    return (code, lines.joined(separator: "\n"))
                }
            }
            buffer.append(try await receive(conn))
        }
    }

    @discardableResult
    private func command(_ line: String, expect: ClosedRange<Int> = 200...399) async throws -> (code: Int, text: String) {
        guard let conn = control else { throw PrinterError.unreachable("Nicht verbunden") }
        try await send(conn, Data((line + "\r\n").utf8))
        let r = try await reply()
        guard expect.contains(r.code) else { throw PrinterError.http(r.code, Self.explain(r.code, r.text, command: line)) }
        return r
    }

    private static func explain(_ code: Int, _ text: String, command: String) -> String {
        if code == 530 { return "Zugangscode falsch." }
        if command.hasPrefix("STOR") { return "Datei konnte nicht gespeichert werden – ist eine microSD-Karte im Drucker? (\(text))" }
        return text
    }

    /// Stores `data` as `name` in the printer's root folder.
    func upload(_ data: Data, name: String) async throws {
        control = try await open(port: port)
        defer { control?.cancel(); control = nil; buffer = Data() }
        let hello = try await reply()
        guard hello.code == 220 else { throw PrinterError.http(hello.code, hello.text) }
        try await command("USER bblp", expect: 230...331)
        try await command("PASS \(accessCode)", expect: 230...230)
        try await command("PBSZ 0")
        try await command("PROT P")
        try await command("TYPE I")
        let pasv = try await command("PASV", expect: 227...227)
        guard let dataPort = Self.passivePort(pasv.text) else { throw PrinterError.badResponse }
        let dataConn = try await open(port: dataPort)
        guard let conn = control else { throw PrinterError.unreachable("Nicht verbunden") }
        try await send(conn, Data("STOR \(name)\r\n".utf8))
        let start = try await reply()
        guard (100...199).contains(start.code) else { dataConn.cancel(); throw PrinterError.http(start.code, Self.explain(start.code, start.text, command: "STOR")) }
        var offset = 0
        let chunk = 64 * 1024
        while offset < data.count {
            try await send(dataConn, data.subdata(in: offset..<min(offset + chunk, data.count)))
            offset += chunk
        }
        // Closing the data channel tells the server the file is complete.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            dataConn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in cont.resume() })
        }
        dataConn.cancel()
        let done = try await reply()
        guard done.code == 226 || done.code == 250 else { throw PrinterError.http(done.code, Self.explain(done.code, done.text, command: "STOR")) }
        _ = try? await command("QUIT", expect: 200...299)
    }

    /// Port from "227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)".
    static func passivePort(_ text: String) -> UInt16? {
        guard let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")"), open < close else { return nil }
        let numbers = text[text.index(after: open)..<close].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 6 else { return nil }
        return UInt16(numbers[4] * 256 + numbers[5])
    }
}
#endif
