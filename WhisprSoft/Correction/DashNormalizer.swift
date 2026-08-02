//
//  DashNormalizer.swift
//  WhisprSoft
//
//  Deterministic final pass that turns em dashes (and spaced en dashes) into
//  commas, so injected text never contains a "—". Runs after the LLM rewrite
//  and KeywordCorrector, as the last text touch before injection, so it catches
//  dashes regardless of which backend produced them. The cleanup prompt also
//  asks the model to avoid dashes — this guarantees the ones that slip through
//  are gone anyway.
//

import Foundation

nonisolated enum DashNormalizer {
    private static let emDash = "\u{2014}"   // —
    private static let enDash = "\u{2013}"   // –

    static func normalize(_ text: String) -> String {
        guard text.contains(emDash) || text.contains(enDash) else { return text }

        var result = text

        // Em dash, any surrounding spaces -> ", "
        result = replace(result, "[ \\t]*\(emDash)[ \\t]*", with: ", ")

        // En dash used as a SPACED separator -> ", " (tight "3–5" ranges,
        // which have no surrounding space, are left untouched).
        result = replace(result, "[ \\t]+\(enDash)[ \\t]*|[ \\t]*\(enDash)[ \\t]+", with: ", ")

        // Nothing was substituted (e.g. a tight "3–5" range was the only dash),
        // so the tidy pass below has nothing to clean up — and running it anyway
        // would eat a legitimate trailing comma this function never introduced.
        guard result != text else { return text }

        // Tidy artifacts: fold a comma pair the substitution created next to an
        // existing comma or a second dash ("first, — second", "a —— b"),
        // collapse ",   ", and strip a comma stranded at the very start or end.
        result = replace(result, ",[ \\t]*,", with: ",")
        result = replace(result, ",[ \\t]{2,}", with: ", ")
        result = replace(result, "^,[ \\t]*", with: "")
        result = replace(result, "[ \\t]*,[ \\t]*$", with: "")

        return result
    }

    private static func replace(_ s: String, _ pattern: String, with repl: String) -> String {
        s.replacingOccurrences(of: pattern, with: repl, options: .regularExpression)
    }
}
