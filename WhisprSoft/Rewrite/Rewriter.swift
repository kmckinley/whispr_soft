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

/// Cleans up / reformats transcribed text before injection.
protocol Rewriter {
    func rewrite(_ text: String) async throws -> String
}

/// Appends a visible suffix so the rewrite step is observable.
nonisolated struct StubRewriter: Rewriter {
    func rewrite(_ text: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(300))
        return text + " [rewritten]"
    }
}
