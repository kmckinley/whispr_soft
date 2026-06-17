//
//  HotkeyMonitor.swift
//  WhisprSoft
//
//  Global hold-to-talk hotkey built on an active CGEventTap. The chord is
//  user-configurable (default ⌃⌥Space) via DictationShortcut; the monitor
//  CACHES it in `shortcut` (reloaded explicitly via reloadShortcut(), not read
//  per event — the tap sees every keystroke system-wide, so a per-event
//  UserDefaults read/parse would add work to the latency-sensitive hot path).
//  Recording runs while the chord is held: onChordDown fires on key-down,
//  onChordUp on key-up (or when a required modifier is released mid-hold).
//
//  The one tap matches the default chord PLUS up to three optional "tone chords"
//  (⌃⌥ + a user-chosen key, each tied to a tone profile). A tone-chord press
//  passes its tone id to onChordDown for a one-shot tone override; the default
//  chord passes nil. Save-time keyCode-uniqueness across all chords keeps the
//  subset modifier match unambiguous.
//
//  Concurrency: the tap's run-loop source lives on the MAIN run loop, so the
//  C callback fires on the main thread. The file-scope trampoline is
//  `nonisolated` (a @convention(c) pointer can't be formed from a
//  MainActor-isolated function under the project's default isolation) and
//  bridges into the actor via MainActor.assumeIsolated, letting handle() and
//  the callbacks be MainActor-isolated and call the Coordinator directly.
//

import CoreGraphics
import Foundation
import os

@MainActor
final class HotkeyMonitor {
    /// Fired when a chord is first pressed. The argument is the tone id to use for
    /// a one-shot tone-chord dictation, or nil for the default dictation chord.
    /// Defaulted to a no-op so the monitor is usable before the Coordinator wires
    /// it up.
    var onChordDown: (UUID?) -> Void = { _ in }
    /// Fired when the engaged chord is released (main key up, or a modifier
    /// dropped). The tone was captured at chord-down, so this carries nothing.
    var onChordUp: () -> Void = {}

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Dictation is active (between onChordDown and onChordUp).
    private var chordEngaged = false
    /// The required modifier flags of the currently-engaged chord, captured at
    /// engage so `flagsChanged` knows which modifiers ending the hold to watch
    /// (the default chord and tone chords can require different modifiers).
    private var engagedFlags: CGEventFlags = []
    /// The main key is physically down as part of the gesture: suppress every
    /// event for that key until it lifts. Tracked separately from `chordEngaged`
    /// so that releasing a *modifier* first (which ends dictation) still consumes
    /// the trailing auto-repeats and keyUp — otherwise they'd leak as a typed
    /// character once the modifier-gated consume condition stopped matching.
    private var consumingMainKey = false
    /// The keycode being consumed while `consumingMainKey` (the engaged chord's
    /// main key). Distinguishes our gesture's key from any other key. -1 = none.
    private var consumingKeyCode: Int64 = -1

    /// The configured default chord. Cached, not read per event (see file header);
    /// refreshed via reloadShortcut() at arm time and on a live binding change.
    private var shortcut: DictationShortcut = .default

    /// The cached tone chords (⌃⌥ + key → tone id). Reloaded alongside `shortcut`;
    /// matched after the default chord. Save-time keyCode-uniqueness guarantees at
    /// most one chord (default OR a tone chord) matches any physical press, so the
    /// subset modifier test below is never ambiguous across chords.
    private var toneChords: [ResolvedToneChord] = []

    /// Re-read the configured default chord AND the tone chords from UserDefaults.
    /// Called at the top of start() (so arming picks up the current bindings) and
    /// by Coordinator.updateHotkey() when the user changes any of them (a binding
    /// edit or a tone deletion), so the live tap updates without a relaunch.
    func reloadShortcut() {
        shortcut = .active()
        toneChords = ToneChordStore.active()
    }

    /// Create and enable the event tap. Idempotent: a no-op if already
    /// running. The tap is ACTIVE (`.defaultTap`, it can discard the Space
    /// key), so it's authorized by Accessibility — not Input Monitoring. If
    /// Accessibility isn't granted, `tapCreate` returns nil and we bail; the
    /// permission gate brings us back once it's granted.
    func start() {
        reloadShortcut()
        guard tap == nil else { return }

        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,                 // active: may discard events
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.hotkey.error("HotkeyMonitor: tapCreate returned nil (Accessibility not granted?)")
            return
        }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        Log.hotkey.notice("HotkeyMonitor: event tap enabled")
    }

    /// Disable the tap, detach its run-loop source, and clear all state.
    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil
        chordEngaged = false
        engagedFlags = []
        consumingMainKey = false
        consumingKeyCode = -1
        Log.hotkey.notice("HotkeyMonitor: event tap disabled")
    }

    /// Called on the main thread (via the trampoline) for every tapped event.
    /// Returns nil to consume the event, or the event to pass it through.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables the tap on slow callbacks / certain input;
        // re-enabling keeps it alive. Pass the event through unchanged.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Log.hotkey.notice("HotkeyMonitor: tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public)")
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        switch type {
        case .keyDown:
            // Auto-repeat (or any press) of the key the gesture already owns —
            // consume so no character is typed, even if a modifier lifted.
            if consumingMainKey && keyCode == consumingKeyCode { return nil }
            // Engaging press: a chord matches (required modifiers + its key) while
            // none is engaged. matchChord() resolves the default chord OR a tone
            // chord; keyCode-uniqueness makes the result unambiguous.
            if !chordEngaged, let match = matchChord(keyCode: keyCode, flags: flags) {
                chordEngaged = true
                engagedFlags = match.flags
                consumingMainKey = true
                consumingKeyCode = keyCode
                onChordDown(match.toneID)
                return nil
            }
            // A key unrelated to any gesture — pass it through.
            return Unmanaged.passUnretained(event)

        case .keyUp where consumingMainKey && keyCode == consumingKeyCode:
            // Main key released: stop suppressing, and end the chord if it's
            // still engaged (it may already have ended via a modifier release).
            consumingMainKey = false
            consumingKeyCode = -1
            if chordEngaged {
                chordEngaged = false
                onChordUp()
            }
            return nil

        case .flagsChanged where chordEngaged && !flags.contains(engagedFlags):
            // A required modifier was released mid-hold: end the chord now, but
            // keep `consumingMainKey` set so the trailing main-key auto-repeats
            // and keyUp are still swallowed. Don't consume the modifier change.
            chordEngaged = false
            onChordUp()
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// The chord matching a physical press, or nil. The default chord uses its
    /// configured modifiers; tone chords use the fixed ⌃⌥. The test is a SUBSET
    /// test (all required modifiers present; extras don't block) — matching the
    /// existing behavior. Save-time keyCode-uniqueness across the default chord
    /// and all tone chords guarantees at most one match, so order is immaterial.
    private func matchChord(keyCode: Int64, flags: CGEventFlags) -> (flags: CGEventFlags, toneID: UUID?)? {
        if keyCode == shortcut.keyCode, flags.contains(shortcut.cgFlags) {
            return (shortcut.cgFlags, nil)
        }
        let toneFlags = CGEventFlags(rawValue: ToneChordStore.modifiers)
        for chord in toneChords where keyCode == chord.keyCode && flags.contains(toneFlags) {
            return (toneFlags, chord.toneID)
        }
        return nil
    }
}

/// C trampoline for the tap. `nonisolated` so a @convention(c) function
/// pointer can be formed under the project's MainActor default isolation.
/// The source is on the main run loop, so this fires on the main thread;
/// MainActor.assumeIsolated lets handle() and the callbacks stay isolated.
private nonisolated func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return MainActor.assumeIsolated {
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo)
            .takeUnretainedValue()
        return monitor.handle(type: type, event: event)
    }
}
