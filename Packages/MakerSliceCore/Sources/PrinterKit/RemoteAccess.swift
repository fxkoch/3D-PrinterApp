import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Reaching the printers away from home: through a VPN (Tailscale) that either routes the home network
/// (the printer keeps its home address) or gives the printer an address of its own (`PrinterConnection.remoteHost`).
public enum RemoteAccess {
    /// How the app reached a printer the last time.
    public enum Route: String, Sendable, Equatable {
        case home
        case remote
    }

    /// Tailscale gives every device an address from 100.64.0.0/10 (carrier-grade NAT range).
    public static func isTailnetAddress(_ ip: UInt32) -> Bool {
        ip & 0xFFC0_0000 == 0x6440_0000
    }

    public static func isTailnetAddress(_ text: String) -> Bool {
        parseIPv4(text).map(isTailnetAddress) ?? text.lowercased().hasSuffix(".ts.net")
    }

    /// Addresses of home networks (10/8, 172.16/12, 192.168/16) – not reachable from the internet without a VPN.
    public static func isPrivateAddress(_ ip: UInt32) -> Bool {
        ip >> 24 == 10 || ip & 0xFFF0_0000 == 0xAC10_0000 || ip >> 16 == 0xC0A8
    }

    public static func parseIPv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var ip: UInt32 = 0
        for p in parts {
            guard let v = UInt32(p), v < 256, !p.isEmpty else { return nil }
            ip = ip << 8 | v
        }
        return ip
    }

    /// This device's own Tailscale address, when the Tailscale VPN is switched on.
    public static func tailnetAddress() -> String? {
        #if canImport(Darwin)
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer?.pointee {
            defer { pointer = entry.ifa_next }
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if isTailnetAddress(ip) { return NetworkScanner.dotted(ip) }
        }
        return nil
        #else
        return nil
        #endif
    }

    /// The TCP port that answers when the printer is there (no data is sent).
    public static func probePort(for connection: PrinterConnection) -> UInt16 {
        switch connection.kind {
        case .moonraker: return UInt16(connection.baseURL?.port ?? NetworkScanner.moonrakerPort)
        case .anycubicLAN: return UInt16(NetworkScanner.kobraPort)
        case .bambuLAN: return 8883
        }
    }

    /// Quick check whether the printer answers at this connection's address.
    public static func answers(_ connection: PrinterConnection, timeout: TimeInterval = 2) async -> Bool {
        await NetworkScanner.tcpOpen(host: connection.hostOnly, port: probePort(for: connection), timeout: timeout)
    }

    /// Which way to try first: the one that worked last; the home address again after a while on the remote one
    /// (back home, the direct way is faster and does not need the VPN).
    public static func order(last: Route?, hasRemote: Bool, sinceHomeTry: TimeInterval) -> [Route] {
        guard hasRemote else { return [.home] }
        if last == .remote, sinceHomeTry < 60 { return [.remote, .home] }
        return [.home, .remote]
    }
}
