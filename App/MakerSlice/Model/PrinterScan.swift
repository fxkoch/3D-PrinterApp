import Foundation
import Observation
import PrinterKit

/// Looks for printers on the local network: Bonjour announcements plus a scan of every address of the subnet.
@MainActor
@Observable
final class PrinterScan {
    private(set) var found: [DiscoveredPrinter] = []
    private(set) var scanning = false
    private(set) var progress = 0.0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let bonjour = PrinterDiscovery()
    @ObservationIgnored private var bonjourTask: Task<Void, Never>?

    func start() {
        stop()
        found = []
        progress = 0
        scanning = true
        bonjour.start()
        bonjourTask = Task { [weak self] in
            // Bonjour answers within a few seconds; merge what it learned.
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                for item in self.bonjour.printers {
                    self.add(DiscoveredPrinter(name: item.name, host: item.host, kind: .moonraker, modelText: item.name))
                }
            }
        }
        task = Task { [weak self] in
            // UI tests scan only the virtual printer on this Mac instead of the whole network.
            let args = ProcessInfo.processInfo.arguments
            let only = args.firstIndex(of: "-uiTestScanHost").flatMap { args.indices.contains($0 + 1) ? [args[$0 + 1]] : nil }
            // The first pass may run into iOS's "allow local network" question; if nothing was found, ask again.
            for pass in 1...2 {
                let stream = NetworkScanner.scan(hostsToCheck: only) { fraction in
                    Task { @MainActor in self?.progress = fraction }
                }
                for await printer in stream {
                    guard let self else { return }
                    self.add(printer)
                }
                guard let self, !Task.isCancelled else { return }
                if !self.found.isEmpty || pass == 2 { break }
            }
            self?.scanning = false
            self?.bonjour.stop()
        }
    }

    func stop() {
        task?.cancel()
        bonjourTask?.cancel()
        bonjour.stop()
        scanning = false
    }

    private func add(_ printer: DiscoveredPrinter) {
        if let index = found.firstIndex(where: { $0.host == printer.host }) {
            // The scan knows more than Bonjour (model, LAN mode).
            if printer.kind == .anycubicLAN || found[index].kind != .anycubicLAN { found[index] = printer }
        } else {
            found.append(printer)
        }
    }
}
