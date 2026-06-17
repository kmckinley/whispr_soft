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
//  Concurrency: the tap's run-loop source lives on the MAIN run loop, so the
//  C callback fires on the main thread. The file-scope trampoline is
//  `nonisolated` (a @convention(c) pointer can't be formed from a
//  MainActor-isolated function under the project's default isolation) and
//  bridges into the actor via MainActor.assumeIsolated, letting handle() and
//  the callbacks be MainActor-isolated and call the Coordinator directly.
//

import CoreGraphics
import os

@MainActor
final class HotkeyMonitor {
    /// Fired when the chord is first pressed. Defaulted to a no-op so the
    /// monitor is usable before the Coordinator wires it up.
    var onChordDown: () -> Void = {}
    /// Fired when the chord is released (main key up, or a modifier dropped).
    var onChordUp: () -> Void = {}

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Dictation is active (between onChordDown and onChordUp).
    private var chordEngaged = false
    /// The main key is physically down as part of the gesture: suppress every
    /// event for that key until it lifts. Tracked separately from `chordEngaged`
    /// so that releasing a *modifier* first (which ends dictation) still consumes
    /// the trailing auto-repeats and keyUp — otherwise they'd leak as a typed
    /// character once the modifier-gated consume condition stopped matching.
    private var consumingMainKey = false

    /// The configured chord. Cached, not read per event (see file header);
    /// refreshed via reloadShortcut() at arm time and on a live binding change.
    private var shortcut: DictationShortcut = .default

    /// Re-read the configured shortcut from UserDefaults. Called at the top of
    /// start() (so arming picks up the current binding) and by
    /// Coordinator.updateHotkey() when the user changes it, so the live tap
    /// updates without a relaunch.
    func reloadShortcut() { shortcut = .active() }

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
        consumingMainKey = false
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
        // Subset test: all REQUIRED modifiers present (extra modifiers don't
        // block). OptionSet.contains is isSuperset, so this matches today's
        // behavior with the configured chord rather than a hardcoded ⌃⌥.
        let modifiersHeld = flags.contains(shortcut.cgFlags)
        let isMainKey = keyCode == shortcut.keyCode

        switch type {
        case .keyDown where isMainKey:
            // Engaging press: required modifiers + main key while not engaged.
            if !chordEngaged && modifiersHeld {
                chordEngaged = true
                consumingMainKey = true
                onChordDown()
                return nil
            }
            // Auto-repeat (or any press of the main key) once the gesture owns
            // it — consume so no character is typed, even if a modifier lifted.
            if consumingMainKey { return nil }
            // A plain press of the main key unrelated to the gesture — pass it.
            return Unmanaged.passUnretained(event)

        case .keyUp where isMainKey && consumingMainKey:
            // Main key released: stop suppressing, and end the chord if it's
            // still engaged (it may already have ended via a modifier release).
            consumingMainKey = false
            if chordEngaged {
                chordEngaged = false
                onChordUp()
            }
            return nil

        case .flagsChanged where chordEngaged && !modifiersHeld:
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
