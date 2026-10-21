import Foundation

/// Helpers for makerworld.com.
///
/// MakerWorld has no public API and sits behind Cloudflare, so the app talks to
/// it from inside a logged-in web view: the JavaScript snippets below run in the
/// page context (same origin, the user's cookies) and hand JSON back to Swift.
/// The endpoints are the ones the MakerWorld website itself uses; they are
/// undocumented and may change, which is why all parsing here is lenient.
public enum MakerWorld {
    public static let defaultHost = "makerworld.com"
    public static let homeURL = URL(string: "https://makerworld.com/de")!

    /// Reference to a model page, e.g. https://makerworld.com/en/models/2344501-keyring#profileId-2563198
    public struct ModelReference: Equatable, Sendable {
        public var designID: Int
        public var profileID: Int?
        public var host: String
    }

    public static func parse(_ url: URL) -> ModelReference? {
        guard let host = url.host?.lowercased(), host.hasSuffix("makerworld.com") || host.hasSuffix("makerworld.com.cn") else {
            return nil
        }
        let parts = url.path.split(separator: "/")
        guard let idx = parts.firstIndex(of: "models"), idx + 1 < parts.count else { return nil }
        let slug = parts[idx + 1]
        guard let id = Int(slug.prefix(while: \.isNumber)) else { return nil }
        var profile: Int?
        if let fragment = url.fragment, let range = fragment.range(of: "profileId-") {
            profile = Int(fragment[range.upperBound...].prefix(while: \.isNumber))
        }
        if profile == nil, let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            profile = query.first { $0.name == "profileId" }?.value.flatMap(Int.init)
        }
        return ModelReference(designID: id, profileID: profile, host: host)
    }

    public static func designPath(_ id: Int) -> String { "/api/v1/design-service/design/\(id)" }
    public static func downloadPath(instanceID: Int) -> String {
        "/api/v1/design-service/instance/\(instanceID)/f3mf?type=download"
    }

    /// JavaScript (for `callAsyncJavaScript`) that GETs a same-origin path and
    /// returns `{status, body}` – body as text.
    public static let fetchTextJS = """
    const r = await fetch(path, { credentials: 'include', headers: { 'Accept': 'application/json' } });
    return { status: r.status, body: await r.text() };
    """

    /// JavaScript that pulls `__NEXT_DATA__` from the current page (model pages embed the design there).
    public static let nextDataJS = """
    const el = document.getElementById('__NEXT_DATA__');
    return el ? el.textContent : null;
    """
}

/// A print profile ("instance") of a design – what MakerWorld calls a profile.
public struct MakerWorldProfile: Identifiable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var isDefault: Bool
    public var coverURL: URL?
    public var printTimeSeconds: Int?
    public var plateCount: Int?
    public var weightGrams: Double?
    public var materials: [String]
    public var printerName: String?
}

public struct MakerWorldDesign: Identifiable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var creator: String?
    public var coverURL: URL?
    public var likeCount: Int?
    public var downloadCount: Int?
    public var profiles: [MakerWorldProfile]
    public var summary: String?

    public var defaultProfile: MakerWorldProfile? {
        profiles.first(where: \.isDefault) ?? profiles.first
    }

    /// Parses the design-service JSON. Accepts the design at the top level or nested in "design"/"data".
    public init?(json data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        self.init(any: root)
    }

    init?(any root: Any) {
        guard let dict = root as? [String: Any] else { return nil }
        if dict["instances"] == nil {
            for key in ["design", "data", "result"] {
                if let nested = dict[key], let d = MakerWorldDesign(any: nested) {
                    self = d
                    return
                }
            }
        }
        guard let id = Lenient.int(dict["id"]) else { return nil }
        self.id = id
        title = Lenient.string(dict["title"]) ?? "Modell \(id)"
        let creator = dict["designCreator"] as? [String: Any] ?? dict["creator"] as? [String: Any]
        self.creator = Lenient.string(creator?["name"]) ?? Lenient.string(creator?["nickname"])
        coverURL = Lenient.url(dict["coverUrl"]) ?? Lenient.url(dict["cover"])
        likeCount = Lenient.int(dict["likeCount"])
        downloadCount = Lenient.int(dict["downloadCount"])
        summary = Lenient.string(dict["summary"])
        let instances = dict["instances"] as? [[String: Any]] ?? []
        profiles = instances.compactMap { inst in
            guard let iid = Lenient.int(inst["id"]) else { return nil }
            let materials = (inst["instanceFilaments"] as? [[String: Any]] ?? []).compactMap { f -> String? in
                let type = Lenient.string(f["type"])
                let color = Lenient.string(f["color"])
                return [type, color].compactMap { $0 }.joined(separator: " ").nilIfEmpty
            }
            let printer = (inst["extention"] as? [String: Any])?["modelInfo"] as? [String: Any]
            return MakerWorldProfile(
                id: iid,
                title: Lenient.string(inst["title"]) ?? "Profil \(iid)",
                isDefault: Lenient.bool(inst["isDefault"]) ?? false,
                coverURL: Lenient.url(inst["cover"]),
                printTimeSeconds: Lenient.int(inst["prediction"]),
                plateCount: Lenient.int(inst["plateCnt"]) ?? (printer?["plates"] as? [Any])?.count,
                weightGrams: Lenient.double(inst["weight"]),
                materials: materials,
                printerName: Lenient.string(inst["printerName"]) ?? Lenient.string(printer?["printerName"])
            )
        }
    }

    /// Extracts the design from a model page's `__NEXT_DATA__` JSON.
    public init?(nextData: String) {
        guard let data = nextData.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let found = MakerWorldDesign.findDesign(in: root, depth: 0) else { return nil }
        self = found
    }

    private static func findDesign(in any: Any, depth: Int) -> MakerWorldDesign? {
        guard depth < 8 else { return nil }
        if let dict = any as? [String: Any] {
            if dict["instances"] is [[String: Any]], dict["id"] != nil, let d = MakerWorldDesign(any: dict) { return d }
            for value in dict.values {
                if let d = findDesign(in: value, depth: depth + 1) { return d }
            }
        } else if let array = any as? [Any] {
            for value in array.prefix(50) {
                if let d = findDesign(in: value, depth: depth + 1) { return d }
            }
        }
        return nil
    }
}

/// Response of the f3mf download endpoint: either JSON with a (signed) URL or the file itself.
public enum MakerWorldDownload: Equatable, Sendable {
    case redirect(url: URL, fileName: String?)
    case unknown

    public init(json data: Data) {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            self = .unknown
            return
        }
        let payload = dict["data"] as? [String: Any] ?? dict
        if let url = Lenient.url(payload["url"]) ?? Lenient.url(payload["downloadUrl"]) {
            self = .redirect(url: url, fileName: Lenient.string(payload["name"]))
        } else {
            self = .unknown
        }
    }
}

enum Lenient {
    static func string(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    static func int(_ any: Any?) -> Int? {
        switch any {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    static func double(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    static func bool(_ any: Any?) -> Bool? {
        switch any {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return s == "true" || s == "1"
        default: return nil
        }
    }

    static func url(_ any: Any?) -> URL? {
        guard let s = string(any), s.hasPrefix("http") else { return nil }
        return URL(string: s)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
