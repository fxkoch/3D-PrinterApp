import Foundation
import Security
import WebKit

/// Keeps logins on model portals (MakerWorld, Thingiverse …) alive across app restarts.
///
/// WebKit forgets cookies that have no expiry date when the app is closed, and some sites drop their login cookie
/// when the system clears caches. So every cookie is (a) given a 60-day lifetime if it had none and (b) backed up
/// in the Keychain, from where it is restored at the next start.
@MainActor
enum PortalSession {
    private static let service = "de.makerslice.portal-cookies"
    private static let lifetime: TimeInterval = 60 * 24 * 3600
    private static let sizeLimit = 400_000

    /// Cookies of these domains count as "signed in" when they carry a token.
    static let accountDomains = ["makerworld.com", "bambulab.com", "thingiverse.com", "thangs.com", "myminifactory.com",
                                 "cults3d.com", "crealitycloud.com", "grabcad.com"]

    /// Gives session cookies a lifetime and saves everything worth keeping.
    static func keep(_ store: WKHTTPCookieStore) async {
        let cookies = await store.allCookies()
        var keep: [HTTPCookie] = []
        for cookie in cookies {
            var cookie = cookie
            if cookie.expiresDate == nil, var props = cookie.properties {
                props[.expires] = Date().addingTimeInterval(lifetime)
                props.removeValue(forKey: .discard)
                if let renewed = HTTPCookie(properties: props) {
                    await store.setCookie(renewed)
                    cookie = renewed
                }
            }
            if let expires = cookie.expiresDate, expires > Date() { keep.append(cookie) }
        }
        save(keep)
    }

    /// Puts saved cookies back (call before the first page load).
    static func restore(into store: WKHTTPCookieStore) async {
        let existing = Set(await store.allCookies().map { "\($0.domain)|\($0.path)|\($0.name)" })
        for props in load() {
            guard let cookie = HTTPCookie(properties: props), let expires = cookie.expiresDate, expires > Date(),
                  !existing.contains("\(cookie.domain)|\(cookie.path)|\(cookie.name)") else { continue }
            await store.setCookie(cookie)
        }
    }

    /// True when a token cookie of a portal account is present.
    static func signedInDomains(_ store: WKHTTPCookieStore) async -> [String] {
        let cookies = await store.allCookies()
        var found: Set<String> = []
        for cookie in cookies {
            let name = cookie.name.lowercased()
            guard name.contains("token") || name == "sid" || name.contains("session") || name.contains("auth") else { continue }
            if let expires = cookie.expiresDate, expires < Date() { continue }
            let domain = cookie.domain.trimmingCharacters(in: ["."]).lowercased()
            if let match = accountDomains.first(where: { domain.hasSuffix($0) }) { found.insert(match) }
        }
        return found.sorted()
    }

    /// Signs out of a portal: removes its cookies from WebKit and from the backup.
    static func signOut(of domains: [String], store: WKHTTPCookieStore) async {
        for cookie in await store.allCookies() {
            let domain = cookie.domain.trimmingCharacters(in: ["."]).lowercased()
            if domains.contains(where: { domain.hasSuffix($0) }) { await store.deleteCookie(cookie) }
        }
        await keep(store)
    }

    // MARK: Keychain backup

    private static func save(_ cookies: [HTTPCookie]) {
        let list: [[String: Any]] = cookies.compactMap { cookie in
            guard let props = cookie.properties else { return nil }
            var dict: [String: Any] = [:]
            for (key, value) in props where value is String || value is Date || value is Bool || value is NSNumber {
                dict[key.rawValue] = value
            }
            return dict
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0),
              data.count < sizeLimit else { return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func load() -> [[HTTPCookiePropertyKey: Any]] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let list = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]] else { return [] }
        return list.map { dict in Dictionary(uniqueKeysWithValues: dict.map { (HTTPCookiePropertyKey($0.key), $0.value) }) }
    }
}
