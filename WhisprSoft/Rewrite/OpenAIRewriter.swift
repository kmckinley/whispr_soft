//
//  OpenAIRewriter.swift
//  WhisprSoft
//
//  Real rewrite stage for the ChatGPT (OpenAI) cloud backend: an OpenAI Chat
//  Completions call that cleans up the raw transcript before injection. Mirrors
//  HTTPRewriter's structure and discipline — the shared, security-hardened
//  prompt comes from `RewritePrompt`, the key is read fresh per call from the
//  Keychain, the tone profile and target language are resolved fresh per call,
//  and only counts are logged (never content or key).
//
//  `nonisolated` so it satisfies the MainActor `Rewriter` requirement and runs
//  off-main — the heavy work is the network round-trip, awaited via URLSession.
//

import Foundation
import os

/// Cleans up dictated speech via an OpenAI Chat Completions request, using the
/// same hardened prompt as the Claude backend (`RewritePrompt`). The model is
/// pinned to `gpt-4.1-mini`.
nonisolated struct OpenAIRewriter: Rewriter {
    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let model = "gpt-4.1-mini"
    private static let timeout: TimeInterval = 60   // matches the cloud Claude path

    func rewrite(_ text: String) async throws -> RewriteResult {
        guard !text.isEmpty else {
            return RewriteResult(text: text, engine: "ChatGPT", model: Self.model, usedRawFallback: false)
        }

        // Resolve auth fresh each call so a key entered/changed in Settings
        // applies immediately, without relaunch. The key is never logged.
        guard let key = Keychain.openAIKey(), !key.isEmpty else {
            throw RewriterError.noOpenAIKey
        }

        // Resolve the active tone profile and target language fresh per call
        // (read-fresh pattern), so selecting/editing them applies on the next
        // dictation. Both feed the shared prompt builder, so the cloud backends
        // stay in lockstep.
        let profile = RewriteProfilesStore.active()
        let language = TargetLanguage.active()

        var request = URLRequest(url: Self.endpoint, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let messages: [Message] =
            [Message(role: "system", content: RewritePrompt.system(for: profile, language: language))]
            + RewritePrompt.fewShots.map { Message(role: $0.role, content: $0.content) }
            + [Message(role: "user", content: RewritePrompt.wrap(text))]

        // `max_completion_tokens` is the current field (the old `max_tokens` is
        // deprecated). Temperature is intentionally omitted (default).
        let body = RequestBody(model: Self.model, messages: messages, max_completion_tokens: 2048)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw RewriterError.httpError(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RewriterError.httpError(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)

        guard let choice = decoded.choices.first else {
            throw RewriterError.emptyResponse
        }

        // A "length" finish means the cleanup was cut off mid-text. Surface it
        // as a failure so the ladder falls back to raw — pasting the user's full
        // transcript beats pasting a silently-truncated cleanup. (Parallels the
        // Anthropic `max_tokens` guard.)
        guard choice.finish_reason != "length" else {
            throw RewriterError.truncated
        }

        let cleaned = (choice.message.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { throw RewriterError.emptyResponse }

        // The profile name is a user-chosen label, not transcript content, so
        // it's safe to log `.public`. The instruction body is NEVER logged. The
        // language id is an app-owned slug, also safe; appended only when
        // translating so the default path's log line matches the cloud line.
        let languageSuffix = language.translates ? " -> \(language.id)" : ""
        Log.rewrite.notice("Rewriter: openai [\(profile?.name ?? "default", privacy: .public)] cleaned \(text.count, privacy: .public) -> \(cleaned.count, privacy: .public) chars\(languageSuffix, privacy: .public)")
        return RewriteResult(text: cleaned, engine: "ChatGPT", model: Self.model, usedRawFallback: false)
    }

    // MARK: - Wire types

    private struct RequestBody: Encodable {
        let model: String
        let messages: [Message]
        let max_completion_tokens: Int
    }

    private struct Message: Codable {
        let role: String
        let content: String
    }

    private struct ResponseBody: Decodable {
        let choices: [Choice]
    }

    private struct Choice: Decodable {
        let message: ChoiceMessage
        let finish_reason: String?
    }

    private struct ChoiceMessage: Decodable {
        let content: String?
    }
}
