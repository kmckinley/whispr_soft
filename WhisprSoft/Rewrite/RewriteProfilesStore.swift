//
//  RewriteProfilesStore.swift
//  WhisprSoft
//
//  The user-editable rewrite "tone profiles" + their persistence. Owned by
//  AppDelegate; the menu binds to `items` and `selectedID`. HTTPRewriter reads
//  the same UserDefaults keys fresh per call via `active()` (the read-fresh
//  pattern Local Mode / CorrectionsStore use), so edits and the selection apply
//  on the next dictation without relaunch. Mirrors CorrectionsStore.
//

import Foundation
import Observation

/// One tone profile. `instruction` is a free-text style description applied as
/// a LIGHT TOUCH after cleanup. A blank instruction behaves as Default.
struct RewriteProfile: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var instruction: String

    /// The name to show in menus/pickers, falling back to "Untitled" for a blank
    /// name. Centralized so every display site stays consistent. `nonisolated` so
    /// the nonisolated resolvers (e.g. `activeDisplayName()`) can read it under the
    /// project's MainActor-default isolation.
    nonisolated var displayName: String { name.isEmpty ? "Untitled" : name }
}

/// The editable tone-profiles list, the active selection, and their
/// persistence. Owned by AppDelegate; the menu binds to `items`/`selectedID`.
/// HTTPRewriter reads the same keys fresh per call via `active()`.
@MainActor
@Observable
final class RewriteProfilesStore {
    /// Nonisolated so the `nonisolated` HTTPRewriter can read the same keys.
    nonisolated static let storageKey = "rewriteProfiles"
    /// Stores the selected profile's `uuidString`; absent / empty / no-match =
    /// "Default — clean up only".
    nonisolated static let selectionKey = "selectedRewriteProfileID"

    var items: [RewriteProfile] = []
    /// The active profile, nil = Default (plain cleanup).
    var selectedID: UUID?

    init() {
        load()
        loadSelection()
    }

    func add() {
        items.append(RewriteProfile(name: "New profile", instruction: ""))
    }

    func remove(_ profile: RewriteProfile) {
        items.removeAll { $0.id == profile.id }
        // If the active profile was removed, fall back to Default.
        if selectedID == profile.id {
            selectedID = nil
            saveSelection()
        }
    }

    /// Move a profile one step toward the top. Per-click reorder (the Tone
    /// tab's up/down arrows). Saved via the view's `.onChange(of: items)`.
    func moveUp(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), i > 0 else { return }
        items.swapAt(i, i - 1)
    }

    /// Move a profile one step toward the bottom.
    func moveDown(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), i < items.count - 1 else { return }
        items.swapAt(i, i + 1)
    }

    /// Persist the current list. Called by the view whenever `items` changes.
    func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// Persist the active selection. Called by the view whenever it changes.
    func saveSelection() {
        if let id = selectedID {
            UserDefaults.standard.set(id.uuidString, forKey: Self.selectionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectionKey)
        }
    }

    private func load() {
        let defaults = UserDefaults.standard
        // Seed starters ONLY on a true first run — when the key is entirely
        // absent. Once it exists (even as `[]`), never re-seed.
        guard let data = defaults.data(forKey: Self.storageKey) else {
            items = Self.starterProfiles
            save()
            return
        }
        guard let decoded = try? JSONDecoder().decode([RewriteProfile].self, from: data) else {
            items = []
            return
        }
        items = decoded
    }

    private func loadSelection() {
        selectedID = Self.loadSelectedID()
    }

    /// The persisted selected-profile id, or nil when the key is absent, empty,
    /// or malformed. Shared by `loadSelection()` and `active()` so both decode
    /// the selection identically. `nonisolated` so `active()` can call it.
    nonisolated private static func loadSelectedID() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: selectionKey),
              !raw.isEmpty
        else { return nil }
        return UUID(uuidString: raw)
    }

    /// Two starter profiles seeded on first run. Selection defaults to nil
    /// (Default), so first-run behavior is unchanged until the user opts in.
    private static let starterProfiles: [RewriteProfile] = [
        RewriteProfile(
            name: "Professional",
            instruction: "Polished and professional — complete sentences, a courteous businesslike register, minimal slang. Keep it natural, not stiff."),
        RewriteProfile(
            name: "Casual",
            instruction: "Relaxed and conversational, like talking to a friend. Contractions are fine; keep it warm and easygoing."),
    ]

    // MARK: - Active-profile resolver (read fresh by the nonisolated rewriter)

    /// The active profile reduced to what the rewriter needs, free of UI types.
    nonisolated struct ActiveRewriteProfile: Sendable {
        let name: String
        let instruction: String
    }

    /// Reads `selectionKey` + `storageKey` fresh from UserDefaults, finds the
    /// selected profile, and returns it ONLY if its `instruction` is non-blank
    /// after trimming. Returns nil for: no selection, selection not found
    /// (deleted), or blank instruction — all of which mean plain cleanup.
    nonisolated static func active() -> ActiveRewriteProfile? {
        guard let id = loadSelectedID(), let profile = storedProfile(id: id) else { return nil }

        let instruction = profile.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return nil }

        return ActiveRewriteProfile(name: profile.name, instruction: instruction)
    }

    /// The display name of the persisted tone selection, for the on-screen
    /// indicator: the selected profile's name, or "Default" when nothing is
    /// selected (or it was deleted). Distinct from `active()`: it returns a name
    /// even for a blank-instruction tone (which `active()` reduces to nil/plain
    /// cleanup), so the indicator can always show a tone even on a default run.
    nonisolated static func activeDisplayName() -> String {
        guard let id = loadSelectedID(), let profile = storedProfile(id: id) else { return "Default" }
        return profile.displayName
    }

    /// Decode `storageKey` fresh and return the profile with `id`, or nil. Shared
    /// decode+find for `active()` and `resolveOverride(id:)` so the two can't drift.
    nonisolated private static func storedProfile(id: UUID) -> RewriteProfile? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let items = try? JSONDecoder().decode([RewriteProfile].self, from: data)
        else { return nil }
        return items.first { $0.id == id }
    }

    /// Resolve a tone-chord binding's tone id for a ONE-SHOT override. Reads
    /// `storageKey` fresh (read-fresh pattern). Returns nil when no profile with
    /// `id` exists — the tone was deleted, so the caller treats the slot as
    /// unassigned (no-op). When it exists, `name` is its display label (for the
    /// recording indicator) and `profile` is the rewrite override: nil when the
    /// instruction is blank (force plain cleanup, mirroring `active()`'s non-blank
    /// invariant), otherwise the profile. Distinct from `active()`: this keeps the
    /// name even for a blank-instruction tone, and never consults the persisted
    /// selection.
    nonisolated static func resolveOverride(id: UUID) -> (name: String, profile: ActiveRewriteProfile?)? {
        guard let profile = storedProfile(id: id) else { return nil }

        let instruction = profile.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let override = instruction.isEmpty
            ? nil
            : ActiveRewriteProfile(name: profile.name, instruction: instruction)
        return (profile.name, override)
    }
}
