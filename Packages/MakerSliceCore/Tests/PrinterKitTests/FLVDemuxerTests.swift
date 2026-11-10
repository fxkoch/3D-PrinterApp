@testable import PrinterKit
import XCTest

final class FLVDemuxerTests: XCTestCase {
    private func tag(type: UInt8, timestamp: Int, body: [UInt8]) -> [UInt8] {
        let size = body.count
        var out: [UInt8] = [type, UInt8(size >> 16 & 255), UInt8(size >> 8 & 255), UInt8(size & 255),
                            UInt8(timestamp >> 16 & 255), UInt8(timestamp >> 8 & 255), UInt8(timestamp & 255), UInt8(timestamp >> 24 & 255),
                            0, 0, 0]
        out += body
        let total = 11 + size
        out += [UInt8(total >> 24 & 255), UInt8(total >> 16 & 255), UInt8(total >> 8 & 255), UInt8(total & 255)]
        return out
    }

    private var stream: [UInt8] {
        let header: [UInt8] = [0x46, 0x4C, 0x56, 1, 5, 0, 0, 0, 9, 0, 0, 0, 0]
        let sps: [UInt8] = [0x67, 0x64, 0x00, 0x1F, 0xAC]
        let pps: [UInt8] = [0x68, 0xEE, 0x3C, 0x80]
        // AVCDecoderConfigurationRecord: version, profile, compat, level, 0xFF (4-byte NAL lengths), 1 SPS, 1 PPS
        var avcc: [UInt8] = [1, 0x64, 0, 0x1F, 0xFF, 0xE1, 0, UInt8(sps.count)] + sps + [1, 0, UInt8(pps.count)] + pps
        let configTag = tag(type: 9, timestamp: 0, body: [0x17, 0, 0, 0, 0] + avcc)
        avcc = []
        let nal: [UInt8] = [0x65, 1, 2, 3, 4, 5]
        let key = tag(type: 9, timestamp: 40, body: [0x17, 1, 0, 0, 0, 0, 0, 0, UInt8(nal.count)] + nal)
        let inter = tag(type: 9, timestamp: 140, body: [0x27, 1, 0, 0, 0, 0, 0, 0, 3, 0x41, 9, 9])
        let audio = tag(type: 8, timestamp: 60, body: [0xAF, 1, 0x21, 0x10])
        return header + configTag + audio + key + inter
    }

    func testParsesConfigAndFrames() {
        var demux = FLVDemuxer()
        let events = demux.feed(stream)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0], .config(sps: [0x67, 0x64, 0x00, 0x1F, 0xAC], pps: [0x68, 0xEE, 0x3C, 0x80], nalLengthSize: 4))
        XCTAssertEqual(events[1], .frame(data: [0, 0, 0, 6, 0x65, 1, 2, 3, 4, 5], timestampMS: 40, keyframe: true))
        XCTAssertEqual(events[2], .frame(data: [0, 0, 0, 3, 0x41, 9, 9], timestampMS: 140, keyframe: false))
    }

    func testWorksWithBytesArrivingInSmallPieces() {
        var demux = FLVDemuxer()
        var all: [FLVDemuxer.Event] = []
        let data = stream
        var i = 0
        while i < data.count {
            let n = min(7, data.count - i)
            all += demux.feed(Array(data[i..<(i + n)]))
            i += n
        }
        XCTAssertEqual(all.count, 3)
    }

    func testIgnoresNonFLVData() {
        var demux = FLVDemuxer()
        XCTAssertTrue(demux.feed(Array("ok".utf8) + Array(repeating: 0, count: 20)).isEmpty)
    }
}

/// Checks a real capture: REAL_FLV=/path/to/capture.flv swift test --filter FLVDemuxerRealTests
final class FLVDemuxerRealTests: XCTestCase {
    func testRealCapture() throws {
        guard let path = ProcessInfo.processInfo.environment["REAL_FLV"] else { throw XCTSkip("REAL_FLV not set") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var demux = FLVDemuxer()
        var events: [FLVDemuxer.Event] = []
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count { events += demux.feed(Array(bytes[i..<min(i + 1400, bytes.count)])); i += 1400 }
        var configs = 0, frames = 0, keys = 0, last = 0
        for e in events {
            switch e {
            case .config(let sps, let pps, let n): configs += 1; print("config sps=\(sps.count)B pps=\(pps.count)B nalLength=\(n)")
            case .frame(_, let t, let key): frames += 1; if key { keys += 1 }; last = t
            }
        }
        print("Frames: \(frames), Keyframes: \(keys), Konfigurationen: \(configs), letzter Zeitstempel: \(last) ms")
        XCTAssertGreaterThan(configs, 0)
        XCTAssertGreaterThan(frames, 10)
    }
}
