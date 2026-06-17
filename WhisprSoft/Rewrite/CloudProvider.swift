//
//  CloudProvider.swift
//  WhisprSoft
//
//  The cloud rewrite provider selection (Claude vs. ChatGPT), used only in Cloud
//  Mode. The selection persists as a stable `rawValue` slug in UserDefaults and
//  is read fresh per call via `active()` — the read-fresh pattern Local Mode and
//  TargetLanguage use, so a change applies on the next dictation without
//  relaunch. Local Mode (LM Studio) is unaffected and stays local-only.
//

import Foundation

/// Which cloud backend the rewrite goes to when Local Mode is off. Default is
/// Claude for any absent / unknown stored value.
nonisolated enum CloudProvider: String, CaseIterable, Identifiable {
    case claude, openai

    var id: String { rawValue }

    /// Persisted selection key, storing the chosen provider's `rawValue`. Shared
    /// by the UI's `@AppStorage` and `active()`.
    static let storageKey = "cloudProvider"

    var displayName: String { self == .claude ? "Claude" : "ChatGPT" }

    /// Read fresh per call; default Claude for absent/unknown values.
    static func active() -> CloudProvider {
        CloudProvider(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .claude
    }
}
