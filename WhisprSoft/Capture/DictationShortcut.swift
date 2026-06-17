//
//  DictationShortcut.swift
//  WhisprSoft
//
//  The user-configurable hold-to-talk chord. Models one shortcut: a single main
//  key plus at least one modifier (hold to record, release to finish). The
//  selection persists as a single stable string in UserDefaults and is read
//  fresh via `active()` — the read-fresh pattern TargetLanguage and CloudProvider
//  use — EXCEPT the event tap caches it (see HotkeyMonitor): the per-event hot
//  path must not read/parse UserDefaults, so the monitor reloads it explicitly
//  via Coordinator.updateHotkey() when the binding changes.
//
//  Not user-extensible and not a protocol-typed stage: there's one concrete
//  value (one shortcut), so no abstraction is warranted (project convention).
//

import AppKit
import Carbon.HIToolbox

/// A hold-to-talk chord: a main key (`keyCode`, a CG/virtual keycode) plus the
/// required modifier flags (`modifiers`, masked to the four modifier bits only —
/// device bits like `maskSecondaryFn` are never stored).
nonisolated struct DictationShortcut: Equatable, Sendable {
    let keyCode: Int64
    let modifiers: UInt64

    /// Only the four modifier bits we model: Control, Option, Command, Shift.
    /// Device bits (`maskSecondaryFn`, `maskNonCoalesced`, …) are masked out.
    static let modifierMask: UInt64 =
        CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskShift.rawValue

    /// ⌃⌥Space — the original hardcoded chord, now the first-run default so
    /// existing behavior is unchanged.
    static let `default` = DictationShortcut(
        keyCode: 49,
        modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue)

    /// Persisted selection key. Shared by the UI's `@AppStorage` and `active()`.
    static let storageKey = "dictationShortcut"

    /// Stores only the masked modifier bits, so a value built from a raw event
    /// flag set never carries device bits.
    init(keyCode: Int64, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    /// The required modifier flags for the event tap's subset test.
    var cgFlags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    // MARK: - Serialization

    /// `"keyCode:modifierRaw"`, e.g. `"49:786432"` for ⌃⌥Space. One string so the
    /// UI can bind it with a single `@AppStorage` key.
    var storageString: String { "\(keyCode):\(modifiers)" }

    /// Parse `storageString`. Returns nil on malformed input OR on a zero-modifier
    /// chord (cheap insurance: `cgFlags` would be empty and `flags.contains(empty)`
    /// is always true, which would fire dictation on a bare key — unreachable
    /// through the recorder UI, which requires a modifier, but guards direct writes).
    init?(storageString: String) {
        let parts = storageString.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let kc = Int64(parts[0]),
              let mods = UInt64(parts[1])
        else { return nil }
        let masked = mods & Self.modifierMask
        guard masked != 0 else { return nil }
        self.init(keyCode: kc, modifiers: masked)
    }

    /// Reads `storageKey` fresh from UserDefaults, falling back to `.default` on
    /// absent / empty / malformed. Mirrors `TargetLanguage.active()`.
    static func active() -> DictationShortcut {
        guard let s = UserDefaults.standard.string(forKey: storageKey), !s.isEmpty,
              let shortcut = DictationShortcut(storageString: s)
        else { return .default }
        return shortcut
    }

    // MARK: - Capture (recorder UI)

    /// Build a shortcut from a key event. Returns nil unless it's a `.keyDown`
    /// (so a non-modifier key) with at least one of Control/Option/Command/Shift
    /// held. `NSEvent.keyCode` is the same virtual keycode space as the CG tap.
    init?(nsEvent event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        var mods: UInt64 = 0
        let f = event.modifierFlags
        if f.contains(.control) { mods |= CGEventFlags.maskControl.rawValue }
        if f.contains(.option)  { mods |= CGEventFlags.maskAlternate.rawValue }
        if f.contains(.command) { mods |= CGEventFlags.maskCommand.rawValue }
        if f.contains(.shift)   { mods |= CGEventFlags.maskShift.rawValue }
        guard mods != 0 else { return nil }
        self.init(keyCode: Int64(event.keyCode), modifiers: mods)
    }

    // MARK: - Display

    /// Ordered keycap labels: modifier symbols in canonical order ⌃ ⌥ ⇧ ⌘, then
    /// the main-key name last — e.g. `["⌃", "⌥", "Space"]`.
    var symbols: [String] {
        var result: [String] = []
        if cgFlags.contains(.maskControl)   { result.append("⌃") }
        if cgFlags.contains(.maskAlternate) { result.append("⌥") }
        if cgFlags.contains(.maskShift)     { result.append("⇧") }
        if cgFlags.contains(.maskCommand)   { result.append("⌘") }
        result.append(Self.keyName(for: keyCode))
        return result
    }

    /// A display name for a virtual keycode. Compact lookup for the common
    /// non-printing keys; printable keys are derived from their character via the
    /// current keyboard layout; `"Key N"` for anything unmapped.
    static func keyName(for keyCode: Int64) -> String {
        if let special = specialKeyNames[keyCode] { return special }
        if let char = printableCharacter(for: keyCode) { return char.uppercased() }
        return "Key \(keyCode)"
    }

    private static let specialKeyNames: [Int64: String] = [
        Int64(kVK_Space): "Space",
        Int64(kVK_Return): "Return",
        Int64(kVK_Tab): "Tab",
        Int64(kVK_Escape): "Escape",
        Int64(kVK_Delete): "Delete",
        Int64(kVK_LeftArrow): "←",
        Int64(kVK_RightArrow): "→",
        Int64(kVK_DownArrow): "↓",
        Int64(kVK_UpArrow): "↑",
        Int64(kVK_F1): "F1", Int64(kVK_F2): "F2", Int64(kVK_F3): "F3",
        Int64(kVK_F4): "F4", Int64(kVK_F5): "F5", Int64(kVK_F6): "F6",
        Int64(kVK_F7): "F7", Int64(kVK_F8): "F8", Int64(kVK_F9): "F9",
        Int64(kVK_F10): "F10", Int64(kVK_F11): "F11", Int64(kVK_F12): "F12",
    ]

    /// The character a keycode produces under the current keyboard layout (no
    /// modifiers, dead keys ignored), or nil if it has no printable form.
    private static func printableCharacter(for keyCode: Int64) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = unsafeBitCast(layoutPtr, to: CFData.self)
        let keyLayout = unsafeBitCast(CFDataGetBytePtr(layoutData),
                                      to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            keyLayout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars)
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }
}
