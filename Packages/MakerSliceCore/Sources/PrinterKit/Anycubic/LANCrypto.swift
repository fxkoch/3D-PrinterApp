import Foundation

/// Small, dependency-free MD5 and AES-128-CBC (decrypt) for the Anycubic LAN
/// handshake. Both are only used to talk to the printer, not for security of
/// user data.
enum LANCrypto {
    // MARK: MD5 (RFC 1321)

    static func md5Hex(_ string: String) -> String {
        md5(Array(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func md5(_ message: [UInt8]) -> [UInt8] {
        let s: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                           5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                           4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                           6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
        let k: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4294967296.0)) }
        var a0: UInt32 = 0x67452301, b0: UInt32 = 0xefcdab89, c0: UInt32 = 0x98badcfe, d0: UInt32 = 0x10325476

        var msg = message
        let bitLength = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in 0..<8 { msg.append(UInt8((bitLength >> (8 * UInt64(i))) & 0xff)) }

        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let j = chunk + i * 4
                m[i] = UInt32(msg[j]) | UInt32(msg[j + 1]) << 8 | UInt32(msg[j + 2]) << 16 | UInt32(msg[j + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32
                let g: Int
                switch i {
                case 0..<16: f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ k[i] &+ m[g]
                a = d; d = c; c = b
                b = b &+ ((f << s[i]) | (f >> (32 - s[i])))
            }
            a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ d
        }
        return [a0, b0, c0, d0].flatMap { v in (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
    }

    // MARK: AES-128 (FIPS-197), CBC decryption with PKCS#7 padding

    private static let sbox: [UInt8] = {
        var s = [UInt8](repeating: 0, count: 256)
        var p: UInt8 = 1, q: UInt8 = 1
        repeat {
            // Multiply p by 3, divide q by 3 in GF(2^8).
            p = p ^ (p << 1) ^ ((p & 0x80) != 0 ? 0x1b : 0)
            q ^= q << 1; q ^= q << 2; q ^= q << 4
            if (q & 0x80) != 0 { q ^= 0x09 }
            let x = q ^ rotl(q, 1) ^ rotl(q, 2) ^ rotl(q, 3) ^ rotl(q, 4)
            s[Int(p)] = x ^ 0x63
        } while p != 1
        s[0] = 0x63
        return s
    }()

    private static let invSbox: [UInt8] = {
        var inv = [UInt8](repeating: 0, count: 256)
        for (i, v) in sbox.enumerated() { inv[Int(v)] = UInt8(i) }
        return inv
    }()

    private static func rotl(_ x: UInt8, _ n: UInt8) -> UInt8 { (x << n) | (x >> (8 - n)) }

    private static func xtime(_ x: UInt8) -> UInt8 { (x << 1) ^ ((x & 0x80) != 0 ? 0x1b : 0) }

    private static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = a, b = b, r: UInt8 = 0
        while b != 0 {
            if b & 1 != 0 { r ^= a }
            a = xtime(a)
            b >>= 1
        }
        return r
    }

    static func expandKey(_ key: [UInt8]) -> [[UInt8]] {
        precondition(key.count == 16)
        var w = [[UInt8]]()
        for i in 0..<4 { w.append(Array(key[(i * 4)..<(i * 4 + 4)])) }
        var rcon: UInt8 = 1
        for i in 4..<44 {
            var t = w[i - 1]
            if i % 4 == 0 {
                t = [sbox[Int(t[1])] ^ rcon, sbox[Int(t[2])], sbox[Int(t[3])], sbox[Int(t[0])]]
                rcon = xtime(rcon)
            }
            w.append(zip(w[i - 4], t).map { $0 ^ $1 })
        }
        // Round keys as 16-byte blocks (column-major, matching the state layout).
        return (0..<11).map { r in (0..<4).flatMap { w[r * 4 + $0] } }
    }

    static func decryptBlock(_ input: [UInt8], roundKeys: [[UInt8]]) -> [UInt8] {
        var s = zip(input, roundKeys[10]).map { $0 ^ $1 }
        for round in stride(from: 9, through: 0, by: -1) {
            // Inverse shift rows (state is column-major: index = col*4 + row).
            var t = s
            for r in 1..<4 {
                for c in 0..<4 { t[((c + r) % 4) * 4 + r] = s[c * 4 + r] }
            }
            s = t.map { invSbox[Int($0)] }
            s = zip(s, roundKeys[round]).map { $0 ^ $1 }
            if round > 0 {
                for c in 0..<4 {
                    let a0 = s[c * 4], a1 = s[c * 4 + 1], a2 = s[c * 4 + 2], a3 = s[c * 4 + 3]
                    s[c * 4] = mul(a0, 14) ^ mul(a1, 11) ^ mul(a2, 13) ^ mul(a3, 9)
                    s[c * 4 + 1] = mul(a0, 9) ^ mul(a1, 14) ^ mul(a2, 11) ^ mul(a3, 13)
                    s[c * 4 + 2] = mul(a0, 13) ^ mul(a1, 9) ^ mul(a2, 14) ^ mul(a3, 11)
                    s[c * 4 + 3] = mul(a0, 11) ^ mul(a1, 13) ^ mul(a2, 9) ^ mul(a3, 14)
                }
            }
        }
        return s
    }

    static func encryptBlock(_ input: [UInt8], roundKeys: [[UInt8]]) -> [UInt8] {
        var s = zip(input, roundKeys[0]).map { $0 ^ $1 }
        for round in 1...10 {
            s = s.map { sbox[Int($0)] }
            var t = s
            for r in 1..<4 {
                for c in 0..<4 { t[c * 4 + r] = s[((c + r) % 4) * 4 + r] }
            }
            s = t
            if round < 10 {
                for c in 0..<4 {
                    let a0 = s[c * 4], a1 = s[c * 4 + 1], a2 = s[c * 4 + 2], a3 = s[c * 4 + 3]
                    s[c * 4] = mul(a0, 2) ^ mul(a1, 3) ^ a2 ^ a3
                    s[c * 4 + 1] = a0 ^ mul(a1, 2) ^ mul(a2, 3) ^ a3
                    s[c * 4 + 2] = a0 ^ a1 ^ mul(a2, 2) ^ mul(a3, 3)
                    s[c * 4 + 3] = mul(a0, 3) ^ a1 ^ a2 ^ mul(a3, 2)
                }
            }
            s = zip(s, roundKeys[round]).map { $0 ^ $1 }
        }
        return s
    }

    enum CryptoError: Error { case badLength, badPadding }

    static func aes128CBCDecrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        guard data.count % 16 == 0, !data.isEmpty, key.count == 16, iv.count == 16 else { throw CryptoError.badLength }
        let keys = expandKey(key)
        var previous = iv
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        for start in stride(from: 0, to: data.count, by: 16) {
            let block = Array(data[start..<(start + 16)])
            out += zip(decryptBlock(block, roundKeys: keys), previous).map { $0 ^ $1 }
            previous = block
        }
        guard let pad = out.last, pad >= 1, pad <= 16, out.suffix(Int(pad)).allSatisfy({ $0 == pad }) else {
            throw CryptoError.badPadding
        }
        return Array(out.dropLast(Int(pad)))
    }

    /// Used by tests to build fixtures.
    static func aes128CBCEncrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8] {
        let keys = expandKey(key)
        let pad = 16 - data.count % 16
        let padded = data + [UInt8](repeating: UInt8(pad), count: pad)
        var previous = iv
        var out: [UInt8] = []
        for start in stride(from: 0, to: padded.count, by: 16) {
            let block = zip(Array(padded[start..<(start + 16)]), previous).map { $0 ^ $1 }
            previous = encryptBlock(block, roundKeys: keys)
            out += previous
        }
        return out
    }
}
