import MakerWorldKit
import SwiftUI
import WebKit

struct DiscoverView: View {
    @Environment(AppModel.self) private var app
    @State private var design: MakerWorldDesign?
    @State private var isFetching = false
    @State private var error: String?
    @State private var showLinkField = false
    @State private var linkText = ""

    private var browser: MakerWorldBrowser { app.browser }

    var body: some View {
        NavigationStack {
            WebView(webView: browser.webView)
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .bottom) {
                    if browser.model != nil { printBar }
                }
                .navigationTitle("MakerWorld")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button { browser.goBack() } label: { Image(systemName: "chevron.backward") }
                            .disabled(!browser.canGoBack)
                        Button { browser.goHome() } label: { Image(systemName: "house") }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if browser.isLoading { ProgressView() }
                        Button { showLinkField = true } label: { Image(systemName: "link") }
                    }
                }
                .sheet(item: $design) { design in
                    ProfilePickerSheet(design: design) { profile in
                        download(profile, of: design)
                    }
                    .presentationDetents([.medium, .large])
                }
                .alert("Link öffnen", isPresented: $showLinkField) {
                    TextField("https://makerworld.com/…", text: $linkText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button("Öffnen") { openLink() }
                    Button("Abbrechen", role: .cancel) {}
                } message: {
                    Text("Füge einen MakerWorld-Link ein.")
                }
                .alert("MakerWorld", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(error ?? "")
                }
        }
        .onAppear {
            browser.onDownload = { data, name, design in
                app.addDownloaded(data: data, fileName: name, title: design?.title,
                                  makerWorldID: browser.model?.designID, coverURL: design?.coverURL)
            }
        }
    }

    private var printBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Snapmaker U1").font(.caption).foregroundStyle(.secondary)
                Text(app.printers.selected?.name ?? "Kein Drucker").font(.subheadline.weight(.semibold))
            }
            Spacer()
            Button {
                Task { await fetchDesign() }
            } label: {
                if isFetching {
                    ProgressView().tint(.white).frame(width: 150)
                } else {
                    Label("Auf U1 drucken", systemImage: "printer.fill")
                        .frame(width: 150)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isFetching)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func fetchDesign() async {
        isFetching = true
        defer { isFetching = false }
        do {
            let loaded = try await browser.loadDesign()
            // Pre-select the profile the user is looking at.
            if let profileID = browser.model?.profileID, loaded.profiles.contains(where: { $0.id == profileID }) {
                var d = loaded
                d.profiles = d.profiles.map { var p = $0; p.isDefault = p.id == profileID; return p }
                design = d
            } else {
                design = loaded
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func download(_ profile: MakerWorldProfile, of design: MakerWorldDesign) {
        self.design = nil
        isFetching = true
        Task {
            defer { isFetching = false }
            do {
                let (data, name) = try await browser.download(profile: profile, of: design)
                app.addDownloaded(data: data, fileName: name, title: "\(design.title) – \(profile.title)",
                                  makerWorldID: design.id, coverURL: design.coverURL)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func openLink() {
        let trimmed = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            error = "Das ist kein gültiger Link."
            return
        }
        browser.open(url)
    }
}

/// Lets the user pick one of the design's print profiles, Bambu-Handy style.
struct ProfilePickerSheet: View {
    let design: MakerWorldDesign
    let onSelect: (MakerWorldProfile) -> Void
    @State private var selection: Int?

    var body: some View {
        NavigationStack {
            List(design.profiles) { profile in
                Button {
                    selection = profile.id
                } label: {
                    HStack(spacing: 12) {
                        AsyncImage(url: profile.coverURL ?? design.coverURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.secondary.opacity(0.15)
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            HStack(spacing: 10) {
                                if let t = profile.printTimeSeconds {
                                    Label(Self.duration(t), systemImage: "clock")
                                }
                                if let plates = profile.plateCount, plates > 1 {
                                    Label("\(plates) Platten", systemImage: "square.grid.2x2")
                                }
                                if let w = profile.weightGrams {
                                    Label("\(Int(w)) g", systemImage: "scalemass")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if let printer = profile.printerName {
                                Text("Profil für \(printer)").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Image(systemName: selection == profile.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection == profile.id ? Color.accentColor : .secondary)
                            .font(.title3)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(design.title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    if let p = design.profiles.first(where: { $0.id == selection }) { onSelect(p) }
                } label: {
                    Text("Herunterladen & vorbereiten").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .disabled(selection == nil)
            }
        }
        .onAppear { selection = design.defaultProfile?.id }
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }
}

/// Hosts the shared WKWebView.
struct WebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
