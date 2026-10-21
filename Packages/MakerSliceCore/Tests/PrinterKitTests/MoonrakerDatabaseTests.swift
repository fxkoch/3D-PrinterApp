import Foundation
@testable import PrinterKit
import XCTest

/// Stand-in for Moonraker's `/server/database/item`.
final class FakeMoonrakerDB: URLProtocol {
    nonisolated(unsafe) static var store: [String: Any] = [:]
    nonisolated(unsafe) static var requests: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        Self.requests.append("\(request.httpMethod ?? "GET") \(url.path)")
        var code = 200
        var body: [String: Any] = [:]
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func query(_ name: String) -> String { comps?.queryItems?.first { $0.name == name }?.value ?? "" }
        if request.httpMethod == "POST" {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 65536)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                stream.close()
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            Self.store["\(json["namespace"] ?? "")/\(json["key"] ?? "")"] = json["value"]
            body = ["result": ["namespace": json["namespace"] ?? "", "key": json["key"] ?? "", "value": json["value"] ?? NSNull()]]
        } else if let value = Self.store["\(query("namespace"))/\(query("key"))"] {
            body = ["result": ["namespace": query("namespace"), "key": query("key"), "value": value]]
        } else {
            code = 404
            body = ["error": ["code": 404, "message": "Key not found"]]
        }
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class MoonrakerDatabaseTests: XCTestCase {
    func testStoreAndReadBackANote() async throws {
        FakeMoonrakerDB.store = [:]
        FakeMoonrakerDB.requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeMoonrakerDB.self]
        let client = MoonrakerClient(connection: PrinterConnection(name: "U1", host: "192.168.1.5", model: "snapmakerU1", kind: .moonraker),
                                     session: URLSession(configuration: config))
        let missing = try await client.storedValue(key: "calibration")
        XCTAssertNil(missing, "nothing stored yet is not an error")

        let note = Data(#"[{"printer":"snapmakerU1","filament":"Generic PETG","kind":"temperature","value":237,"date":"2026-10-21T08:00:00Z"}]"#.utf8)
        try await client.store(value: note, key: "calibration")
        let back = try await client.storedValue(key: "calibration")
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(back)) as? [[String: Any]])
        XCTAssertEqual(list.first?["value"] as? Int, 237)
        XCTAssertEqual(FakeMoonrakerDB.requests, ["GET /server/database/item", "POST /server/database/item", "GET /server/database/item"],
                       "only database reads and one database write – nothing that prints, heats or moves")
    }
}
