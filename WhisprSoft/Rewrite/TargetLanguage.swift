//
//  TargetLanguage.swift
//  WhisprSoft
//
//  The fixed, built-in target-language list for dictation output. When a
//  non-default language is selected, HTTPRewriter appends an app-owned
//  `## Translate` section so the cleaned transcript is translated before
//  injection. The selection persists as a stable `id` slug in UserDefaults and
//  is read fresh per call via `active()` — the read-fresh pattern Local Mode,
//  CorrectionsStore, and RewriteProfilesStore use, so a change applies on the
//  next dictation without relaunch.
//
//  Not user-editable and not a protocol-typed stage: there's one use site
//  (HTTPRewriter), so no abstraction is warranted (project convention).
//

import Foundation

/// A built-in output language. `id` is a stable slug (the persisted key, never
/// the display name, so relabeling later doesn't orphan a saved selection);
/// `displayName` is the menu label; `englishName` is how the LLM is told to name
/// the target language in the `## Translate` section.
nonisolated struct TargetLanguage: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let englishName: String

    /// Default = English (United States) = no translation (current behavior).
    static let `default` = TargetLanguage(
        id: "en-US", displayName: "English (United States)", englishName: "English")

    /// false only for the default: when false, the cleanup output stays in the
    /// spoken language and the `## Translate` section is not appended.
    var translates: Bool { id != Self.default.id }

    /// Persisted selection key, storing the chosen language `id`. Absent / empty
    /// / unknown = default. Shared by the UI's `@AppStorage` and `active()`.
    static let storageKey = "selectedTargetLanguage"

    /// The fixed, ordered list shown in the picker. English (US) leads as the
    /// default; the rest are widely-used languages.
    static let all: [TargetLanguage] = [
        .default,
        TargetLanguage(id: "es",    displayName: "Spanish",                englishName: "Spanish"),
        TargetLanguage(id: "fr",    displayName: "French",                 englishName: "French"),
        TargetLanguage(id: "de",    displayName: "German",                 englishName: "German"),
        TargetLanguage(id: "it",    displayName: "Italian",                englishName: "Italian"),
        TargetLanguage(id: "pt-BR", displayName: "Portuguese (Brazil)",    englishName: "Brazilian Portuguese"),
        TargetLanguage(id: "nl",    displayName: "Dutch",                  englishName: "Dutch"),
        TargetLanguage(id: "ru",    displayName: "Russian",                englishName: "Russian"),
        TargetLanguage(id: "pl",    displayName: "Polish",                 englishName: "Polish"),
        TargetLanguage(id: "uk",    displayName: "Ukrainian",              englishName: "Ukrainian"),
        TargetLanguage(id: "ar",    displayName: "Arabic",                 englishName: "Arabic"),
        TargetLanguage(id: "he",    displayName: "Hebrew",                 englishName: "Hebrew"),
        TargetLanguage(id: "hi",    displayName: "Hindi",                  englishName: "Hindi"),
        TargetLanguage(id: "zh-Hans", displayName: "Chinese (Simplified)", englishName: "Simplified Chinese"),
        TargetLanguage(id: "zh-Hant", displayName: "Chinese (Traditional)", englishName: "Traditional Chinese"),
        TargetLanguage(id: "ja",    displayName: "Japanese",               englishName: "Japanese"),
        TargetLanguage(id: "ko",    displayName: "Korean",                 englishName: "Korean"),
        TargetLanguage(id: "vi",    displayName: "Vietnamese",             englishName: "Vietnamese"),
        TargetLanguage(id: "th",    displayName: "Thai",                   englishName: "Thai"),
        TargetLanguage(id: "tr",    displayName: "Turkish",                englishName: "Turkish"),
    ]

    /// Reads `storageKey` fresh from UserDefaults and returns the matching
    /// language, falling back to the default for an absent / empty / unknown id.
    /// Mirrors `RewriteProfilesStore.active()`.
    nonisolated static func active() -> TargetLanguage {
        guard let id = UserDefaults.standard.string(forKey: storageKey), !id.isEmpty,
              let match = all.first(where: { $0.id == id })
        else { return .default }
        return match
    }
}
