//
//  Rewriter.swift
//  WhisprSoft
//
//  Rewrite stage contract + stub. The rewrite ladder (cloud Claude →
//  local LM Studio → raw) is a later pass; for now just the protocol,
//  the mode enum, and a stub.
//

import Foundation

/// Which rung of the rewrite ladder a request should use.
enum RewriteMode {
    case cloud   // Claude API (future pass)
    case local   // LM Studio via localhost (future pass)
    case raw     // no rewrite, pass transcript through
}

/// The outcome of a rewrite: the cleaned (or raw-passthrough) text plus enough
/// diagnostics to log what actually ran — which engine/model, and whether the
/// ladder fell back to raw. A value type so it crosses back from the nonisolated
/// rewriters without a Sendable hazard.
struct RewriteResult: Sendable {
    let text: String
    let engine: String        // display name: "Claude" / "ChatGPT" / "LM Studio"
    let model: String?        // resolved/pinned model id; nil on raw fallback
    let usedRawFallback: Bool
}

/// Cleans up / reformats transcribed text before injection.
protocol Rewriter {
    func rewrite(_ text: String) async throws -> RewriteResult
}

/// Appends a visible suffix so the rewrite step is observable.
nonisolated struct StubRewriter: Rewriter {
    func rewrite(_ text: String) async throws -> RewriteResult {
        try await Task.sleep(for: .milliseconds(300))
        return RewriteResult(text: text + " [rewritten]", engine: "Stub", model: nil, usedRawFallback: false)
    }
}
