//
//  ScratchpadStore.swift
//  WhisprSoft
//
//  In-memory "quick note" scratchpad. Shared by the Coordinator (writer) and
//  MenuBarContent (reader/editor). When dictation begins while the menu-bar
//  popover is open, the cleaned-up text is appended here instead of being
//  pasted into the frontmost app.
//
//  Session-only by design: the note survives closing/reopening the popover and
//  switching tabs, but is NOT persisted to disk — it's lost on quit.
//

import Foundation
import Observation

@MainActor
@Observable
final class ScratchpadStore {
    /// True while the menu-bar popover window is visible. Set by MenuBarContent.
    var isPopoverOpen = false
    /// Whether the note box is shown on the Dictate tab.
    private(set) var isExpanded = false
    /// True while a dictation is being captured into the note (drives the
    /// box's listening indicator).
    private(set) var isCapturing = false
    /// The note text. Bound to the editor; also mutated by append/clear.
    var text = ""

    /// Nonisolated so it can construct in the Coordinator's default arguments
    /// (the same pattern the nonisolated stubs use). Only initializes defaults.
    nonisolated init() {}

    func beginCapture() { isExpanded = true; isCapturing = true }

    /// End the capture. Collapse the box only if there's nothing to show — so a
    /// failed/empty capture (beginCapture eagerly expanded to show "listening")
    /// doesn't leave an empty box stuck open, while a capture that produced text
    /// (or a note that already held text) stays visible.
    func endCapture() {
        isCapturing = false
        if text.isEmpty { isExpanded = false }
    }

    func append(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        text = text.isEmpty ? t : text + "\n" + t
        isExpanded = true
    }

    func clear() { text = ""; isExpanded = false }
}
