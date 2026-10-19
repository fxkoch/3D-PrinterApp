import Foundation
import MakerWorldKit
import Observation
import WebKit

/// Owns the MakerWorld web view and talks to the site's internal API from
/// inside the page (same origin, user's login cookies, passes Cloudflare).
@MainActor
@Observable
final class MakerWorldBrowser: NSObject {
    let webView: WKWebView

    private(set) var currentURL: URL?
    private(set) var canGoBack = false
    private(set) var isLoading = false
    private(set) var model: MakerWorld.ModelReference?

    /// Called with downloaded file data (from our API flow or the site's own download buttons).
    @ObservationIgnored var onDownload: ((Data, String, MakerWorldDesign?) -> Void)?

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // keeps the MakerWorld login between launches
        config.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.url, options: .new) { [weak self] view, _ in
                Task { @MainActor in self?.urlChanged(view.url) }
            },
            webView.observe(\.canGoBack, options: .new) { [weak self] view, _ in
                Task { @MainActor in self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.isLoading, options: .new) { [weak self] view, _ in
                Task { @MainActor in self?.isLoading = view.isLoading }
            },
        ]
        webView.load(URLRequest(url: MakerWorld.homeURL))
    }

    func open(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func reload() { webView.reload() }
    func goHome() { open(MakerWorld.homeURL) }

    private func urlChanged(_ url: URL?) {
        currentURL = url
        model = url.flatMap(MakerWorld.parse)
    }

    // MARK: - API via the page

    enum BrowserError: LocalizedError {
        case notOnModelPage, requestFailed(Int), noProfiles, downloadUnavailable

        var errorDescription: String? {
            switch self {
            case .notOnModelPage: return "Öffne zuerst ein Modell auf MakerWorld."
            case .requestFailed(let code) where code == 401 || code == 403:
                return "MakerWorld verlangt eine Anmeldung. Melde dich oben auf der Seite an und versuche es erneut."
            case .requestFailed(let code): return "MakerWorld hat mit Fehler \(code) geantwortet."
            case .noProfiles: return "Für dieses Modell wurden keine Druckprofile gefunden."
            case .downloadUnavailable:
                return "Der Direkt-Download hat nicht geklappt. Tippe auf der Seite auf „Download“ (3MF oder STL) – MakerSlice übernimmt die Datei automatisch."
            }
        }
    }

    private func fetchText(_ path: String) async throws -> (Int, String) {
        let result = try await webView.callAsyncJavaScript(
            MakerWorld.fetchTextJS, arguments: ["path": path], in: nil, contentWorld: .defaultClient
        )
        guard let dict = result as? [String: Any] else { throw BrowserError.requestFailed(0) }
        let status = (dict["status"] as? NSNumber)?.intValue ?? 0
        return (status, dict["body"] as? String ?? "")
    }

    /// Loads design details (title, print profiles) for the open model page.
    func loadDesign() async throws -> MakerWorldDesign {
        guard let model else { throw BrowserError.notOnModelPage }
        let (status, body) = try await fetchText(MakerWorld.designPath(model.designID))
        if status == 200, let design = MakerWorldDesign(json: Data(body.utf8)), !design.profiles.isEmpty {
            return design
        }
        // Fallback: the page embeds the design in its Next.js data.
        if let next = try await webView.callAsyncJavaScript(MakerWorld.nextDataJS, arguments: [:], in: nil,
                                                             contentWorld: .defaultClient) as? String,
           let design = MakerWorldDesign(nextData: next), !design.profiles.isEmpty {
            return design
        }
        if status != 200 { throw BrowserError.requestFailed(status) }
        throw BrowserError.noProfiles
    }

    /// Downloads the 3MF of a print profile.
    func download(profile: MakerWorldProfile, of design: MakerWorldDesign) async throws -> (Data, String) {
        let (status, body) = try await fetchText(MakerWorld.downloadPath(instanceID: profile.id))
        guard status == 200 else { throw BrowserError.requestFailed(status) }
        guard case let .redirect(url, name) = MakerWorldDownload(json: Data(body.utf8)) else {
            throw BrowserError.downloadUnavailable
        }
        var request = URLRequest(url: url)
        // Signed CDN links don't need cookies, but pass them in case the URL is on makerworld.com.
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        HTTPCookie.requestHeaderFields(with: cookies.filter { url.host?.hasSuffix($0.domain.trimmingCharacters(in: ["."])) ?? false })
            .forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400, !data.isEmpty else {
            throw BrowserError.downloadUnavailable
        }
        let fileName = name ?? "\(design.title) – \(profile.title).3mf"
        return (data, fileName.hasSuffix(".3mf") ? fileName : fileName + ".3mf")
    }

    // MARK: - Downloads started by the website itself

    @ObservationIgnored fileprivate var pendingDownloads: [ObjectIdentifier: URL] = [:]

    fileprivate static func looksLikeModelFile(_ response: URLResponse) -> Bool {
        let name = (response.suggestedFilename ?? response.url?.lastPathComponent ?? "").lowercased()
        if name.hasSuffix(".3mf") || name.hasSuffix(".stl") || name.hasSuffix(".obj") { return true }
        let mime = response.mimeType?.lowercased() ?? ""
        return mime.contains("3mf") || mime == "application/sla" || mime == "model/stl" || mime == "application/octet-stream"
    }
}

extension MakerWorldBrowser: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if !navigationResponse.canShowMIMEType || Self.looksLikeModelFile(navigationResponse.response) {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.shouldPerformDownload ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    /// Links with target="_blank" open in the same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(suggestedFilename)
        pendingDownloads[ObjectIdentifier(download)] = url
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = pendingDownloads.removeValue(forKey: ObjectIdentifier(download)),
              let data = try? Data(contentsOf: url) else { return }
        onDownload?(data, url.lastPathComponent, nil)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        pendingDownloads.removeValue(forKey: ObjectIdentifier(download))
    }
}
