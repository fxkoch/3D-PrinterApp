import MakerWorldKit
import SwiftUI
import WebKit

/// Search free models on MakerWorld and Printables, open them for printing.
struct DiscoverView: View {
    @Environment(AppModel.self) private var app

    enum SourceFilter: String, CaseIterable, Identifiable {
        case all, makerWorld, printables
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "Alle"
            case .makerWorld: return "MakerWorld"
            case .printables: return "Printables"
            }
        }
    }

    @State private var query = ""
    @State private var filter: SourceFilter = .all
    @State private var order: SearchOrder = .popular
    @State private var results: [ModelSearchResult] = []
    @State private var searching = false
    @State private var notes: [String] = []
    @State private var selected: ModelSearchResult?
    @State private var showBrowser = false
    @State private var searchTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Quelle", selection: $filter) {
                        ForEach(SourceFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    ForEach(notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if results.isEmpty && !searching {
                        ContentUnavailableView("Keine Treffer", systemImage: "magnifyingglass",
                                               description: Text("Suche nach einem Begriff, z. B. „Kabelhalter“ oder „Vase“."))
                            .padding(.top, 40)
                    }

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(results) { result in
                            Button { selected = result } label: { ResultCard(result: result) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("result-\(result.id)")
                        }
                    }
                    if searching {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Entdecken")
            .searchable(text: $query, prompt: "Kostenlose Modelle suchen")
            .onSubmit(of: .search) { runSearch() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Sortierung", selection: $order) {
                            ForEach(SearchOrder.allCases) { Text($0.displayName).tag($0) }
                        }
                    } label: {
                        Label("Sortieren", systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showBrowser = true } label: { Label("MakerWorld öffnen", systemImage: "safari") }
                }
            }
            .onChange(of: filter) { _, _ in runSearch() }
            .onChange(of: order) { _, _ in runSearch() }
            .task { if results.isEmpty { runSearch() } }
            .sheet(item: $selected) { result in
                ModelDetailView(result: result)
            }
            .fullScreenCover(isPresented: $showBrowser) {
                BrowserView()
            }
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = self.filter, order = self.order
        searching = true
        notes = []
        results = []
        searchTask = Task {
            var collected: [[ModelSearchResult]] = []
            var problems: [String] = []
            await withTaskGroup(of: (ModelSource, Result<[ModelSearchResult], Error>).self) { group in
                if filter != .makerWorld {
                    group.addTask {
                        do { return (.printables, .success(try await PrintablesClient().search(q, order: order))) } catch {
                            return (.printables, .failure(error))
                        }
                    }
                }
                if filter != .printables {
                    let browser = app.browser
                    group.addTask { @MainActor in
                        do { return (.makerWorld, .success(try await browser.search(q, order: order))) } catch {
                            return (.makerWorld, .failure(error))
                        }
                    }
                }
                for await (source, result) in group {
                    switch result {
                    case .success(let list): collected.append(list)
                    case .failure(let error):
                        problems.append("\(source.displayName): \(error.localizedDescription)")
                    }
                }
            }
            guard !Task.isCancelled else { return }
            // Interleave sources so both show up at the top.
            var merged: [ModelSearchResult] = []
            let longest = collected.map(\.count).max() ?? 0
            for i in 0..<longest {
                for list in collected where i < list.count { merged.append(list[i]) }
            }
            results = merged
            notes = problems
            if problems.contains(where: { $0.hasPrefix("MakerWorld") }) {
                notes.append("Tipp: Öffne oben rechts MakerWorld und melde dich an – danach funktioniert die Suche dort.")
            }
            searching = false
        }
    }
}

private struct ResultCard: View {
    let result: ModelSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: result.imageURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color(.tertiarySystemFill).overlay { Image(systemName: "cube").foregroundStyle(.tertiary) }
                }
            }
            .frame(height: 130)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(result.title).font(.subheadline.weight(.medium)).lineLimit(2).frame(height: 38, alignment: .top)
            HStack(spacing: 8) {
                Text(result.source.displayName)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                Spacer(minLength: 0)
                if let likes = result.likes { Label("\(likes)", systemImage: "heart") }
                if let downloads = result.downloads { Label(Self.short(downloads), systemImage: "arrow.down.circle") }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    static func short(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}

/// Full MakerWorld website (login, browsing) with a "print" bar on model pages.
struct BrowserView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var design: MakerWorldDesign?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let browser = app.browser
        NavigationStack {
            WebView(webView: browser.webView)
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .bottom) {
                    if browser.model != nil {
                        HStack {
                            Text("Modell erkannt").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                Task { await loadDesign() }
                            } label: {
                                if busy { ProgressView() } else { Label("Drucken", systemImage: "printer") }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                        .background(.bar)
                    }
                }
                .navigationTitle("MakerWorld")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if browser.isLoading { ProgressView() }
                        Button { browser.goBack() } label: { Image(systemName: "chevron.backward") }.disabled(!browser.canGoBack)
                        Button { browser.goHome() } label: { Image(systemName: "house") }
                    }
                }
                .sheet(item: $design) { d in
                    MakerWorldProfilesView(design: d) { dismiss() }
                }
                .alert("MakerWorld", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: { Text(error ?? "") }
        }
        .onAppear {
            browser.onDownload = { data, name, _ in
                app.addDownloaded(data: data, fileName: name, title: nil, source: .makerWorld,
                                  sourceID: browser.model.map { String($0.designID) })
                dismiss()
            }
        }
    }

    private func loadDesign() async {
        busy = true
        defer { busy = false }
        do {
            design = try await app.browser.loadDesign()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Hosts the shared WKWebView.
struct WebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
