//
//  CorrectionsStore.swift
//  WhisprSoft
//
//  The editable keyword-corrections list + its persistence. Owned by
//  AppDelegate; the menu binds to `items`. KeywordCorrector reads the same
//  UserDefaults key fresh per call (the read-fresh pattern Local Mode uses),
//  so edits apply on the next dictation without relaunch.
//

import Foundation
import Observation

/// One find→replace rule. `from` is matched whole-word, case-insensitively;
/// `to` is inserted verbatim. An empty `to` is allowed (deletes the match).
struct Correction: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var from: String
    var to: String
}

/// The editable corrections list + its persistence. Owned by AppDelegate; the
/// menu binds to `items`. KeywordCorrector reads the same UserDefaults key.
@MainActor
@Observable
final class CorrectionsStore {
    /// Nonisolated so the `nonisolated` KeywordCorrector can read the same key.
    nonisolated static let storageKey = "keywordCorrections"

    var items: [Correction] = []

    init() { load() }

    func add() { items.append(Correction(from: "", to: "")) }

    func remove(_ correction: Correction) {
        items.removeAll { $0.id == correction.id }
    }

    /// Persist the current list. Called by the view whenever `items` changes.
    func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([Correction].self, from: data)
        else { items = []; return }
        items = decoded
    }

    /// The replacement (`to`) terms, fed to WhisperKit as a decoding bias so the
    /// user's curated domain vocabulary is recognised at transcription time —
    /// complementing the after-the-fact correction. Read fresh from the storage
    /// key (the same read-fresh pattern KeywordCorrector uses), so edits apply on
    /// the next dictation with no relaunch. Terms are trimmed, empties dropped,
    /// and de-duplicated preserving first-occurrence order — the user
    /// intentionally maps several misheard `from` variants to one `to`, so the
    /// raw list has repeats the prompt must collapse. `nonisolated` so the
    /// transcriber can call it off the main actor.
    nonisolated static func biasTerms() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let items = try? JSONDecoder().decode([Correction].self, from: data)
        else { return [] }

        var seen = Set<String>()
        var terms: [String] = []
        for item in items {
            let term = item.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
        }
        return terms
    }
}
