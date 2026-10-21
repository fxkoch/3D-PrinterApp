import Foundation

/// Reads an FLV byte stream (as the Kobra S1 camera delivers it over HTTP) and extracts the H.264 video.
/// Feed bytes as they arrive; complete video frames come back as `Event`s.
public struct FLVDemuxer {
    public enum Event: Equatable, Sendable {
        /// Decoder setup from the stream's first video packet.
        case config(sps: [UInt8], pps: [UInt8], nalLengthSize: Int)
        /// One video frame in AVCC format (each NAL unit prefixed with its length).
        case frame(data: [UInt8], timestampMS: Int, keyframe: Bool)
    }

    private var buffer: [UInt8] = []
    private var headerRead = false

    public init() {}

    /// Appends received bytes and returns the events found so far.
    public mutating func feed(_ bytes: [UInt8]) -> [Event] {
        buffer.append(contentsOf: bytes)
        var events: [Event] = []
        var pos = 0
        if !headerRead {
            guard buffer.count >= 13 else { return [] }
            guard buffer[0] == 0x46, buffer[1] == 0x4C, buffer[2] == 0x56 else {   // "FLV"
                buffer.removeAll()
                return []
            }
            let offset = Int(buffer[5]) << 24 | Int(buffer[6]) << 16 | Int(buffer[7]) << 8 | Int(buffer[8])
            pos = offset + 4   // header + PreviousTagSize0
            headerRead = true
        }
        while buffer.count - pos >= 11 {
            let type = buffer[pos]
            let size = Int(buffer[pos + 1]) << 16 | Int(buffer[pos + 2]) << 8 | Int(buffer[pos + 3])
            let timestamp = Int(buffer[pos + 4]) << 16 | Int(buffer[pos + 5]) << 8 | Int(buffer[pos + 6]) | Int(buffer[pos + 7]) << 24
            let end = pos + 11 + size
            guard buffer.count >= end + 4 else { break }   // wait for the whole tag and its trailer
            if type == 9, size > 5 {
                let body = Array(buffer[(pos + 11)..<end])
                let codec = body[0] & 0x0F, frameType = body[0] >> 4
                if codec == 7 {   // AVC
                    let packetType = body[1]
                    let payload = Array(body[5...])
                    if packetType == 0 {
                        if let config = FLVDemuxer.parseAVCConfig(payload) { events.append(config) }
                    } else if packetType == 1 {
                        events.append(.frame(data: payload, timestampMS: timestamp, keyframe: frameType == 1))
                    }
                }
            }
            pos = end + 4
        }
        if pos > 0 { buffer.removeFirst(pos) }
        // Never let a broken stream grow without bound.
        if buffer.count > 8_000_000 { buffer.removeAll(); headerRead = true }
        return events
    }

    /// AVCDecoderConfigurationRecord → SPS, PPS and the NAL length field size.
    static func parseAVCConfig(_ d: [UInt8]) -> Event? {
        guard d.count > 8, d[0] == 1 else { return nil }
        let nalLength = Int(d[4] & 3) + 1
        let spsCount = Int(d[5] & 0x1F)
        var p = 6
        var sps: [UInt8]?
        for _ in 0..<spsCount {
            guard p + 2 <= d.count else { return nil }
            let n = Int(d[p]) << 8 | Int(d[p + 1])
            p += 2
            guard p + n <= d.count else { return nil }
            if sps == nil { sps = Array(d[p..<(p + n)]) }
            p += n
        }
        guard p < d.count else { return nil }
        let ppsCount = Int(d[p])
        p += 1
        var pps: [UInt8]?
        for _ in 0..<ppsCount {
            guard p + 2 <= d.count else { return nil }
            let n = Int(d[p]) << 8 | Int(d[p + 1])
            p += 2
            guard p + n <= d.count else { return nil }
            if pps == nil { pps = Array(d[p..<(p + n)]) }
            p += n
        }
        guard let sps, let pps else { return nil }
        return .config(sps: sps, pps: pps, nalLengthSize: nalLength)
    }
}
