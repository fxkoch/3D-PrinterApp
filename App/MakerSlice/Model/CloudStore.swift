import Foundation
import PrinterKit
import Security

/// Persists the cloud-slicing setup: repository and branch in UserDefaults, the token in the Keychain.
enum CloudStore {
    private static let service = "de.makerslice.cloud"

    static func load() -> CloudSliceConfig {
        let d = UserDefaults.standard
        return CloudSliceConfig(repository: d.string(forKey: "cloud.repository") ?? "",
                                token: readToken() ?? "",
                                workflowBranch: d.string(forKey: "cloud.branch") ?? "")
    }

    static func save(_ config: CloudSliceConfig) {
        let d = UserDefaults.standard
        d.set(config.repository, forKey: "cloud.repository")
        d.set(config.workflowBranch, forKey: "cloud.branch")
        writeToken(config.token)
    }

    private static func readToken() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeToken(_ token: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard !token.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
