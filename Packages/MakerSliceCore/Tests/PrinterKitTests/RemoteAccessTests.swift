import XCTest
@testable import PrinterKit

final class RemoteAccessTests: XCTestCase {
    func testTailnetAndPrivateAddresses() throws {
        XCTAssertTrue(RemoteAccess.isTailnetAddress("100.101.102.103"))
        XCTAssertTrue(RemoteAccess.isTailnetAddress("100.64.0.1"))
        XCTAssertTrue(RemoteAccess.isTailnetAddress("100.127.255.254"))
        XCTAssertFalse(RemoteAccess.isTailnetAddress("100.128.0.1"))
        XCTAssertFalse(RemoteAccess.isTailnetAddress("100.63.255.255"))
        XCTAssertTrue(RemoteAccess.isTailnetAddress("snapmaker-u1.tail1234.ts.net"))
        XCTAssertFalse(RemoteAccess.isTailnetAddress("192.168.68.57"))

        let lan = try XCTUnwrap(RemoteAccess.parseIPv4("192.168.68.57"))
        XCTAssertTrue(RemoteAccess.isPrivateAddress(lan))
        XCTAssertTrue(RemoteAccess.isPrivateAddress(try XCTUnwrap(RemoteAccess.parseIPv4("10.0.0.5"))))
        XCTAssertTrue(RemoteAccess.isPrivateAddress(try XCTUnwrap(RemoteAccess.parseIPv4("172.20.1.1"))))
        XCTAssertFalse(RemoteAccess.isPrivateAddress(try XCTUnwrap(RemoteAccess.parseIPv4("172.32.1.1"))))
        XCTAssertFalse(RemoteAccess.isPrivateAddress(try XCTUnwrap(RemoteAccess.parseIPv4("8.8.8.8"))))
        XCTAssertNil(RemoteAccess.parseIPv4("192.168.1"))
        XCTAssertNil(RemoteAccess.parseIPv4("192.168.1.256"))
        XCTAssertNil(RemoteAccess.parseIPv4("u1.local"))
    }

    func testRemoteConnectionKeepsEverythingButTheAddress() throws {
        var c = PrinterConnection(name: "U1", host: "192.168.68.57", apiKey: "k", remoteHost: " 100.90.1.2 ")
        let remote = try XCTUnwrap(c.remote)
        XCTAssertEqual(remote.host, "100.90.1.2")
        XCTAssertEqual(remote.id, c.id)
        XCTAssertEqual(remote.apiKey, "k")
        XCTAssertEqual(remote.baseURL?.absoluteString, "http://100.90.1.2:7125")
        c.remoteHost = "  "
        XCTAssertNil(c.remote, "an empty field means no remote address")
        c.remoteHost = "192.168.68.57"
        XCTAssertNil(c.remote, "the home address is no second way")
    }

    func testOldSavedPrintersStillLoad() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"U1","host":"192.168.68.57","model":"snapmakerU1","kind":"moonraker"}"#
        let c = try JSONDecoder().decode(PrinterConnection.self, from: Data(json.utf8))
        XCTAssertNil(c.remoteHost)
        var withRemote = c
        withRemote.remoteHost = "u1.tail.ts.net"
        let back = try JSONDecoder().decode(PrinterConnection.self, from: JSONEncoder().encode(withRemote))
        XCTAssertEqual(back.remoteHost, "u1.tail.ts.net")
    }

    func testRouteOrder() {
        XCTAssertEqual(RemoteAccess.order(last: nil, hasRemote: false, sinceHomeTry: 999), [.home])
        XCTAssertEqual(RemoteAccess.order(last: .remote, hasRemote: false, sinceHomeTry: 0), [.home])
        XCTAssertEqual(RemoteAccess.order(last: nil, hasRemote: true, sinceHomeTry: 999), [.home, .remote])
        XCTAssertEqual(RemoteAccess.order(last: .remote, hasRemote: true, sinceHomeTry: 10), [.remote, .home],
                       "on the way: the remote address first")
        XCTAssertEqual(RemoteAccess.order(last: .remote, hasRemote: true, sinceHomeTry: 61), [.home, .remote],
                       "every minute the home address gets a chance again")
    }

    func testProbePorts() {
        XCTAssertEqual(RemoteAccess.probePort(for: PrinterConnection(name: "U1", host: "192.168.1.5")), 7125)
        XCTAssertEqual(RemoteAccess.probePort(for: PrinterConnection(name: "U1", host: "192.168.1.5:7200")), 7200)
        XCTAssertEqual(RemoteAccess.probePort(for: PrinterConnection(name: "K", host: "192.168.1.6", kind: .anycubicLAN)), 18910)
        XCTAssertEqual(RemoteAccess.probePort(for: PrinterConnection(name: "P", host: "192.168.1.7", kind: .bambuLAN)), 8883)
    }
}
