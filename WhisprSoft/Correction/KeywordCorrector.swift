//
//  KeywordCorrector.swift
//  WhisprSoft
//
//  Deterministic find-replace that runs as the FINAL pipeline step — after the
//  LLM rewrite, before injection — so neither Whisper's mishearing nor the LLM
//  can leave a wrong spelling (e.g. "acme co" → "Acme Co"). A pure function,
//  not a protocol-injected stage: there's no swappable backend to abstract.
//

import Foundation
import os

nonisolated enum KeywordCorrector {
    /// Reads the user's stored corrections (managed by CorrectionsStore) fresh
    /// each call, so edits in the menu take effect on the next dictation with
    /// no relaunch. Whole-word, case-insensitive; replacement casing preserved.
    static func correct(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let corrections = loadCorrections()
        guard !corrections.isEmpty else { return text }

        var result = text
        var applied = 0
        for correction in corrections {
            let from = correction.from.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty else { continue }   // blank rows are no-ops
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: from) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let template = NSRegularExpression.escapedTemplate(for: correction.to)
            let count = regex.numberOfMatches(in: result, range: NSRange(result.startIndex..., in: result))
            if count > 0 {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
                applied += count
            }
        }
        if applied > 0 {
            Log.correction.notice("KeywordCorrector: applied \(applied, privacy: .public) correction(s)")
        }
        return result
    }

    private static func loadCorrections() -> [Correction] {
        guard let data = UserDefaults.standard.data(forKey: CorrectionsStore.storageKey),
              let items = try? JSONDecoder().decode([Correction].self, from: data)
        else { return [] }
        return items
    }
}
