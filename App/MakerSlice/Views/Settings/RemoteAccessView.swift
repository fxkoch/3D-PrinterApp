import PrinterKit
import SliceKit
import SwiftUI

/// Using the printers away from home: status of every printer, and the steps to set up Tailscale.
struct RemoteAccessView: View {
    @Environment(AppModel.self) private var app
    @State private var tailnet = RemoteAccess.tailnetAddress()
    @State private var home = NetworkScanner.localIPv4()
    @State private var testing = false
    @State private var tested: Date?

    private static let tailscaleAppStore = URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!
    private static let adminRoutes = URL(string: "https://login.tailscale.com/admin/machines")!

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: tailnet != nil ? "lock.shield.fill" : "lock.shield")
                        .font(.title2)
                        .foregroundStyle(tailnet != nil ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tailnet != nil ? "Tailscale ist an" : "Tailscale ist aus").font(.headline)
                        Text(tailnet.map { "Dieses iPhone: \($0)" } ?? "Ohne Tailscale erreicht die App die Drucker nur im Heim-WLAN.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("tailscaleState")
                ForEach(app.printers.printers) { printer in
                    PrinterRouteRow(printer: printer, homeNetwork: home)
                }
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Label("Verbindung testen", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        if testing { ProgressView() } else if let tested { Text(tested, style: .time).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .disabled(testing || app.printers.printers.isEmpty)
                .accessibilityIdentifier("remoteTest")
            } header: {
                Text("Jetzt")
            }

            Section {
                step(1, "Tailscale aufs iPhone", "Kostenlos im App Store. Mit Apple-, Google- oder Microsoft-Konto anmelden – kein Passwort für die Drucker nötig.") {
                    Link(destination: Self.tailscaleAppStore) { Label("Im App Store öffnen", systemImage: "arrow.down.app") }
                }
                step(2, "Zuhause eine Brücke einrichten", bridgeText) {
                    EmptyView()
                }
                step(3, "Heimnetz freigeben", "In der Tailscale-Verwaltung beim Brücken-Gerät „Edit route settings“ öffnen und \(subnet) erlauben. Danach erreichst du unterwegs alle Drucker unter ihren gewohnten Adressen.") {
                    Link(destination: Self.adminRoutes) { Label("Tailscale-Verwaltung öffnen", systemImage: "safari") }
                }
                step(4, "Unterwegs: Tailscale einschalten", "In der Tailscale-App oder in den iPhone-Einstellungen unter VPN. Die App merkt selbst, ob du zuhause oder unterwegs bist.") {
                    EmptyView()
                }
            } header: {
                Text("Einrichten (einmalig)")
            } footer: {
                Text("Tailscale verbindet dein iPhone verschlüsselt mit deinem Heimnetz. Am Router wird nichts geöffnet, die Drucker bleiben aus dem Internet unsichtbar.")
            }

            Section {
                Text("Hat ein Drucker in Tailscale eine eigene Adresse (z. B. 100.x.y.z oder einen Namen), trag sie beim Drucker unter „Bearbeiten → Adresse unterwegs“ ein. Die App nimmt dann zuhause die WLAN-Adresse und unterwegs diese.")
                    .font(.callout)
            } header: {
                Text("Ohne Heimnetz-Freigabe")
            }

            Section {
                Label("Drucken, Live-Status, Kamera, Pause und Abbruch funktionieren unterwegs wie zuhause. Die Kamera kann über Mobilfunk langsamer sein.", systemImage: "checkmark.circle")
                Label("Mitteilungen bei geschlossener App kommen unterwegs nur, wenn Tailscale an ist.", systemImage: "bell.badge")
                Label("Die Brücke muss eingeschaltet sein. Ist der Drucker selbst die Brücke, ist er unterwegs nur erreichbar, solange er an ist.", systemImage: "power")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Fernzugriff")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshNetwork() }
        .refreshable { await test() }
    }

    private var bridgeText: String {
        let hasU1 = app.printers.printers.contains { app.printers.model(of: $0) == .snapmakerU1 }
        return (hasU1 ? "Am einfachsten übernimmt das dein Snapmaker U1 selbst: Tailscale läuft auf dem Drucker und gibt das Heimnetz frei – damit sind auch die anderen Drucker unterwegs erreichbar. Claude richtet das am Mac für dich ein, wenn du zustimmst. " : "")
            + "Alternativ ein Gerät, das immer an ist: ein Mac, ein Raspberry Pi oder ein Router mit Tailscale, eingerichtet als „Subnet Router“ für \(subnet)."
    }

    /// The home network the printers are in (from the Wi-Fi when at home, else from the printer addresses).
    private var subnet: String {
        let ips = app.printers.printers.compactMap { RemoteAccess.parseIPv4($0.hostOnly) }.filter(RemoteAccess.isPrivateAddress)
        if let home, let ip = ips.first, ip & home.mask == home.address & home.mask {
            let bits = home.mask.nonzeroBitCount
            return "\(NetworkScanner.dotted(home.address & home.mask))/\(bits)"
        }
        if let ip = ips.first { return "\(NetworkScanner.dotted(ip & 0xFFFF_FF00))/24" }
        return "dein Heimnetz (z. B. 192.168.1.0/24)"
    }

    private func step<Extra: View>(_ n: Int, _ title: String, _ text: String, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.subheadline.weight(.bold))
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                extra().font(.callout)
            }
        }
        .padding(.vertical, 4)
    }

    private func refreshNetwork() {
        tailnet = RemoteAccess.tailnetAddress()
        home = NetworkScanner.localIPv4()
    }

    private func test() async {
        testing = true
        refreshNetwork()
        await app.printers.refreshAll()
        tested = Date()
        testing = false
    }
}

/// One printer: reached at home, on the way (through the VPN or its remote address), or not at all.
private struct PrinterRouteRow: View {
    @Environment(AppModel.self) private var app
    let printer: PrinterConnection
    let homeNetwork: (address: UInt32, mask: UInt32)?

    var body: some View {
        let (text, color, icon) = state
        HStack {
            Image(systemName: icon).foregroundStyle(color).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(printer.name)
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("route-\(printer.name)")
    }

    private var state: (String, Color, String) {
        guard app.printers.isOnline(printer) else {
            return (app.printers.errors[printer.id].map { "Nicht erreichbar – \($0)" } ?? "Wird gesucht …", .secondary, "wifi.slash")
        }
        if app.printers.isRemote(printer) {
            return ("Unterwegs über \(printer.remoteAddress ?? "Tailscale")", .blue, "globe")
        }
        guard let ip = RemoteAccess.parseIPv4(printer.hostOnly) else {
            return ("Verbunden (\(printer.hostOnly))", .green, "checkmark.circle.fill")
        }
        if let home = homeNetwork, ip & home.mask == home.address & home.mask {
            return ("Zuhause im WLAN (\(printer.hostOnly))", .green, "house.fill")
        }
        return ("Unterwegs über das freigegebene Heimnetz (\(printer.hostOnly))", .blue, "globe")
    }
}
