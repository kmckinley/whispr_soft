//
//  ToneChordStore.swift
//  WhisprSoft
//
//  Up to three user-assignable "tone chords": each a reference to a tone profile
//  plus a single chord key. The modifier is FIXED at Control+Option for every
//  slot, so only the key (`keyCode`) is stored. Pressing an assigned chord starts
//  a ONE-SHOT dictation in that tone — the persisted/active tone is never touched
//  (the Coordinator threads the tone as a one-run override; see ToneSelection).
//
//  This is additive: the default dictation shortcut (DictationShortcut) and the
//  Dictate-tab tone picker are unchanged. Owned by AppDelegate; the Settings UI
//  binds to `slots`. The HotkeyMonitor reads the resolved chords fresh via
//  `active()` (the read-fresh pattern DictationShortcut / TargetLanguage use),
//  caching them like the primary chord — the per-event hot path never reads
//  UserDefaults. Mirrors CorrectionsStore / RewriteProfilesStore persistence.
//

import CoreGraphics
import Foundation
import Observation

/// One tone-chord slot: a tone reference + a chord key. Modifiers are fixed at
/// ⌃⌥, so only `keyCode` is stored. A slot is "armed" (registered as a global
/// chord) only when BOTH `toneID` and `keyCode` are set; either nil = a partial
/// or empty slot that does nothing.
struct ToneChordSlot: Codable, Equatable, Sendable {
    var toneID: UUID?
    var keyCode: Int64?

    static let empty = ToneChordSlot(toneID: nil, keyCode: nil)
}

/// A resolved, registerable tone chord for the event tap: the key plus the tone
/// it triggers. The modifiers are the fixed ⌃⌥ (see `ToneChordStore.modifiers`).
/// `Sendable` so the nonisolated monitor can cache it.
nonisolated struct ResolvedToneChord: Sendable, Equatable {
    let keyCode: Int64
    let toneID: UUID
}

/// The three tone-chord slots and their persistence. Owned by AppDelegate; the
/// Settings UI binds to `slots`. The monitor reads `active()` fresh per arm.
@MainActor
@Observable
final class ToneChordStore {
    /// Persisted slots key. `nonisolated` so `active()` can read it off-main.
    nonisolated static let storageKey = "toneChords"

    /// Exactly three slots (the feature cap).
    static let slotCount = 3

    /// The fixed modifier set every tone chord uses: Control+Option. Stored as a
    /// raw CGEventFlags value so the nonisolated monitor can build its flag set.
    nonisolated static let modifiers: UInt64 =
        CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue

    var slots: [ToneChordSlot] = Array(repeating: .empty, count: ToneChordStore.slotCount)

    init() { load() }

    /// Persist the current slots. Called by the Settings UI after every edit.
    func save() {
        guard let data = try? JSONEncoder().encode(slots) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([ToneChordSlot].self, from: data)
        else { return }   // absent / malformed → keep the three empty slots
        // Normalize to exactly slotCount: pad short, truncate long, so the UI's
        // fixed three rows always have a backing slot regardless of stored shape.
        var normalized = decoded
        if normalized.count < Self.slotCount {
            normalized += Array(repeating: .empty, count: Self.slotCount - normalized.count)
        } else if normalized.count > Self.slotCount {
            normalized = Array(normalized.prefix(Self.slotCount))
        }
        slots = normalized
    }

    // MARK: - Resolver (read fresh by the nonisolated monitor)

    /// The armed tone chords, read fresh from UserDefaults, with any chord whose
    /// tone no longer exists DROPPED — so a deleted tone's key types normally
    /// again (the slot is treated as unassigned). The Coordinator's begin-time
    /// resolve is the backstop for a tone deleted between cache reloads.
    nonisolated static func active() -> [ResolvedToneChord] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let slots = try? JSONDecoder().decode([ToneChordSlot].self, from: data)
        else { return [] }

        let existingIDs = existingProfileIDs()
        return slots.compactMap { slot in
            guard let toneID = slot.toneID, let keyCode = slot.keyCode,
                  existingIDs.contains(toneID)
            else { return nil }
            return ResolvedToneChord(keyCode: keyCode, toneID: toneID)
        }
    }

    /// The set of tone-profile ids that currently exist, decoded fresh from the
    /// profiles store's own key. Used to drop tone chords whose tone was deleted.
    nonisolated private static func existingProfileIDs() -> Set<UUID> {
        guard let data = UserDefaults.standard.data(forKey: RewriteProfilesStore.storageKey),
              let items = try? JSONDecoder().decode([RewriteProfile].self, from: data)
        else { return [] }
        return Set(items.map(\.id))
    }
}
