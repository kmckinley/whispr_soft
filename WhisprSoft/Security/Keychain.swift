//
//  Keychain.swift
//  WhisprSoft
//
//  Minimal Security-framework wrapper for the Claude API key. The key is
//  stored as a generic password under a fixed service/account; its value is
//  never logged. Read per-request by the rewriter so updating it takes effect
//  without relaunching.
//

import Foundation
import Security

/// Stores the Claude API key in the login keychain. `nonisolated` so it's
/// reachable from the nonisolated HTTPRewriter as well as the MainActor UI.
nonisolated enum Keychain {
    private static let service = "com.whisprsoft"
    private static let account = "anthropic-api-key"

    /// Upsert the key. An empty string deletes the stored key instead.
    static func setAPIKey(_ key: String) {
        guard !key.isEmpty else {
            deleteAPIKey()
            return
        }
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Try update first; if nothing is stored yet, add.
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// The stored key, or nil if none is set.
    static func apiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Remove the stored key, if any.
    static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
