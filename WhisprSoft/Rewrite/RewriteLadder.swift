//
//  RewriteLadder.swift
//  WhisprSoft
//
//  Picks a rewrite backend by the persisted "localMode" toggle and falls back
//  to raw passthrough so dictation always produces text. The toggle is read
//  fresh per call so flipping it takes effect immediately.
//
//  Local Mode is LOCAL-ONLY (the privacy guarantee): when on, the rewrite goes
//  to LM Studio and, on any failure, falls back to the raw transcript — NEVER
//  to the cloud. Cloud Mode: cloud → raw, as before. Either way, text derived
//  from audio only leaves the Mac when the user has cloud mode selected.
//

import Foundation
import os

/// Mode-aware rewrite ladder. `nonisolated` to match the protocol witness.
nonisolated struct RewriteLadder: Rewriter {
    let cloud: Rewriter
    let local: Rewriter

    func rewrite(_ text: String) async throws -> String {
        guard !text.isEmpty else { return text }
        let localMode = UserDefaults.standard.bool(forKey: "localMode")
        let primary = localMode ? local : cloud
        do {
            return try await primary.rewrite(text)
        } catch {
            // Raw passthrough — a backend failure must never block injection;
            // we always paste something. Crucially, we fall back to raw, never
            // to the *other* backend: Local Mode stays local-only.
            Log.rewrite.error("\(localMode ? "local" : "cloud", privacy: .public) rewrite failed, using raw: \(error.localizedDescription, privacy: .public)")
            return text
        }
    }
}
