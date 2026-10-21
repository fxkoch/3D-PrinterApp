import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#endif

/// A printer found on the local network.
public struct DiscoveredPrinter: Identifiable, Hashable, Sendable {
    public var id: String { host }
    public var name: String
    public var host: String
    public var kind: ConnectionKind
    /// Model text reported by the device ("Anycubic Kobra S1", Klipper hostname …).
    public var modelText: String
    /// Hint for the user (e.g. LAN mode is switched off).
    public var note: String?

    public init(name: String, host: String, kind: ConnectionKind, modelText: String, note: String? = nil) {
        self.name = name
        self.host = host
        self.kind = kind
        self.modelText = modelText
        self.note = note
    }

    /// Best guess which of the app's printer models this is.
    public var looksLikeKobraS1: Bool { modelText.lowercased().contains("kobra s1") || modelText.lowercased().contains("kobra-s1") }
    public var looksLikeSnapmaker: Bool {
        let t = modelText.lowercased()
        return t.contains("snapmaker") || t.contains("u1")
    }
}

/// Finds Kobra S1 (LAN mode, port 18910) and Moonraker/Klipper printers (port 7125) by asking every address of the
/// local network – no IP address has to be typed in. Only harmless read requests are sent.
public enum NetworkScanner {
    public static let kobraPort = 18910
    public static let moonrakerPort = 7125

    /// All usable host addresses of the subnet around `address` (at most `limit`, nearest to the device first).
    public static func hosts(address: UInt32, mask: UInt32, limit: Int = 1022) -> [UInt32] {
        let network = address & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }
        var all = Array((network + 1)..<broadcast).filter { $0 != address }
        if all.count > limit {
            all.sort { abs(Int64($0) - Int64(address)) < abs(Int64($1) - Int64(address)) }
            all = Array(all.prefix(limit))
        }
        return all.sorted { abs(Int64($0) - Int64(address)) < abs(Int64($1) - Int64(address)) }
    }

    public static func dotted(_ ip: UInt32) -> String {
        "\(ip >> 24 & 255).\(ip >> 16 & 255).\(ip >> 8 & 255).\(ip & 255)"
    }

    /// IPv4 address and netmask of the Wi-Fi (or Ethernet) interface.
    public static func localIPv4() -> (address: UInt32, mask: UInt32)? {
        #if canImport(Darwin)
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var best: (UInt32, UInt32)?
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer?.pointee {
            defer { pointer = entry.ifa_next }
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), let netmask = entry.ifa_netmask else { continue }
            let name = String(cString: entry.ifa_name)
            guard name == "en0" || name.hasPrefix("en") else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if best == nil || name == "en0" { best = (ip, mask) }
        }
        return best.map { (address: $0.0, mask: $0.1) }
        #else
        return nil
        #endif
    }

    private static func session(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    private static func json(_ url: String, session: URLSession) async -> [String: Any]? {
        guard let url = URL(string: url) else { return nil }
        guard let (data, response) = try? await session.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Asks one address whether a printer answers there (both printer types are asked at the same time).
    public static func probe(host: String, port kobraPort: Int = NetworkScanner.kobraPort,
                             moonrakerPort: Int = NetworkScanner.moonrakerPort, timeout: TimeInterval = 1.5) async -> DiscoveredPrinter? {
        let session = session(timeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        async let kobraInfo = json("http://\(host):\(kobraPort)/info", session: session)
        async let moonrakerInfo = json("http://\(host):\(moonrakerPort)/server/info", session: session)
        let (kobra, moonraker) = await (kobraInfo, moonrakerInfo)
        // Anycubic LAN handshake endpoint (also answers when LAN mode is off, with ctrlType "cloud").
        if let info = kobra, info["modelName"] != nil || info["deviceType"] != nil {
            let model = info["modelName"] as? String ?? "Anycubic"
            let name = info["deviceName"] as? String ?? model
            let lanOff = (info["ctrlType"] as? String) == "cloud"
            return DiscoveredPrinter(name: name, host: host, kind: .anycubicLAN, modelText: model,
                                     note: lanOff ? "LAN-Modus ist am Drucker ausgeschaltet (Einstellungen → Netzwerk)." : nil)
        }
        // Klipper/Moonraker.
        if let server = moonraker, server["result"] != nil {
            var hostname = host
            if let printer = await json("http://\(host):\(moonrakerPort)/printer/info", session: session),
               let name = (printer["result"] as? [String: Any])?["hostname"] as? String, !name.isEmpty {
                hostname = name
            }
            return DiscoveredPrinter(name: hostname, host: host, kind: .moonraker, modelText: hostname)
        }
        return nil
    }

    /// Scans the local subnet; each found printer is delivered as soon as it answers.
    /// `progress` gets the fraction of addresses checked.
    public static func scan(hostsToCheck: [String]? = nil, concurrency: Int = 128,
                            progress: (@Sendable (Double) -> Void)? = nil) -> AsyncStream<DiscoveredPrinter> {
        AsyncStream { continuation in
            let task = Task {
                var list = hostsToCheck ?? []
                if list.isEmpty, let local = localIPv4() {
                    list = hosts(address: local.address, mask: local.mask).map(dotted)
                }
                let total = max(list.count, 1)
                var next = 0, done = 0
                await withTaskGroup(of: DiscoveredPrinter?.self) { group in
                    func launch() {
                        guard next < list.count, !Task.isCancelled else { return }
                        let host = list[next]
                        next += 1
                        group.addTask { await probe(host: host) }
                    }
                    for _ in 0..<min(concurrency, list.count) { launch() }
                    while let result = await group.next() {
                        done += 1
                        if let result { continuation.yield(result) }
                        progress?(Double(done) / Double(total))
                        launch()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
