//
//  DictationLogStore.swift
//  WhisprSoft
//
//  Diagnostic log of recent dictations. One entry per run records what
//  engine/model ran, whether the ladder fell back (raw or cross-provider), where
//  the text went, per-stage timings, and char counts — enough to answer "what
//  just happened?" without reading Console.
//
//  Persisted to UserDefaults (JSON), loaded at launch and capped as a ring
//  buffer. Persistence is privacy-safe because a `DictationLogEntry` holds ONLY
//  counts/timings/engine metadata — never transcript content, so no dictated text
//  ever reaches disk. The Settings "Show logs" toggle controls visibility;
//  collection and persistence always happen.
//

import Foundation
import Observation

/// One dictation's diagnostic record. A value type so the Coordinator can build
/// it off whatever it measured and hand it to the store. `Codable` so the store
/// can persist the list — all value types plus a synthesized `id`, so the
/// synthesized conformance round-trips cleanly. It holds only counts/timings/
/// metadata, never transcript content, so persisting it is privacy-safe.
struct DictationLogEntry: Identifiable, Sendable, Codable {
    let id = UUID()
    let date: Date
    let engine: String        // "Claude" / "ChatGPT" / "LM Studio" / "—"
    let model: String?
    let usedRawFallback: Bool
    /// True when the ladder's cross-provider fallback delivered this text (the
    /// active cloud provider failed, the other one succeeded). Default so the
    /// no-audio / error construction sites don't all need updating; mutually
    /// exclusive with `usedRawFallback` on the success path.
    var usedProviderFallback: Bool = false
    let destination: String   // "Pasted" / "Note" / "—"
    let recordMs: Int         // hold duration (begin→end)
    let transcriptionMs: Int  // speech-to-text
    let rewriteMs: Int        // cleanup/rewrite stage
    let totalMs: Int          // stop→delivered (processing, excludes hold)
    let inputChars: Int       // transcript length
    let outputChars: Int      // final delivered length
    let status: String        // "OK" / "No audio" / "Error: …"

    /// `id` is omitted from coding: a `let id = UUID()` can't be overwritten on
    /// decode (Swift warns), and the id is only SwiftUI list identity within a
    /// session — a fresh UUID on load is fine. Everything else round-trips.
    private enum CodingKeys: String, CodingKey {
        case date, engine, model, usedRawFallback, usedProviderFallback
        case destination, recordMs, transcriptionMs, rewriteMs, totalMs
        case inputChars, outputChars, status
    }
}

/// Holds the recent dictation entries in memory (newest first), capped as a ring
/// buffer. Owned by `AppDelegate`, mirroring the other `@MainActor @Observable`
/// stores; the Coordinator writes, the menu reads.
@MainActor
@Observable
final class DictationLogStore {
    /// Persisted JSON list of entries (metadata only — no transcript content, so
    /// safe to write to disk). Mirrors CorrectionsStore's persistence pattern.
    nonisolated static let storageKey = "dictationLog"

    /// Seeded from the persisted list via a nonisolated default initializer, so a
    /// nonisolated `init()` (needed for the Coordinator's default arguments) can
    /// construct the store without touching the MainActor-isolated property body.
    private(set) var entries: [DictationLogEntry] = DictationLogStore.loadEntries()
    private let cap = 100   // ring buffer; newest first, bounds the stored size

    /// Nonisolated so it can construct in the Coordinator's default arguments
    /// (the same pattern the other injected stores use).
    nonisolated init() {}

    func record(_ e: DictationLogEntry) {
        entries.insert(e, at: 0)
        if entries.count > cap { entries.removeLast(entries.count - cap) }
        save()
    }

    func clear() { entries.removeAll(); save() }

    /// Persist the current list as JSON. Called after every mutation.
    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// Restore the persisted list; on absence or a decode failure, return empty
    /// (logs were never persisted before, so no migration is needed). Nonisolated
    /// so the nonisolated init can call it.
    private nonisolated static func loadEntries() -> [DictationLogEntry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([DictationLogEntry].self, from: data)
        else { return [] }
        return decoded
    }
}
