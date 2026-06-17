//
//  WhisprSoftApp.swift
//  WhisprSoft
//
//  Menu-bar agent entry point. No dock icon, no window — LSUIElement is
//  set in the target's build settings.
//

import SwiftUI

@main
struct WhisprSoftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("WhisprSoft", systemImage: "waveform") {
            MenuBarContent(coordinator: appDelegate.coordinator,
                           permissions: appDelegate.permissions,
                           corrections: appDelegate.corrections,
                           profiles: appDelegate.profiles,
                           scratchpad: appDelegate.scratchpad,
                           log: appDelegate.log)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the Coordinator and PermissionsManager so the hotkey can be armed at
/// launch — before the menu is ever opened — letting dictation work on
/// relaunch without user interaction. Both stay `@Observable`, so the views
/// still track them through the delegate.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let scratchpad: ScratchpadStore
    let log: DictationLogStore
    let coordinator: Coordinator
    let permissions = PermissionsManager()
    let corrections = CorrectionsStore()
    let profiles = RewriteProfilesStore()

    override init() {
        // Share the scratchpad and log stores between the Coordinator (writer)
        // and the view (reader/editor). Use locals to avoid referencing self
        // during init.
        let pad = ScratchpadStore()
        let dictationLog = DictationLogStore()
        self.scratchpad = pad
        self.log = dictationLog
        self.coordinator = Coordinator(scratchpad: pad, log: dictationLog)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        permissions.refresh()
        if permissions.allGranted { coordinator.startHotkey() }
        // Warm the transcription model now so it's ready by the first dictation;
        // the load needs no permissions, so preload unconditionally — it warms
        // even while the user is still working through onboarding.
        coordinator.preloadModel()
    }
}
