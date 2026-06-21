//
//  AppToneMapStore.swift
//  WhisprSoft
//
//  App-context tone mapping for the DEFAULT dictation chord: a user-editable
//  list pairing a frontmost-app bundle id with a tone profile, so dictating into
//  (say) Slack uses "Client comms" while Terminal uses "Technical" — without the
//  user touching the active tone. One mapping per app; any tone profile can be
//  referenced by id. A tone-chord (⌃⌥) one-shot STILL overrides app context — app
//  mapping applies only to the default chord (see Coordinator.beginDictation).
//
//  Ships EMPTY (opt-in). Owned by AppDelegate; the Settings UI binds to `items`.
//  The Coordinator reads the mapping fresh per dictation via the `nonisolated
//  static resolve(bundleID:)` (the read-fresh pattern, mirroring
//  RewriteProfilesStore.resolveOverride / ToneChordStore.active). Mirrors
//  CorrectionsStore / RewriteProfilesStore persistence.
//

import Foundation
import Observation

/// One app→tone mapping. `appName` is the display name captured when the mapping
/// is added (so the row reads nicely even for a not-currently-running app);
/// `toneID` references a `RewriteProfile.id`.
struct AppToneMapping: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var bundleID: String
    var appName: String
    var toneID: UUID
}

/// The editable app→tone mappings and their persistence. Owned by AppDelegate;
/// the Settings UI binds to `items`. The Coordinator reads the same key fresh per
/// dictation via the `nonisolated static resolve`.
@MainActor
@Observable
final class AppToneMapStore {
    /// Nonisolated so the `nonisolated static resolve` can read the same key.
    nonisolated static let storageKey = "appToneMappings"

    var items: [AppToneMapping] = []

    init() { load() }

    /// Persist the current list. Called by the Settings UI's `.onChange(of:)`.
    func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// Absent / malformed → []. Ships empty (opt-in); there's no first-run seed.
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([AppToneMapping].self, from: data)
        else { return }
        items = decoded
    }

    // MARK: - Resolver (read fresh by the Coordinator)

    /// The tone mapped to `bundleID`, or nil if no mapping exists OR the mapped
    /// tone was deleted. Delegates to `RewriteProfilesStore.resolveOverride` so a
    /// blank-instruction tone still yields a name with a nil profile (plain
    /// cleanup), and a deleted tone resolves to nil (treated as no mapping).
    nonisolated static func resolve(bundleID: String)
        -> (name: String, profile: RewriteProfilesStore.ActiveRewriteProfile?)? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let items = try? JSONDecoder().decode([AppToneMapping].self, from: data),
              let mapping = items.first(where: { $0.bundleID == bundleID })
        else { return nil }
        return RewriteProfilesStore.resolveOverride(id: mapping.toneID)
    }
}
