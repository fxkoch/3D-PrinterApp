import Foundation
@testable import PrinterKit
import XCTest

final class NetworkScannerTests: XCTestCase {
    func testSubnetHostsNearestFirst() {
        let address: UInt32 = 192 << 24 | 168 << 16 | 68 << 8 | 73
        let mask: UInt32 = 0xFFFF_FC00   // /22 like a typical mesh router network
        let list = NetworkScanner.hosts(address: address, mask: mask)
        XCTAssertEqual(list.count, 1021)   // 1022 usable addresses minus the device itself
        XCTAssertEqual(NetworkScanner.dotted(list[0]), "192.168.68.72")
        XCTAssertFalse(list.contains(address))
        XCTAssertTrue(list.map(NetworkScanner.dotted).contains("192.168.68.79"))
        XCTAssertTrue(list.map(NetworkScanner.dotted).contains("192.168.71.254"))
        XCTAssertFalse(list.map(NetworkScanner.dotted).contains("192.168.68.0"))
        // A /16 is cut to the 1022 addresses closest to the device.
        XCTAssertEqual(NetworkScanner.hosts(address: address, mask: 0xFFFF_0000).count, 1022)
    }

    /// Needs the virtual Kobra S1 (KOBRA_HOST=127.0.0.1 with tools/virtualprinters/kobra_s1_sim.py running).
    func testFindsTheVirtualKobra() async throws {
        guard let host = ProcessInfo.processInfo.environment["KOBRA_HOST"] else { throw XCTSkip("KOBRA_HOST not set") }
        let found = await NetworkScanner.probe(host: host)
        let printer = try XCTUnwrap(found)
        XCTAssertEqual(printer.kind, .anycubicLAN)
        XCTAssertTrue(printer.looksLikeKobraS1, printer.modelText)

        var results: [DiscoveredPrinter] = []
        for await p in NetworkScanner.scan(hostsToCheck: [host, "127.0.0.2"]) { results.append(p) }
        XCTAssertEqual(results.map(\.host), [host])
    }

    func testNothingFoundOnAnUnusedAddress() async {
        let found = await NetworkScanner.probe(host: "127.0.0.1", port: 1, moonrakerPort: 2, timeout: 0.5)
        XCTAssertNil(found)
    }
}

/// Scans the real local network (read-only requests to ports 18910 and 7125). REAL_SCAN=1 swift test --filter NetworkScannerRealTests
final class NetworkScannerRealTests: XCTestCase {
    func testScanLocalNetwork() async throws {
        guard ProcessInfo.processInfo.environment["REAL_SCAN"] == "1" else { throw XCTSkip("REAL_SCAN not set") }
        let local = try XCTUnwrap(NetworkScanner.localIPv4(), "no local IPv4 address")
        print("Netz: \(NetworkScanner.dotted(local.address)) / \(NetworkScanner.dotted(local.mask))")
        let started = Date()
        var found: [DiscoveredPrinter] = []
        for await printer in NetworkScanner.scan() { found.append(printer); print("GEFUNDEN: \(printer)") }
        print("Suche dauerte \(Int(Date().timeIntervalSince(started))) s, \(found.count) Drucker")
    }
}
