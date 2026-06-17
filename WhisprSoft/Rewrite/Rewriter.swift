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
    /// True only when the ladder's cross-provider fallback kicked in: the active
    /// cloud provider failed and the *other* one produced this text. A `var` with
    /// a default so every existing construction site (the rewriters, the stub,
    /// the ladder's raw/empty results) compiles unchanged — only the ladder's
    /// success-via-secondary path sets it true. Mutually exclusive with
    /// `usedRawFallback` on the success path.
    var usedProviderFallback: Bool = false
}

/// Which tone a single rewrite should apply. `.active` reads the persisted tone
/// selection fresh per call (normal dictation). `.override` forces a specific
/// tone for ONE run — a tone-chord dictation — without touching the persisted
/// selection; its associated value is nil when the forced tone resolves to plain
/// cleanup (a blank instruction), mirroring `RewriteProfilesStore.active()`'s
/// non-blank invariant.
enum ToneSelection: Sendable {
    case active
    case override(RewriteProfilesStore.ActiveRewriteProfile?)
}

/// Cleans up / reformats transcribed text before injection. `tone` is `.active`
/// for a normal dictation (the persisted tone selection, read fresh) or
/// `.override` for a one-shot tone-chord dictation.
protocol Rewriter {
    func rewrite(_ text: String, tone: ToneSelection) async throws -> RewriteResult
}

/// Appends a visible suffix so the rewrite step is observable.
nonisolated struct StubRewriter: Rewriter {
    func rewrite(_ text: String, tone: ToneSelection) async throws -> RewriteResult {
        try await Task.sleep(for: .milliseconds(300))
        return RewriteResult(text: text + " [rewritten]", engine: "Stub", model: nil, usedRawFallback: false)
    }
}
