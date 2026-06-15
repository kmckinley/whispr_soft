//
//  TextInjector.swift
//  WhisprSoft
//
//  Injection stage contract + stub + real PasteboardInjector.
//

import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import os

/// Delivers the final text into the frontmost app.
protocol TextInjector {
    func inject(_ text: String) throws
}

/// Prints the final text to the console. Does NOT touch the pasteboard
/// or Accessibility — retained for previews/tests.
nonisolated struct StubInjector: TextInjector {
    func inject(_ text: String) throws {
        print("INJECT >> \(text)")
    }
}

/// Pastes the text into the frontmost app: saves the pasteboard, sets our
/// text, synthesizes Cmd-V, then restores the pasteboard. `nonisolated` to
/// match the protocol witness, so the MainActor Coordinator calls it exactly
/// like the stub. Requires the Accessibility grant (posting synthetic key
/// events) — already hard-gated by the time the pipeline runs.
nonisolated struct PasteboardInjector: TextInjector {
    func inject(_ text: String) throws {
        guard !text.isEmpty else { return }   // nothing to paste
        guard AXIsProcessTrusted() else {
            throw InjectionError.accessibilityNotTrusted
        }

        let pasteboard = NSPasteboard.general

        // Deep-copy the current items BEFORE clearing (pasteboardItems
        // is live and is invalidated by clearContents). Note: this copies
        // only materialized data, so promised/lazy types (e.g. a file copied
        // in Finder, which is offered as a promise) are dropped on restore.
        let saved: [NSPasteboardItem]? = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        try postCommandV()

        // Restore the user's clipboard after the paste has had time to
        // land. This delay is a heuristic — restoring immediately can
        // race the target app's paste and put the old content back
        // first. ~120ms is comfortably enough in practice.
        if let saved {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                pasteboard.clearContents()
                pasteboard.writeObjects(saved)
            }
        }

        Log.injection.notice("PasteboardInjector: pasted \(text.count, privacy: .public) chars")
    }

    private func postCommandV() throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9   // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            throw InjectionError.eventCreationFailed
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

enum InjectionError: LocalizedError {
    case accessibilityNotTrusted
    case eventCreationFailed
    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "Accessibility permission is required to paste text."
        case .eventCreationFailed:
            return "Could not create the paste keystroke."
        }
    }
}
