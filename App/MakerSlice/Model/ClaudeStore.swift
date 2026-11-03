import ClaudeKit
import Foundation
import Security

/// Persists the Claude assistant setup: the API key in the Keychain, model and effort in UserDefaults.
enum ClaudeStore {
    private static let service = "de.makerslice.claude"

    static func load() -> ClaudeConfig {
        let d = UserDefaults.standard
        let model = d.string(forKey: "claude.model").flatMap(ClaudeModel.init(rawValue:)) ?? .opus
        let effort = d.string(forKey: "claude.effort") ?? "medium"
        return ClaudeConfig(apiKey: readKey() ?? "", model: model, effort: effort)
    }

    static func save(_ config: ClaudeConfig) {
        let d = UserDefaults.standard
        d.set(config.model.rawValue, forKey: "claude.model")
        d.set(config.effort, forKey: "claude.effort")
        writeKey(config.apiKey)
    }

    private static func readKey() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKey(_ key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
