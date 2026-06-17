//
//  Keychain.swift
//  WhisprSoft
//
//  Minimal Security-framework wrapper for the cloud rewrite API keys (Claude
//  and ChatGPT). Each key is stored as a generic password under a fixed
//  service/account; its value is never logged. Read per-request by the
//  rewriters so updating a key takes effect without relaunching.
//

import Foundation
import Security

/// Stores the cloud API keys in the login keychain. `nonisolated` so it's
/// reachable from the nonisolated rewriters as well as the MainActor UI.
nonisolated enum Keychain {
    private static let service = "com.whisprsoft"
    private static let anthropicAccount = "anthropic-api-key"
    private static let openAIAccount = "openai-api-key"

    // MARK: - Claude (Anthropic) API key

    /// Upsert the Claude key. An empty string deletes the stored key instead.
    static func setAPIKey(_ key: String) { set(key, account: anthropicAccount) }

    /// The stored Claude key, or nil if none is set.
    static func apiKey() -> String? { read(account: anthropicAccount) }

    /// Remove the stored Claude key, if any.
    static func deleteAPIKey() { delete(account: anthropicAccount) }

    // MARK: - ChatGPT (OpenAI) API key

    /// Upsert the OpenAI key. An empty string deletes the stored key instead.
    static func setOpenAIKey(_ key: String) { set(key, account: openAIAccount) }

    /// The stored OpenAI key, or nil if none is set.
    static func openAIKey() -> String? { read(account: openAIAccount) }

    /// Remove the stored OpenAI key, if any.
    static func deleteOpenAIKey() { delete(account: openAIAccount) }

    // MARK: - Generic implementation (keyed by account)

    /// Upsert a key for the given account. An empty string deletes it instead.
    private static func set(_ key: String, account: String) {
        guard !key.isEmpty else {
            delete(account: account)
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

    /// The stored key for the given account, or nil if none is set.
    private static func read(account: String) -> String? {
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

    /// Remove the stored key for the given account, if any.
    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
