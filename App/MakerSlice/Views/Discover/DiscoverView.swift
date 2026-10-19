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

                    if results.isEmpty && !searching && notes.isEmpty {
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
            var collected: [ModelSource: [ModelSearchResult]] = [:]
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
                // Show each source as soon as it answers.
                for await (source, result) in group {
                    guard !Task.isCancelled else { return }
                    switch result {
                    case .success(let list): collected[source] = list
                    case .failure(let error): problems.append("\(source.displayName): \(error.localizedDescription)")
                    }
                    results = Self.interleave(collected)
                    notes = problems
                }
            }
            guard !Task.isCancelled else { return }
            if problems.contains(where: { $0.hasPrefix("MakerWorld") }) {
                notes.append("Tipp: Öffne oben rechts MakerWorld und melde dich an – danach funktioniert die Suche dort.")
            }
            searching = false
        }
    }

    /// Alternates sources so both show up at the top.
    static func interleave(_ lists: [ModelSource: [ModelSearchResult]]) -> [ModelSearchResult] {
        let ordered = ModelSource.allCases.compactMap { lists[$0] }
        var merged: [ModelSearchResult] = []
        let longest = ordered.map(\.count).max() ?? 0
        for i in 0..<longest {
            for list in ordered where i < list.count { merged.append(list[i]) }
        }
        return merged
    }
}

private struct ResultCard: View {
    let result: ModelSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color(.tertiarySystemFill)
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    AsyncImage(url: result.imageURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: "cube").foregroundStyle(.tertiary)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(result.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Text(result.source.displayName)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
                if let likes = result.likes {
                    Label(Self.short(likes), systemImage: "heart").lineLimit(1).fixedSize()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.corner))
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
