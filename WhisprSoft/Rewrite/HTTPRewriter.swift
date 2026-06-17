//
//  HTTPRewriter.swift
//  WhisprSoft
//
//  Real rewrite stage: a cloud Claude call (Haiku) that cleans up the raw
//  transcript before injection. Uses the Anthropic Messages shape — the same
//  shape LM Studio speaks, so the later local rung reuses this client with a
//  different RewriterConfig. The API key is read from the Keychain per call,
//  so updating it takes effect without relaunch. The key is never logged.
//

import Foundation
import os

/// The pieces that differ between rewrite backends. Cloud authenticates with
/// the Keychain API key and pins a model; local points at LM Studio, uses a
/// dummy token, and resolves the loaded model from `/v1/models` at runtime.
nonisolated struct RewriterConfig {
    let endpoint: URL
    /// Pinned model id, or nil to fetch the loaded model from `modelsEndpoint`.
    let model: String?
    /// true → cloud x-api-key from Keychain; false → dummy LM Studio token.
    let usesKeychainKey: Bool
    /// OpenAI-style models list, queried when `model` is nil.
    let modelsEndpoint: URL?
    /// Per-request timeout. Bounds the dictation hot path: a hung backend falls
    /// back to raw within this window instead of the 60s URLSession default.
    let timeout: TimeInterval
    /// User-facing engine name for the dictation log ("Claude"/"LM Studio").
    let displayName: String

    /// Label for diagnostics ("cloud"/"local").
    var label: String { usesKeychainKey ? "cloud" : "local" }

    static let cloud = RewriterConfig(
        endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
        model: "claude-haiku-4-5-20251001",
        usesKeychainKey: true,
        modelsEndpoint: nil,
        timeout: 60,   // proven default; cloud is reliable, leave headroom
        displayName: "Claude"
    )

    // LM Studio speaks the Anthropic Messages shape at this loopback address.
    // 127.0.0.1 (not localhost) is App Transport Security-exempt, so no
    // Info.plist/ATS changes are needed for the plaintext HTTP call.
    static let local = RewriterConfig(
        endpoint: URL(string: "http://127.0.0.1:1234/v1/messages")!,
        model: nil,
        usesKeychainKey: false,
        modelsEndpoint: URL(string: "http://127.0.0.1:1234/v1/models")!,
        timeout: 20,   // tight bound so a stuck LM Studio doesn't freeze dictation
        displayName: "LM Studio"
    )
}

/// Cleans up dictated speech via an Anthropic Messages request. `nonisolated`
/// so it satisfies the MainActor `Rewriter` requirement and runs off-main —
/// the heavy work is the network round-trip, awaited via URLSession.
nonisolated struct HTTPRewriter: Rewriter {
    let config: RewriterConfig

    func rewrite(_ text: String) async throws -> RewriteResult {
        guard !text.isEmpty else {
            return RewriteResult(text: text, engine: config.displayName, model: config.model, usedRawFallback: false)
        }

        // Resolve auth. Cloud reads the key fresh each call so a key
        // entered/changed in the menu applies immediately, without relaunch.
        // Local uses a dummy token (LM Studio ignores it unless auth is on).
        let token: String
        if config.usesKeychainKey {
            guard let key = Keychain.apiKey(), !key.isEmpty else {
                throw RewriterError.noAPIKey
            }
            token = key
        } else {
            token = "lmstudio"
        }

        // Resolve the model: pinned (cloud) or the first loaded model from the
        // local /v1/models list. An empty/unreachable list throws → raw fallback.
        let model = try await resolveModel()

        // Resolve the active tone profile fresh per call (read-fresh pattern), so
        // selecting/editing a profile in the menu applies on the next dictation.
        // Applying it here means cloud and local both get it — no ladder change.
        let profile = RewriteProfilesStore.active()

        // Resolve the target language fresh per call too (read-fresh pattern).
        // Default (English US) means no translation — `systemPrompt` returns
        // exactly today's output. A non-default language appends `## Translate`.
        let language = TargetLanguage.active()

        var request = URLRequest(url: config.endpoint, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body = RequestBody(
            model: model,
            max_tokens: 2048,
            system: RewritePrompt.system(for: profile, language: language),
            messages: RewritePrompt.fewShots.map { Message(role: $0.role, content: $0.content) }
                + [Message(role: "user", content: RewritePrompt.wrap(text))]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw RewriterError.httpError(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RewriterError.httpError(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)

        // A `max_tokens` stop means the cleanup was cut off mid-text. Surface
        // it as a failure so the ladder falls back to raw — pasting the user's
        // full transcript beats pasting a silently-truncated cleanup.
        guard decoded.stop_reason != "max_tokens" else {
            throw RewriterError.truncated
        }

        let cleaned = decoded.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { throw RewriterError.emptyResponse }

        // The profile name is a user-chosen label, not transcript content, so
        // it's safe to log `.public`. The instruction body is NEVER logged.
        // The language id is an app-owned slug, also safe; appended only when
        // translating so the default path's log line is unchanged.
        let languageSuffix = language.translates ? " -> \(language.id)" : ""
        Log.rewrite.notice("Rewriter: \(config.label, privacy: .public) [\(profile?.name ?? "default", privacy: .public)] cleaned \(text.count, privacy: .public) -> \(cleaned.count, privacy: .public) chars\(languageSuffix, privacy: .public)")
        return RewriteResult(text: cleaned, engine: config.displayName, model: model, usedRawFallback: false)
    }

    // MARK: - Model resolution

    /// The model id to send: the pinned `config.model`, or — when nil — the
    /// first id from the local `/v1/models` list. Throws if the list is
    /// unreachable (URLSession) or empty (`.noModelAvailable`) so the ladder
    /// falls back to raw rather than sending an unusable request.
    private func resolveModel() async throws -> String {
        if let model = config.model { return model }
        guard let modelsEndpoint = config.modelsEndpoint else {
            throw RewriterError.noModelAvailable
        }

        let modelsRequest = URLRequest(url: modelsEndpoint, timeoutInterval: config.timeout)
        let (data, response) = try await URLSession.shared.data(for: modelsRequest)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw RewriterError.noModelAvailable
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        guard let id = decoded.data.first?.id, !id.isEmpty else {
            throw RewriterError.noModelAvailable
        }

        Log.rewrite.notice("Rewriter: \(config.label, privacy: .public) resolved model \(id, privacy: .public)")
        return id
    }

    private struct ModelsResponse: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    // MARK: - Wire types

    private struct RequestBody: Encodable {
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Message]
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    private struct ResponseBody: Decodable {
        let content: [Block]
        let stop_reason: String?
    }

    private struct Block: Decodable {
        let type: String
        // Optional: non-text blocks (future tool/thinking shapes) have no
        // `text`. We filter to type == "text" and compactMap anyway, so a
        // missing field is tolerated rather than failing the whole decode.
        let text: String?
    }
}

/// Failures surfaced by the rewrite stage. `LocalizedError` so the ladder's
/// log line and any UI get a readable description.
enum RewriterError: LocalizedError {
    case noAPIKey
    case noOpenAIKey
    case noModelAvailable
    case httpError(Int)
    case emptyResponse
    case truncated

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No Claude API key is set."
        case .noOpenAIKey:
            return "No ChatGPT (OpenAI) API key is set."
        case .noModelAvailable:
            return "No local model is loaded in LM Studio."
        case .httpError(let status):
            return "Rewrite request failed (HTTP \(status))."
        case .emptyResponse:
            return "The rewrite response was empty."
        case .truncated:
            return "The rewrite response was cut off (max tokens)."
        }
    }
}
