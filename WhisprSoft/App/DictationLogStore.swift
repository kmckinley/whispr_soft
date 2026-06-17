//
//  DictationLogStore.swift
//  WhisprSoft
//
//  In-memory diagnostic log of recent dictations. One entry per run records what
//  engine/model ran, whether the ladder fell back to raw, where the text went,
//  per-stage timings, and char counts — enough to answer "what just happened?"
//  without reading Console.
//
//  In-memory ONLY by design: entries are NEVER written to disk and are lost on
//  quit. They never contain transcript content — only counts and metadata. The
//  Settings "Show logs" toggle controls visibility; collection always happens.
//

import Foundation
import Observation

/// One dictation's diagnostic record. A value type so the Coordinator can build
/// it off whatever it measured and hand it to the store.
struct DictationLogEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let engine: String        // "Claude" / "ChatGPT" / "LM Studio" / "—"
    let model: String?
    let usedRawFallback: Bool
    let destination: String   // "Pasted" / "Note" / "—"
    let recordMs: Int         // hold duration (begin→end)
    let transcriptionMs: Int  // speech-to-text
    let rewriteMs: Int        // cleanup/rewrite stage
    let totalMs: Int          // stop→delivered (processing, excludes hold)
    let inputChars: Int       // transcript length
    let outputChars: Int      // final delivered length
    let status: String        // "OK" / "No audio" / "Error: …"
}

/// Holds the recent dictation entries in memory (newest first), capped as a ring
/// buffer. Owned by `AppDelegate`, mirroring the other `@MainActor @Observable`
/// stores; the Coordinator writes, the menu reads.
@MainActor
@Observable
final class DictationLogStore {
    private(set) var entries: [DictationLogEntry] = []
    private let cap = 100   // ring buffer; newest first

    /// Nonisolated so it can construct in the Coordinator's default arguments
    /// (the same pattern the other injected stores use).
    nonisolated init() {}

    func record(_ e: DictationLogEntry) {
        entries.insert(e, at: 0)
        if entries.count > cap { entries.removeLast(entries.count - cap) }
    }

    func clear() { entries.removeAll() }
}
