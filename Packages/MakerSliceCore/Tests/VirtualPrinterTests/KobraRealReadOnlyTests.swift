import Foundation
@testable import PrinterKit
import SliceKit
import XCTest

/// Reads a REAL Kobra S1 in LAN mode – status queries only (handshake, MQTT connect, info/temperature/fan/light/ACE queries).
/// Never sends print, heat, pause, cancel or file commands.
/// Run with: REAL_KOBRA_HOST=192.168.x.y swift test --filter KobraRealReadOnlyTests
#if canImport(Network)
final class KobraRealReadOnlyTests: XCTestCase {
    func testReadStatus() async throws {
        guard let host = ProcessInfo.processInfo.environment["REAL_KOBRA_HOST"] else { throw XCTSkip("REAL_KOBRA_HOST not set") }
        let client = AnycubicLANClient(connection: PrinterConnection(name: "Kobra S1", host: host,
                                                                       model: PrinterModel.kobraS1.rawValue, kind: .anycubicLAN))
        let status = try await client.status()
        try await Task.sleep(nanoseconds: 4_000_000_000)   // let all reports arrive
        let status2 = try await client.status()
        print("=== PARSED STATUS ===\n\(status2)\n(first: \(status.state))")
        for (type, data) in client.latestRawReports().sorted(by: { $0.key < $1.key }) {
            print("=== RAW \(type) ===\n\(String(data: data, encoding: .utf8) ?? "?")")
        }
        print("=== EVENTS ===")
        for e in try await client.recentEvents() { print("\(e.level) \(e.message)") }
        client.disconnect()
    }
}
#endif
