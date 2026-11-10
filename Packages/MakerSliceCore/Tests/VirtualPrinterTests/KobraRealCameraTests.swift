import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PrinterKit
import SliceKit
import XCTest

/// Starts the camera of a REAL Kobra S1 (nothing else), reads a few seconds of the FLV stream and stops the camera.
/// Run with: REAL_KOBRA_HOST=192.168.x.y REAL_KOBRA_CAMERA=1 swift test --filter KobraRealCameraTests
#if canImport(Network)
final class KobraRealCameraTests: XCTestCase {
    func testStartCameraAndReadStream() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["REAL_KOBRA_HOST"], env["REAL_KOBRA_CAMERA"] == "1" else { throw XCTSkip("REAL_KOBRA_HOST/REAL_KOBRA_CAMERA not set") }
        let client = AnycubicLANClient(connection: PrinterConnection(name: "Kobra S1", host: host,
                                                                       model: PrinterModel.kobraS1.rawValue, kind: .anycubicLAN))
        _ = try await client.status()
        do { try await client.startCamera(); print("startCapture: bestätigt") } catch { print("startCapture: \(error)") }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        for (type, data) in client.latestRawReports().sorted(by: { $0.key < $1.key }) where type == "video" || type == "camera" {
            print("=== RAW \(type) ===\n\(String(data: data, encoding: .utf8) ?? "?")")
        }
        defer { Task { try? await client.stopCamera() } }

        var request = URLRequest(url: URL(string: "http://\(host):18088/flv")!)
        request.timeoutInterval = 15
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        print("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) \((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "")")
        var data = Data()
        let started = Date()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 400_000 || Date().timeIntervalSince(started) > 8 { break }
        }
        let path = env["REAL_KOBRA_OUT"] ?? "/tmp/kobra_cam.flv"
        try data.write(to: URL(fileURLWithPath: path))
        print("FLV: \(data.count) Bytes, Anfang \(data.prefix(4).map { String(format: "%02x", $0) }.joined()) → \(path)")
        try? await client.stopCamera()
        client.disconnect()
    }
}
#endif
