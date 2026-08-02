//
//  TranscriptFilter.swift
//  WhisprSoft
//
//  Strips known Whisper hallucinations from the RAW transcript, right after
//  transcription and before the rewrite stage. small.en was trained on scraped
//  subtitle files, so on silence / near-silence it can emit a phantom
//  "subtitle credit" (famously the non-existent zeoranger.co.uk). The rewrite
//  stage is told never to remove content, so it would pass the phantom through
//  — this pure function removes it deterministically instead.
//
//  Intentionally NARROW: only phrases anchored on tokens a person would never
//  dictate. Add new phantoms to `hallucinationPatterns` as they surface — one
//  entry per family — without changing the strip logic below.
//

import Foundation
import os

nonisolated enum TranscriptFilter {
    /// Case-insensitive regex fragments, each matching one hallucination family
    /// plus its optional "subs/subtitles by ..." lead-in and trailing dot.
    private static let hallucinationPatterns: [String] = [
        // "Subs by www.zeoranger.co.uk", "Subtitles by www.zeoranger.co.uk",
        // bare "www.zeoranger.co.uk", trailing period, any casing. The lead-in
        // is only consumed when "zeoranger" follows, so "subtitles by John" is
        // never touched. The anchor is \b-bounded on both sides so a longer word
        // merely *containing* the token isn't partially eaten.
        #"(?:sub(?:title)?s?\s+by\s+)?(?:the\s+)?(?:www\.)?\bzeoranger(?:\.co\.uk)?\b\.?"#,
    ]

    /// Removes every known hallucination phrase, collapses the whitespace the
    /// removal leaves behind, and trims. A take that transcribed to nothing but
    /// the phantom collapses to "" — the rewrite ladder treats empty input as a
    /// no-op and nothing is injected.
    static func strip(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = text
        var removed = 0
        for fragment in hallucinationPatterns {
            guard let regex = try? NSRegularExpression(pattern: fragment, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            let count = regex.numberOfMatches(in: result, range: range)
            if count > 0 {
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
                removed += count
            }
        }

        guard removed > 0 else { return text }

        result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        Log.transcription.notice("TranscriptFilter: removed \(removed, privacy: .public) known hallucination phrase(s)")
        return result
    }
}
