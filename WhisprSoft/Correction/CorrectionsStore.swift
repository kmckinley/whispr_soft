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
}
