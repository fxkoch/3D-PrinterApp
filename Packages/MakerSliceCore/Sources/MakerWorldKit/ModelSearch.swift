import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ModelSource: String, CaseIterable, Sendable, Identifiable, Codable {
    case makerWorld, printables
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .makerWorld: return "MakerWorld"
        case .printables: return "Printables"
        }
    }
}

public enum SearchOrder: String, CaseIterable, Sendable, Identifiable {
    case relevance, popular, newest, rating
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .relevance: return "Relevanz"
        case .popular: return "Beliebt"
        case .newest: return "Neu"
        case .rating: return "Bewertung"
        }
    }
}

/// A free model found by a search.
public struct ModelSearchResult: Identifiable, Hashable, Sendable {
    public var id: String { "\(source.rawValue)-\(modelID)" }
    public var source: ModelSource
    public var modelID: String
    public var title: String
    public var author: String?
    public var imageURL: URL?
    public var likes: Int?
    public var downloads: Int?
    public var pageURL: URL?

    public init(source: ModelSource, modelID: String, title: String, author: String? = nil, imageURL: URL? = nil,
                likes: Int? = nil, downloads: Int? = nil, pageURL: URL? = nil) {
        self.source = source
        self.modelID = modelID
        self.title = title
        self.author = author
        self.imageURL = imageURL
        self.likes = likes
        self.downloads = downloads
        self.pageURL = pageURL
    }
}

/// A downloadable file of a model.
public struct ModelFile: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var size: Int?

    public var isPrintable: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["stl", "3mf", "obj"].contains(ext)
    }
}

/// Printables.com GraphQL API (public, no login needed). Only free models are returned.
public struct PrintablesClient: Sendable {
    public static let endpoint = URL(string: "https://api.printables.com/graphql/")!
    public static let mediaBase = "https://media.printables.com/"

    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func search(_ query: String, order: SearchOrder = .relevance, offset: Int = 0, limit: Int = 30) async throws -> [ModelSearchResult] {
        let ordering: String
        switch order {
        case .relevance: ordering = query.isEmpty ? "popular" : "best_match"
        case .popular: ordering = "popular"
        case .newest: ordering = "latest"
        case .rating: ordering = "rating"
        }
        let gql = """
        query Search($q: String!, $limit: Int, $offset: Int) {
          searchPrints2(query: $q, limit: $limit, offset: $offset, ordering: \(ordering)) {
            items { id name slug price premium likesCount downloadCount image { filePath } user { publicUsername } }
          }
        }
        """
        let json = try await post(gql, variables: ["q": query, "limit": limit, "offset": offset])
        return Self.parseSearch(json)
    }

    static func parseSearch(_ json: [String: Any]) -> [ModelSearchResult] {
        guard let data = json["data"] as? [String: Any], let search = data["searchPrints2"] as? [String: Any],
              let items = search["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = Lenient.string(item["id"]), let name = Lenient.string(item["name"]) else { return nil }
            // Free models only.
            if item["price"] != nil, !(item["price"] is NSNull) { return nil }
            if Lenient.bool(item["premium"]) == true { return nil }
            let path = (item["image"] as? [String: Any]).flatMap { Lenient.string($0["filePath"]) }
            let slug = Lenient.string(item["slug"]) ?? ""
            return ModelSearchResult(
                source: .printables, modelID: id, title: name,
                author: (item["user"] as? [String: Any]).flatMap { Lenient.string($0["publicUsername"]) },
                imageURL: path.flatMap { URL(string: mediaBase + $0) },
                likes: Lenient.int(item["likesCount"]), downloads: Lenient.int(item["downloadCount"]),
                pageURL: URL(string: "https://www.printables.com/model/\(id)-\(slug)")
            )
        }
    }

    public func files(modelID: String) async throws -> [ModelFile] {
        let gql = "query Files($id: ID!) { print(id: $id) { stls { id name fileSize } } }"
        let json = try await post(gql, variables: ["id": modelID])
        guard let data = json["data"] as? [String: Any], let print = data["print"] as? [String: Any],
              let stls = print["stls"] as? [[String: Any]] else { return [] }
        return stls.compactMap { f in
            guard let id = Lenient.string(f["id"]), let name = Lenient.string(f["name"]) else { return nil }
            return ModelFile(id: id, name: name, size: Lenient.int(f["fileSize"]))
        }.filter(\.isPrintable)
    }

    public func download(_ file: ModelFile, modelID: String) async throws -> Data {
        let gql = """
        mutation Link($id: ID!, $printId: ID!) {
          getDownloadLink(id: $id, printId: $printId, fileType: stl, source: model_detail) { ok output { link } }
        }
        """
        let json = try await post(gql, variables: ["id": file.id, "printId": modelID])
        guard let data = json["data"] as? [String: Any], let result = data["getDownloadLink"] as? [String: Any],
              let output = result["output"] as? [String: Any], let link = Lenient.url(output["link"]) else {
            throw URLError(.badServerResponse)
        }
        let (bytes, response) = try await session.data(from: link)
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { throw URLError(.badServerResponse) }
        return bytes
    }

    private func post(_ query: String, variables: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MakerSlice/1.0 (iPhone)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return json
    }
}

extension MakerWorld {
    /// Keyword search used by the MakerWorld website (call from the logged-in web view).
    public static func searchPath(_ keyword: String, offset: Int = 0, limit: Int = 30, order: SearchOrder = .relevance) -> String {
        let q = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        if keyword.isEmpty {
            return "/api/v1/search-service/select/design/nav?navKey=Trending&offset=\(offset)&limit=\(limit)"
        }
        let orderBy: String
        switch order {
        case .relevance: orderBy = ""
        case .popular: orderBy = "&orderBy=downloadCount"
        case .newest: orderBy = "&orderBy=createTime"
        case .rating: orderBy = "&orderBy=likeCount"
        }
        return "/api/v1/search-service/select/design2?keyword=\(q)&offset=\(offset)&limit=\(limit)\(orderBy)"
    }

    /// Website search page, used when the API is unavailable.
    public static func searchPageURL(_ keyword: String) -> URL {
        var comps = URLComponents(string: "https://makerworld.com/de/search/models")!
        comps.queryItems = [URLQueryItem(name: "keyword", value: keyword)]
        return comps.url!
    }

    /// Parses search/nav responses leniently: finds the first list of design-like objects.
    public static func parseSearch(_ data: Data) -> [ModelSearchResult] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        guard let list = findDesignList(root, depth: 0) else { return [] }
        return list.compactMap { item in
            let design = item["design"] as? [String: Any] ?? item
            guard let id = Lenient.int(design["id"]) ?? Lenient.int(design["designId"]),
                  let title = Lenient.string(design["title"]) else { return nil }
            let creator = design["designCreator"] as? [String: Any] ?? design["creator"] as? [String: Any]
            return ModelSearchResult(
                source: .makerWorld, modelID: String(id), title: title,
                author: Lenient.string(creator?["name"]),
                imageURL: Lenient.url(design["cover"]) ?? Lenient.url(design["coverUrl"]),
                likes: Lenient.int(design["likeCount"]), downloads: Lenient.int(design["downloadCount"]),
                pageURL: URL(string: "https://makerworld.com/de/models/\(id)")
            )
        }
    }

    private static func findDesignList(_ any: Any, depth: Int) -> [[String: Any]]? {
        guard depth < 6 else { return nil }
        if let array = any as? [[String: Any]], let first = array.first {
            let probe = first["design"] as? [String: Any] ?? first
            if probe["title"] != nil, probe["id"] != nil || probe["designId"] != nil { return array }
        }
        if let dict = any as? [String: Any] {
            for key in ["hits", "designs", "list", "items", "data", "result"] {
                if let v = dict[key], let found = findDesignList(v, depth: depth + 1) { return found }
            }
            for value in dict.values {
                if let found = findDesignList(value, depth: depth + 1) { return found }
            }
        }
        return nil
    }
}
