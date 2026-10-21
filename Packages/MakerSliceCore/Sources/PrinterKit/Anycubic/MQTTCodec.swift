import Foundation

/// Minimal MQTT 3.1.1 packet encoder/decoder (QoS 0/1), enough for the
/// Anycubic LAN broker.
enum MQTTPacket: Equatable {
    case connAck(returnCode: UInt8)
    case subAck(packetID: UInt16)
    case publish(topic: String, payload: Data, qos: UInt8, packetID: UInt16?)
    case pubAck(packetID: UInt16)
    case pingResp
    case other(type: UInt8)
}

enum MQTTCodec {
    static func connect(clientID: String, username: String?, password: String?, keepAlive: UInt16) -> Data {
        var variable = Data()
        variable.append(string("MQTT"))
        variable.append(4) // protocol level 3.1.1
        var flags: UInt8 = 0x02 // clean session
        if username != nil { flags |= 0x80 }
        if password != nil { flags |= 0x40 }
        variable.append(flags)
        variable.append(UInt8(keepAlive >> 8)); variable.append(UInt8(keepAlive & 0xff))
        var payload = string(clientID)
        if let username { payload.append(string(username)) }
        if let password { payload.append(string(password)) }
        return packet(0x10, variable + payload)
    }

    static func subscribe(topic: String, packetID: UInt16, qos: UInt8 = 0) -> Data {
        var body = Data([UInt8(packetID >> 8), UInt8(packetID & 0xff)])
        body.append(string(topic))
        body.append(qos)
        return packet(0x82, body)
    }

    static func publish(topic: String, payload: Data) -> Data {
        packet(0x30, string(topic) + payload)
    }

    static func pubAck(packetID: UInt16) -> Data {
        packet(0x40, Data([UInt8(packetID >> 8), UInt8(packetID & 0xff)]))
    }

    static let pingReq = Data([0xC0, 0x00])
    static let disconnect = Data([0xE0, 0x00])

    static func string(_ s: String) -> Data {
        let bytes = Array(s.utf8)
        return Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xff)] + bytes)
    }

    static func packet(_ header: UInt8, _ body: Data) -> Data {
        var out = Data([header])
        var length = body.count
        repeat {
            var byte = UInt8(length % 128)
            length /= 128
            if length > 0 { byte |= 0x80 }
            out.append(byte)
        } while length > 0
        out.append(body)
        return out
    }

    /// Accumulates bytes from the socket and yields complete packets.
    struct Decoder {
        private var buffer = Data()

        mutating func append(_ data: Data) {
            buffer.append(data)
        }

        mutating func next() -> MQTTPacket? {
            let bytes = [UInt8](buffer.prefix(5))
            guard bytes.count >= 2 else { return nil }
            var multiplier = 1, length = 0, index = 1
            while true {
                guard index < bytes.count else { return nil }
                let b = Int(bytes[index])
                length += (b & 0x7f) * multiplier
                multiplier *= 128
                index += 1
                if b & 0x80 == 0 { break }
                if index > 4 { buffer.removeAll(); return nil } // malformed
            }
            guard buffer.count >= index + length else { return nil }
            let header = bytes[0]
            let body = Data(buffer.dropFirst(index).prefix(length))
            buffer = Data(buffer.dropFirst(index + length))
            return Self.parse(header: header, body: [UInt8](body))
        }

        static func parse(header: UInt8, body: [UInt8]) -> MQTTPacket {
            switch header >> 4 {
            case 2:
                return .connAck(returnCode: body.count >= 2 ? body[1] : 0xff)
            case 9:
                return .subAck(packetID: body.count >= 2 ? UInt16(body[0]) << 8 | UInt16(body[1]) : 0)
            case 3:
                guard body.count >= 2 else { return .other(type: 3) }
                let qos = (header >> 1) & 0x03
                let topicLength = Int(body[0]) << 8 | Int(body[1])
                guard body.count >= 2 + topicLength else { return .other(type: 3) }
                let topic = String(decoding: body[2..<(2 + topicLength)], as: UTF8.self)
                var offset = 2 + topicLength
                var packetID: UInt16?
                if qos > 0, body.count >= offset + 2 {
                    packetID = UInt16(body[offset]) << 8 | UInt16(body[offset + 1])
                    offset += 2
                }
                return .publish(topic: topic, payload: Data(body[offset...]), qos: qos, packetID: packetID)
            case 4:
                return .pubAck(packetID: body.count >= 2 ? UInt16(body[0]) << 8 | UInt16(body[1]) : 0)
            case 13:
                return .pingResp
            default:
                return .other(type: header >> 4)
            }
        }
    }
}
