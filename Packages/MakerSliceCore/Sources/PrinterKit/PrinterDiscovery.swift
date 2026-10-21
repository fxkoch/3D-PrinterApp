#if canImport(Network)
import Foundation
import Network

/// Finds Snapmaker printers on the local network via Bonjour.
/// The U1 firmware advertises `_snapmaker._tcp`; generic Klipper hosts may use `_moonraker._tcp`.
/// Requires `NSLocalNetworkUsageDescription` and `NSBonjourServices` in Info.plist.
@MainActor
public final class PrinterDiscovery: ObservableObject {
    public struct Found: Identifiable, Hashable, Sendable {
        public var id: String { name }
        public var name: String
        public var host: String
    }

    @Published public private(set) var printers: [Found] = []
    @Published public private(set) var isSearching = false

    private var browsers: [NWBrowser] = []
    private var resolvers: [NWConnection] = []

    public init() {}

    public func start() {
        stop()
        isSearching = true
        for type in ["_snapmaker._tcp", "_moonraker._tcp"] {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in self?.handle(results) }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    public func stop() {
        browsers.forEach { $0.cancel() }
        resolvers.forEach { $0.cancel() }
        browsers.removeAll()
        resolvers.removeAll()
        isSearching = false
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint,
                  !printers.contains(where: { $0.name == name }) else { continue }
            resolve(result.endpoint, name: name)
        }
    }

    /// Opens a short connection to learn the IP address behind the service.
    private func resolve(_ endpoint: NWEndpoint, name: String) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state, let path = connection?.currentPath,
                  case let .hostPort(host, _) = path.remoteEndpoint else { return }
            func withoutZone(_ s: String) -> String { s.split(separator: "%").first.map(String.init) ?? s }
            let hostString: String
            switch host {
            case .ipv4(let addr): hostString = withoutZone("\(addr)")
            case .ipv6(let addr): hostString = "[\(withoutZone("\(addr)"))]"
            case .name(let n, _): hostString = n
            @unknown default: hostString = "\(host)"
            }
            connection?.cancel()
            Task { @MainActor in
                guard let self, !self.printers.contains(where: { $0.name == name }) else { return }
                self.printers.append(Found(name: name, host: hostString))
            }
        }
        connection.start(queue: .main)
        resolvers.append(connection)
    }
}
#endif
