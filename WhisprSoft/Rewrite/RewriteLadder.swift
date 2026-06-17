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
//  to the cloud. Cloud Mode routes to the selected cloud provider (Claude or
//  ChatGPT) and falls back to raw on any failure, as before. Either way, text
//  derived from audio only leaves the Mac when the user has a cloud provider
//  selected (Local Mode off).
//

import Foundation
import os

/// Mode-aware rewrite ladder. `nonisolated` to match the protocol witness. In
/// Cloud Mode it picks between two cloud backends by the persisted
/// `CloudProvider` selection; Local Mode stays local-only.
nonisolated struct RewriteLadder: Rewriter {
    let claude: Rewriter
    let openai: Rewriter
    let local: Rewriter

    func rewrite(_ text: String) async throws -> RewriteResult {
        let localMode = UserDefaults.standard.bool(forKey: "localMode")
        // The engine the user *intended* this run to use, independent of whether
        // it succeeded — so the dictation log shows "Claude (raw fallback)"
        // rather than a bare "—" when the backend fails.
        let intendedEngine = localMode ? "LM Studio" : CloudProvider.active().displayName

        guard !text.isEmpty else {
            return RewriteResult(text: text, engine: intendedEngine, model: nil, usedRawFallback: false)
        }

        // Pick the primary backend. Both the localMode flag and the cloud
        // provider are read fresh per call so switching either takes effect on
        // the next dictation without relaunch.
        let primary: Rewriter
        let label: String
        if localMode {
            primary = local; label = "local"
        } else if CloudProvider.active() == .openai {
            primary = openai; label = "openai"
        } else {
            primary = claude; label = "claude"
        }

        do {
            return try await primary.rewrite(text)
        } catch {
            Log.rewrite.error("\(label, privacy: .public) rewrite failed: \(error.localizedDescription, privacy: .public)")

            // Cross-provider fallback (Cloud Mode only, opt-in). Local Mode is
            // never eligible — it stays local-only (the privacy guarantee). The
            // toggle is read fresh per call so flipping it takes effect at once.
            let fallbackEnabled = UserDefaults.standard.bool(forKey: "cloudProviderFallback")
            if !localMode, fallbackEnabled {
                let active = CloudProvider.active()
                let other: CloudProvider = active == .openai ? .claude : .openai
                // Defensive re-check: the toggle could have been enabled while
                // both keys were set, then a key removed afterwards. If the other
                // provider's key is gone, skip straight to raw.
                let otherKey = other == .claude ? Keychain.apiKey() : Keychain.openAIKey()
                if let otherKey, !otherKey.isEmpty {
                    let secondary: Rewriter = other == .openai ? openai : claude
                    do {
                        var rr = try await secondary.rewrite(text)
                        rr.usedProviderFallback = true
                        Log.rewrite.notice("provider fallback: \(active.displayName, privacy: .public) failed, used \(other.displayName, privacy: .public)")
                        return rr
                    } catch {
                        Log.rewrite.error("provider fallback also failed (\(other.displayName, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                        // Fall through to raw passthrough below.
                    }
                }
            }

            // Raw passthrough — a backend failure must never block injection; we
            // always paste something. `intendedEngine` keeps the log showing the
            // active provider's name (e.g. "Claude · raw fallback"). Note
            // `usedProviderFallback` stays false here even when the secondary
            // also failed, so the "successful cross-provider save" count stays
            // clean (the both-failed case is captured by the Console log above).
            Log.rewrite.error("\(label, privacy: .public) using raw passthrough")
            return RewriteResult(text: text, engine: intendedEngine, model: nil, usedRawFallback: true)
        }
    }
}
