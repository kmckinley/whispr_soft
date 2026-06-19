//
//  HUDController.swift
//  WhisprSoft
//
//  Owns the floating on-screen dictation HUD panel, hosts HUDView, observes the
//  Coordinator's pipeline state, and shows/hides + positions the panel. The
//  Coordinator stays free of any HUD knowledge — this is a pure observer of its
//  published `state`, mirroring how the hotkey is armed from AppDelegate.
//

import AppKit
import SwiftUI

@MainActor
final class HUDController {
    private let coordinator: Coordinator
    private var panel: NSPanel?
    private var hostingView: NSHostingView<HUDView>?

    /// Bumped by every show()/hide(). A pending hide's fade-out completion checks
    /// its captured value against the current one and no-ops if superseded — so a
    /// re-press within the 0.15s fade window can't order the panel out from under
    /// the new dictation.
    private var transitionGeneration = 0

    /// UserDefaults key for the "Show on-screen indicator" toggle. Absent =
    /// treated as on (the toggle defaults on); explicitly false = never show.
    private static let showHUDKey = "showHUD"

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
    }

    /// Build the panel and begin observing pipeline state. Call once at launch.
    func start() {
        makePanel()
        observeState()
        update()
    }

    // MARK: - Panel construction

    private func makePanel() {
        let hosting = NSHostingView(rootView: HUDView(coordinator: coordinator))
        hosting.setFrameSize(hosting.fittingSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false            // the SwiftUI pill draws its own shadow
        panel.isMovable = false
        panel.ignoresMouseEvents = true    // informational only — pass clicks through
        panel.hidesOnDeactivate = false
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting
    }

    // MARK: - State observation

    /// Track `coordinator.state` via Observation. The tracker fires once per
    /// registration, so we re-arm after each change. The onChange closure can run
    /// off the main actor, so hop back before touching AppKit.
    private func observeState() {
        withObservationTracking {
            _ = coordinator.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.update()
                self.observeState()   // re-arm
            }
        }
    }

    /// Show (reposition + order front) for any non-idle state, hide on idle —
    /// gated on the "Show on-screen indicator" setting.
    private func update() {
        let showSetting = UserDefaults.standard.object(forKey: Self.showHUDKey) as? Bool ?? true

        let shouldShow: Bool
        switch coordinator.state {
        case .idle:
            shouldShow = false
        case .recording, .transcribing, .rewriting, .injecting, .error:
            shouldShow = showSetting
        }

        if shouldShow { show() } else { hide() }
    }

    // MARK: - Show / hide / position

    private func show() {
        guard let panel, let hostingView else { return }
        transitionGeneration += 1   // supersede any in-flight hide

        // Content (e.g. the tone name) varies in width, so re-measure each show.
        // Flush any pending SwiftUI layout first so fittingSize reflects the new
        // state's content, not the previous frame's.
        hostingView.layoutSubtreeIfNeeded()
        hostingView.setFrameSize(hostingView.fittingSize)
        panel.setContentSize(hostingView.fittingSize)
        reposition()

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()   // shows without activating — never key/main
        }
        // Always drive alpha back to 1, even if a fade-out was mid-flight — a
        // re-press within the fade window must restore full opacity.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        transitionGeneration += 1
        let generation = transitionGeneration
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            // The completion runs on the main thread; bridge into the actor to read
            // the generation token. A show() that landed during the fade bumped it,
            // so skip the orderOut and don't yank a panel the new dictation re-raised.
            MainActor.assumeIsolated {
                guard let self, self.transitionGeneration == generation else { return }
                panel?.orderOut(nil)
            }
        }
    }

    /// Center horizontally on the active screen, top edge ~12pt below the visible
    /// frame's top (which already excludes the menu bar / notch). Recomputed each
    /// show, since the active screen can change between dictations.
    private func reposition() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - 12 - size.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
