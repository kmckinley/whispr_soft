//
//  MenuBarContent.swift
//  WhisprSoft
//
//  The menu-bar popover. Observes the Coordinator and PermissionsManager.
//
//  A 360pt dark, violet-accented, tabbed popover (Dictate / Tone / Corrections)
//  with a gear-accessed Settings screen, built from the "Kemsoft Voice Popover"
//  design. All pipeline wiring is reused unchanged — this is a UI shell over the
//  Coordinator, the two stores, the Keychain, and `@AppStorage("localMode")`.
//  The hero is a STATUS DISPLAY driven by `coordinator.state`, not a button. The
//  active tone profile is chosen only on the Dictate tab; the Tone tab is purely
//  CRUD/reorder management. The MenuBarExtra icon stays `waveform` (set in
//  WhisprSoftApp).
//

import SwiftUI
import AppKit
import Carbon.HIToolbox  // kVK_Escape for the shortcut recorder
import os                // Log.hotkey diagnostics in the chord recorder

struct MenuBarContent: View {
    let coordinator: Coordinator
    let permissions: PermissionsManager
    @Bindable var corrections: CorrectionsStore
    @Bindable var profiles: RewriteProfilesStore
    @Bindable var toneChords: ToneChordStore
    @Bindable var scratchpad: ScratchpadStore
    let log: DictationLogStore

    enum Tab: String, CaseIterable { case dictate = "Dictate", tone = "Tone", corrections = "Corrections" }

    /// Active body tab. Settings replaces the body entirely when shown.
    @State private var tab: Tab = .dictate
    @State private var showingSettings = false
    /// Inline tone picker disclosure on the Dictate tab.
    @State private var showingTonePicker = false
    /// Inline target-language picker disclosure on the Dictate tab.
    @State private var showingLanguagePicker = false
    /// Inline cloud-engine (provider) picker disclosure on the Dictate tab.
    @State private var showingEnginePicker = false

    /// The tone profile expanded for editing on the Tone tab; one at a time.
    @State private var expandedProfileID: UUID?

    /// Settings: reveal the API-key field; whether a key is stored.
    @State private var addingKey = false
    @State private var apiKeyDraft = ""
    @State private var hasStoredKey = false

    /// Settings: the ChatGPT (OpenAI) key row — reveal the field; whether a key
    /// is stored. Mirrors the Claude key state above.
    @State private var addingOpenAIKey = false
    @State private var openAIKeyDraft = ""
    @State private var hasOpenAIKey = false

    /// The selected cloud provider id. Read fresh per rewrite by
    /// `CloudProvider.active()`, so switching takes effect on the next dictation.
    @AppStorage(CloudProvider.storageKey) private var selectedProvider = CloudProvider.claude.id

    /// The configured dictation chord, as its single serialized string. Bound so
    /// the keycaps (Settings + the Dictate hero) update reactively on a change;
    /// the live tap is updated separately via `coordinator.updateHotkey()`.
    @AppStorage(DictationShortcut.storageKey) private var shortcutStorage = DictationShortcut.default.storageString

    /// Settings: capturing the next chord. While true, a local event monitor
    /// intercepts key events; `shortcutMonitor` holds its token, `shortcutHint`
    /// shows a transient validation message.
    @State private var recordingShortcut = false
    @State private var shortcutMonitor: Any?
    @State private var shortcutHint: String?

    /// Settings: capturing a tone-chord key. `recordingChordIndex` is the slot
    /// being recorded (nil = none), `chordMonitor` holds the local event monitor,
    /// `chordHint` shows a transient validation/collision message. Mirrors the
    /// default-shortcut recorder, but accepts ONLY ⌃⌥ + a single key.
    @State private var recordingChordIndex: Int?
    @State private var chordMonitor: Any?
    @State private var chordHint: String?
    /// Fires a soft "didn't reach the app" note if no chord is captured within a
    /// few seconds of starting — a best-effort signal that the combo may be grabbed
    /// by macOS or another app before it reaches our local monitor. Cancelled on
    /// capture/stop so it never fires for a completed or abandoned recording.
    @State private var chordTimeoutWork: DispatchWorkItem?

    /// The active chord, decoded from `shortcutStorage` (default on malformed).
    /// Shared by `shortcutSettingRow` and the Dictate hero so they can't drift.
    private var currentShortcut: DictationShortcut {
        DictationShortcut(storageString: shortcutStorage) ?? .default
    }

    /// The chord's keycaps, shared by the Dictate hero and the Settings row so a
    /// layout change can't drift between them (the reason `currentShortcut` is
    /// shared in the first place).
    @ViewBuilder
    private func keycaps(for shortcut: DictationShortcut) -> some View {
        ForEach(Array(shortcut.symbols.enumerated()), id: \.offset) { _, symbol in
            Keycap(symbol)
        }
    }

    /// Measured height of the current scrollable body, capped at 444 (the design
    /// cap); a `.window` MenuBarExtra sizes to content, so the scroll area needs
    /// a determinate height. Starts non-zero so the first frame doesn't collapse.
    @State private var bodyHeight: CGFloat = 380

    /// Route cleanup to the local LM Studio instead of cloud Claude. Read fresh
    /// per rewrite by RewriteLadder, so toggling takes effect immediately.
    @AppStorage("localMode") private var localMode = false

    /// Reveal the per-dictation diagnostic log at the bottom of Settings. Logs
    /// are always collected and persisted; this only controls visibility.
    @AppStorage("showLogs") private var showLogs = false

    /// Show the floating on-screen dictation indicator (HUD). Defaults on;
    /// HUDController reads the same key to gate showing the panel.
    @AppStorage("showHUD") private var showHUD = true

    /// Cross-provider cloud fallback: if the active cloud provider fails, try the
    /// other one before raw. Read fresh per rewrite by RewriteLadder. Cloud Mode
    /// only; gated in the UI on both cloud keys being present.
    @AppStorage("cloudProviderFallback") private var cloudProviderFallback = false

    /// The target output language id. Read fresh per rewrite by
    /// `TargetLanguage.active()`, so a change takes effect on the next dictation.
    /// Default (English US) means no translation.
    @AppStorage(TargetLanguage.storageKey) private var selectedLanguageID = TargetLanguage.default.id

    var body: some View {
        // Hard gate: until all permissions are granted the popover shows only
        // the styled permissions gate — no tabs/gear/Local-AI, no way through.
        // The panel chrome is hoisted here so the gate and the granted body
        // share it.
        Group {
            if permissions.allGranted {
                grantedBody
            } else {
                permissionsGate
            }
        }
        .frame(width: 360)
        .background(popoverBackground)
        .preferredColorScheme(.dark)
        // Track popover visibility (drives the note-routing decision) and
        // re-evaluate the gate on every appearance (granted OR revoked). For a
        // `.window` MenuBarExtra these fire when the popover is shown/dismissed.
        .onAppear { scratchpad.isPopoverOpen = true; permissions.refresh() }
        .onDisappear { scratchpad.isPopoverOpen = false }
        // Arm/disarm the hotkey off the gate; `initial: true` covers opening
        // while already granted (AppDelegate handles launch-time arming).
        .onChange(of: permissions.allGranted, initial: true) { _, granted in
            if granted { coordinator.startHotkey() } else { coordinator.stopHotkey() }
        }
    }

    // MARK: - Granted container (always-mounted while granted)

    /// The always-mounted shell: header + (tabbed body | Settings). Persistence
    /// hooks live here so saves fire regardless of which screen is showing.
    private var grantedBody: some View {
        VStack(spacing: 0) {
            header

            if showingSettings {
                settingsScroll
            } else {
                segmentedControl
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                tabScroll
            }
        }
        .onAppear { refreshKeyStatus() }
        .onChange(of: corrections.items) { _, _ in corrections.save() }
        .onChange(of: profiles.items) { old, new in
            profiles.save()
            // Refresh the monitor's cached tone chords only when the set of
            // profiles changes (a deletion can orphan a chord — its key must type
            // normally again). A rename/instruction edit doesn't affect chord
            // resolution (it's by id, and the HUD name is read fresh at press), so
            // skip the reload on those to keep edits off the tap's cache path.
            if Set(old.map(\.id)) != Set(new.map(\.id)) {
                coordinator.updateHotkey()
            }
        }
        .onChange(of: profiles.selectedID) { _, _ in profiles.saveSelection() }
        // When a capture starts routing to the note, surface it: leave Settings
        // and snap to the Dictate tab so the box is visible. Keyed on
        // isCapturing (not isExpanded): isCapturing reliably goes false→true on
        // every capture, whereas isExpanded stays true once the note has text,
        // so a second burst started on another tab would otherwise snap nothing.
        .onChange(of: scratchpad.isCapturing) { _, capturing in
            if capturing { showingSettings = false; tab = .dictate }
        }
    }

    /// Translucent dark panel with a faint violet (top-right) + magenta (bottom)
    /// radial wash — an approximation of the design's vibrancy.
    private var popoverBackground: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            Color(hex: 0x1A1821).opacity(0.86)
            RadialGradient(colors: [Theme.accent.opacity(0.16), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 300)
            RadialGradient(colors: [Color(hex: 0xFF6FD8).opacity(0.08), .clear],
                           center: .bottomLeading, startRadius: 0, endRadius: 240)
        }
        .ignoresSafeArea()
    }

    // MARK: - Permissions gate (hard gate; shown until allGranted)

    /// The styled permission gate shown while `!permissions.allGranted`. Shares
    /// the panel chrome (hoisted to `body`) and the private `Theme` tokens.
    /// There is no escape — no segmented control, gear, or tabs — until all
    /// three are granted; the `body` Group re-gates bidirectionally on appear.
    private var permissionsGate: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header (no gear — no way past the gate).
            HStack(spacing: 10) {
                appIcon(size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WhisprSoft")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                    Text("Finish setup to start")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
            }

            // Make the gate explicit.
            Text("WhisprSoft needs these two permissions to run.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.accent.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.accentSoft)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accentBorder.opacity(0.5), lineWidth: 0.5))
                )

            VStack(spacing: 8) {
                permissionGateRow(
                    title: "Microphone",
                    why: "Records your voice to transcribe it.",
                    status: permissions.microphone
                ) {
                    switch permissions.microphone {
                    case .notDetermined:
                        gateButton("Grant", primary: true) {
                            Task { await permissions.requestMicrophone() }
                        }
                    case .denied:
                        gateButton("Open Settings", primary: false) {
                            permissions.openMicrophoneSettings()
                        }
                    case .granted:
                        EmptyView()
                    }
                }

                permissionGateRow(
                    title: "Accessibility",
                    why: "Pastes transcribed text and detects the dictation hotkey.",
                    status: permissions.accessibility
                ) {
                    if permissions.accessibility != .granted {
                        gateButton("Grant", primary: true) { permissions.requestAccessibility() }
                    }
                }
            }

            HStack {
                Button { permissions.refresh() } label: {
                    Text("Re-check")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                Spacer()
                Button { NSApplication.shared.terminate(nil) } label: {
                    Text("Quit")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.red)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .onAppear { permissions.refresh() }
    }

    /// One gate row: leading status indicator + title/why on the left, the
    /// permission-specific action right-aligned, in card chrome.
    private func permissionGateRow<Action: View>(
        title: String,
        why: String,
        status: PermissionStatus,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 16))
                .foregroundStyle(status == .granted ? Theme.green : Theme.amber)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(why)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .cardSurface()
    }

    /// A small gate action button: primary = accent-soft fill, secondary =
    /// faint white fill.
    private func gateButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(primary ? Theme.accent : .white.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(primary ? Theme.accentSoft : Color.white.opacity(0.07))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            if showingSettings {
                Button { withAnimation(.easeInOut(duration: 0.22)) { showingSettings = false } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("Settings")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
            } else {
                appIcon(size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WhisprSoft")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                    HStack(spacing: 5) {
                        StatusDot(color: statusColor)
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                Spacer()
                HoverIconButton(system: "gearshape") {
                    withAnimation(.easeInOut(duration: 0.22)) { showingSettings = true }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var statusColor: Color {
        switch coordinator.state {
        case .idle: return Theme.green
        case .recording, .transcribing, .rewriting, .injecting: return Theme.accent
        case .error: return Theme.red
        }
    }

    private var statusText: String {
        switch coordinator.state {
        case .idle: return coordinator.isModelLoading ? "Preparing…" : "Idle"
        case .recording: return "Listening"
        case .transcribing, .rewriting, .injecting: return "Cleaning up"
        case .error: return "Error"
        }
    }

    private var isRecording: Bool {
        if case .recording = coordinator.state { return true }
        return false
    }

    // MARK: - Segmented control

    private var segmentedControl: some View {
        HStack(spacing: 3) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button { withAnimation(.easeInOut(duration: 0.15)) { tab = t } } label: {
                    Text(t.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tab == t ? .white : Color.white.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(tab == t ? Color.white.opacity(0.13) : .clear)
                                .shadow(color: tab == t ? Theme.accentGlow.opacity(0.5) : .clear, radius: 4)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        )
    }

    // MARK: - Scroll containers (content-sized up to the 444 cap)

    private var tabScroll: some View {
        measuredScroll {
            VStack(spacing: 14) {
                switch tab {
                case .dictate:     dictateTab
                case .corrections: correctionsTab
                case .tone:        toneTab
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    private var settingsScroll: some View {
        measuredScroll { settingsContent.padding(14) }
            .onAppear { refreshKeyStatus() }
    }

    @ViewBuilder
    private func measuredScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .background(GeometryReader { g in
                    Color.clear.preference(key: HeightKey.self, value: g.size.height)
                })
        }
        .frame(height: min(bodyHeight, 444))
        .scrollIndicators(.never)
        .onPreferenceChange(HeightKey.self) { bodyHeight = $0 }
    }

    // MARK: - Dictate tab

    private var dictateTab: some View {
        VStack(spacing: 12) {
            heroCard
            if scratchpad.isExpanded { noteCard }
            dictateGroupedCard
        }
        .animation(.easeInOut(duration: 0.22), value: scratchpad.isExpanded)
    }

    /// The in-popover quick-note box, shown at the bottom of the Dictate tab
    /// when a capture routes here (or while it holds text). Editable by hand.
    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Note")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                if scratchpad.isCapturing {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                        .shadow(color: Theme.accentGlow, radius: 3)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(scratchpad.text, forType: .string)
                } label: {
                    Text("Copy")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(scratchpad.text.isEmpty ? .white.opacity(0.25) : Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(scratchpad.text.isEmpty)

                Button {
                    scratchpad.clear()
                } label: {
                    Text("Clear")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.red)
                }
                .buttonStyle(.plain)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $scratchpad.text)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(minHeight: 70, maxHeight: 150)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.05))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                    )

                if scratchpad.text.isEmpty {
                    Text("Dictate or type a quick note…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(12)
        .cardSurface()
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var heroCard: some View {
        VStack(spacing: 14) {
            ZStack {
                if isRecording { PulseRing() }
                micCircle
            }
            .frame(width: 96, height: 96)

            VStack(spacing: 6) {
                Text(heroTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                heroSubview
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .cardSurface()
    }

    private var micCircle: some View {
        Circle()
            .fill(RadialGradient(colors: [Theme.micTint, Theme.accent, Theme.micDark],
                                 center: .center, startRadius: 2, endRadius: 40))
            .frame(width: 76, height: 76)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
            .overlay(heroGlyph)
            .shadow(color: Theme.accentGlow, radius: 16)
    }

    @ViewBuilder
    private var heroGlyph: some View {
        switch coordinator.state {
        case .idle:
            if coordinator.isModelLoading { Spinner() } else { appIcon(size: 34) }
        case .recording:
            WaveformBars()
        case .transcribing, .rewriting, .injecting:
            Spinner()
        case .error:
            appIcon(size: 34)
        }
    }

    private var heroTitle: String {
        switch coordinator.state {
        case .idle: return coordinator.isModelLoading ? "Preparing model…" : "Ready to dictate"
        case .recording: return "Listening…"
        case .transcribing, .rewriting, .injecting: return "Cleaning up…"
        case .error: return "Error"
        }
    }

    @ViewBuilder
    private var heroSubview: some View {
        switch coordinator.state {
        case .idle:
            if coordinator.isModelLoading {
                EmptyView()
            } else {
                HStack(spacing: 5) {
                    Text("Hold").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    keycaps(for: currentShortcut)
                }
            }
        case .recording:
            // For a tone-chord dictation, name the one-shot tone in the indicator
            // (the only on-screen indicator; invisible when the popover is closed,
            // the common dictate-into-another-app case — a pre-existing limit).
            if let tone = coordinator.activeToneName {
                heroSub("\(tone) · Release to finish")
            } else {
                heroSub("Release to finish")
            }
        case .transcribing, .rewriting, .injecting:
            heroSub("Polishing with \(engineName)")
        case .error(let message):
            heroSub(message)
        }
    }

    private func heroSub(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.45))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The cloud/local engine display name (matches the Engine row + Settings).
    /// Reuses `activeProviderName` (which reads the `@AppStorage` selection) so
    /// the hero subtitle re-renders when the provider changes.
    private var engineName: String {
        localMode ? "LM Studio" : activeProviderName
    }

    private var dictateGroupedCard: some View {
        VStack(spacing: 0) {
            // Target-language row → inline picker. Default (English US) = no translation.
            Button { withAnimation(.easeInOut(duration: 0.18)) { showingLanguagePicker.toggle() } } label: {
                groupedRow(title: "Language", value: activeLanguageName, chevronUp: showingLanguagePicker)
            }
            .buttonStyle(.plain)

            if showingLanguagePicker {
                hairline
                ForEach(TargetLanguage.all) { language in
                    languageOptionRow(name: language.displayName, id: language.id)
                }
            }

            hairline

            // Tone profile row → inline picker (the ONLY place the active tone is set).
            Button { withAnimation(.easeInOut(duration: 0.18)) { showingTonePicker.toggle() } } label: {
                groupedRow(title: "Tone profile", value: activeToneName, chevronUp: showingTonePicker)
            }
            .buttonStyle(.plain)

            if showingTonePicker {
                hairline
                toneOptionRow(name: "Default (clean up only)", id: nil)
                ForEach(profiles.items) { profile in
                    toneOptionRow(name: profile.name.isEmpty ? "Untitled" : profile.name, id: profile.id)
                }
            }

            hairline

            // Engine row. In Local Mode it's a settings-nav row (unchanged). In
            // Cloud Mode it's an inline picker between the cloud providers.
            if localMode {
                Button { withAnimation(.easeInOut(duration: 0.22)) { showingSettings = true } } label: {
                    HStack(spacing: 8) {
                        Text("Engine")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer()
                        Circle().fill(Theme.green).frame(width: 6, height: 6)
                        Text("Local · LM Studio")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Button { withAnimation(.easeInOut(duration: 0.18)) { showingEnginePicker.toggle() } } label: {
                    groupedRow(title: "Engine", value: activeProviderName, chevronUp: showingEnginePicker)
                }
                .buttonStyle(.plain)

                if showingEnginePicker {
                    hairline
                    engineOptionRow(.claude)
                    engineOptionRow(.openai)
                }
            }
        }
        .groupedCardSurface()
    }

    /// The active cloud provider's display name (Cloud Mode Engine row value).
    private var activeProviderName: String {
        CloudProvider(rawValue: selectedProvider)?.displayName ?? "Claude"
    }

    /// One cloud-provider option in the inline Engine picker. A provider with a
    /// stored key switches inline; one without jumps to Settings (showing an
    /// "Add key" hint) so the user can add it.
    private func engineOptionRow(_ provider: CloudProvider) -> some View {
        let connected = provider == .claude ? hasStoredKey : hasOpenAIKey
        return Button {
            if connected {
                selectedProvider = provider.id
                withAnimation(.easeInOut(duration: 0.18)) { showingEnginePicker = false }
            } else {
                withAnimation(.easeInOut(duration: 0.22)) {
                    showingEnginePicker = false
                    showingSettings = true
                }
            }
        } label: {
            HStack {
                Text(provider.displayName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer()
                if !connected {
                    Text("Add key")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                } else if selectedProvider == provider.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.violetCheck)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func groupedRow(title: String, value: String, chevronUp: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(value)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Image(systemName: chevronUp ? "chevron.up" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private func toneOptionRow(name: String, id: UUID?) -> some View {
        Button {
            profiles.selectedID = id
            withAnimation(.easeInOut(duration: 0.18)) { showingTonePicker = false }
        } label: {
            HStack {
                Text(name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer()
                if profiles.selectedID == id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.violetCheck)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var activeToneName: String {
        if let id = profiles.selectedID,
           let profile = profiles.items.first(where: { $0.id == id }) {
            return profile.name.isEmpty ? "Untitled" : profile.name
        }
        return "Default (clean up only)"
    }

    /// Language picker option row — parallels `toneOptionRow` but keys on the
    /// language's String id (vs. the tone picker's UUID?), so it's a small
    /// separate helper rather than forcing the types to match.
    private func languageOptionRow(name: String, id: String) -> some View {
        Button {
            selectedLanguageID = id
            withAnimation(.easeInOut(duration: 0.18)) { showingLanguagePicker = false }
        } label: {
            HStack {
                Text(name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer()
                if selectedLanguageID == id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.violetCheck)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var activeLanguageName: String {
        TargetLanguage.all.first(where: { $0.id == selectedLanguageID })?.displayName
            ?? TargetLanguage.default.displayName
    }

    // MARK: - Tone tab (management only — no active selection here)

    private var toneTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Create and edit your tone profiles. Use the arrows to reorder — pick the active one on the Dictate tab.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach($profiles.items) { profileCard($0) }
            }

            DashedAddButton(title: "Add profile") {
                profiles.add()
                expandedProfileID = profiles.items.last?.id
            }
        }
    }

    @ViewBuilder
    private func profileCard(_ profile: Binding<RewriteProfile>) -> some View {
        let id = profile.wrappedValue.id
        let expanded = expandedProfileID == id

        VStack(alignment: .leading, spacing: 0) {
            if expanded {
                expandedProfileContent(profile)
            } else {
                // Collapsed: tapping the row expands it; the leading up/down
                // arrows reorder one step per click and consume their own taps.
                collapsedProfileHeader(profile)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(expanded ? Theme.accentSoft : Color.white.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(expanded ? Theme.accentBorder : Color.white.opacity(0.06),
                                      lineWidth: expanded ? 1 : 0.5)
                )
        )
        .shadow(color: expanded ? Theme.accentGlow.opacity(0.5) : .clear, radius: expanded ? 10 : 0)
    }

    /// A compact vertical pair of reorder arrows (up over down) in the leading
    /// slot of a collapsed profile card. Each arrow is disabled + dimmed at the
    /// list boundary, and consumes its own tap so the row's expand gesture only
    /// fires when tapping elsewhere.
    @ViewBuilder
    private func reorderArrows(for id: UUID) -> some View {
        let i = profiles.items.firstIndex(where: { $0.id == id })
        let isFirst = i == 0
        let isLast = i == profiles.items.count - 1
        VStack(spacing: 3) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { profiles.moveUp(id) }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(isFirst ? 0.18 : 0.55))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isFirst)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { profiles.moveDown(id) }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(isLast ? 0.18 : 0.55))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLast)
        }
    }

    private func collapsedProfileHeader(_ profile: Binding<RewriteProfile>) -> some View {
        let p = profile.wrappedValue
        return HStack(spacing: 10) {
            reorderArrows(for: p.id)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.name.isEmpty ? "Untitled" : p.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    if profiles.selectedID == p.id { activeBadge }
                }
                Text(p.instruction.isEmpty ? "No description" : p.instruction)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) { expandedProfileID = p.id }
        }
    }

    private func expandedProfileContent(_ profile: Binding<RewriteProfile>) -> some View {
        let p = profile.wrappedValue
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(p.name.isEmpty ? "Untitled" : p.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                if profiles.selectedID == p.id { activeBadge }
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { expandedProfileID = nil } }

            fieldLabel("Title")
            TextField("Name", text: profile.name)
                .insetField()

            fieldLabel("Description")
            TextField("Tone instruction", text: profile.instruction, axis: .vertical)
                .lineLimit(2...4)
                .insetField()

            HStack {
                Button { profiles.remove(p) } label: {
                    Text("Delete")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.red)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.18)) { expandedProfileID = nil } } label: {
                    Text("Done")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.knobDark)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }

    private var activeBadge: some View {
        Text("ACTIVE")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(Theme.violetCheck)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.accentSoft))
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.4))
    }

    // MARK: - Corrections tab

    private var correctionsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Replaces misheard words after cleanup, automatically. Replacement terms also help recognition during transcription.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)

            Text("\(corrections.items.count) corrections".uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.4))

            VStack(spacing: 6) {
                ForEach($corrections.items) { $correction in
                    correctionRow($correction)
                }
            }

            DashedAddButton(title: "Add correction") { corrections.add() }
        }
    }

    private func correctionRow(_ correction: Binding<Correction>) -> some View {
        HStack(spacing: 8) {
            // `from` is forced lowercase as typed — matching is case-insensitive
            // anyway, so this just keeps the stored key tidy.
            TextField("heard", text: Binding(
                get: { correction.wrappedValue.from },
                set: { correction.from.wrappedValue = $0.lowercased() }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.55))

            Image(systemName: "arrow.right")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))

            TextField("replace", text: correction.to)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.92))

            Button { corrections.remove(correction.wrappedValue) } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        )
    }

    // MARK: - Settings

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                localModeSettingRow
                hairline
                apiKeyRow(title: "Claude API key", placeholder: "sk-ant-…",
                          connected: hasStoredKey, adding: $addingKey, draft: $apiKeyDraft,
                          onSave: saveAPIKey,
                          onRemove: { Keychain.deleteAPIKey(); hasStoredKey = false })
                hairline
                apiKeyRow(title: "ChatGPT API key", placeholder: "sk-…",
                          connected: hasOpenAIKey, adding: $addingOpenAIKey, draft: $openAIKeyDraft,
                          onSave: saveOpenAIKey,
                          onRemove: { Keychain.deleteOpenAIKey(); hasOpenAIKey = false })
                hairline
                providerFallbackSettingRow
                hairline
                showHUDSettingRow
                hairline
                shortcutSettingRow
            }
            .groupedCardSurface()

            toneChordsSection

            Button { NSApplication.shared.terminate(nil) } label: {
                Text("Quit WhisprSoft")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Theme.red.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.red.opacity(0.25), lineWidth: 0.5))
                    )
            }
            .buttonStyle(.plain)

            logsSection

            if let version = versionString {
                Text("Version \(version)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var localModeSettingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local mode")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    Text("Process on-device with LM Studio")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                LocalToggle(isOn: $localMode)
            }
            Text("Cleanup runs on your local LM Studio (127.0.0.1:1234). Audio-derived text never leaves your Mac.")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    /// Cross-provider cloud fallback toggle. Enabled only when BOTH cloud keys
    /// are present (a switch to the other provider needs its key); when either is
    /// missing it's disabled, dimmed, and shows a hint. If a key is later removed
    /// the toggle simply disables again — the ladder's defensive key-check makes
    /// any stored `true` inert until both keys return, so no force-write is needed.
    private var providerFallbackSettingRow: some View {
        let bothKeys = hasStoredKey && hasOpenAIKey
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cloud fallback")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(bothKeys ? 0.9 : 0.4))
                    Text(bothKeys
                         ? "If your active cloud model fails, automatically try the other one."
                         : "Add both your Claude and ChatGPT keys to enable.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(bothKeys ? 0.45 : 0.35))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                LocalToggle(isOn: $cloudProviderFallback)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .disabled(!bothKeys)
        .opacity(bothKeys ? 1 : 0.6)
    }

    /// Toggle for the floating on-screen dictation indicator. HUDController reads
    /// the same `@AppStorage("showHUD")` key, so flipping this gates the next
    /// dictation's HUD without a relaunch.
    private var showHUDSettingRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Show on-screen indicator")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text("A floating pill near the top of the screen while dictating.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            LocalToggle(isOn: $showHUD)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    // MARK: - Logs

    /// The "Show logs" toggle and, when on, the per-dictation diagnostic list.
    /// Logs are always collected in memory (see DictationLogStore); the toggle
    /// only controls whether they're rendered here.
    @ViewBuilder
    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show logs")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    Text("Per-dictation diagnostics. Saved on this Mac; clear anytime.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                LocalToggle(isOn: $showLogs)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .groupedCardSurface()

        if showLogs { logsList }
    }

    private var logsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(log.entries.count) dictation\(log.entries.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button("Clear") { log.clear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                    .disabled(log.entries.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if log.entries.isEmpty {
                Text("No dictations logged yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            } else {
                ForEach(log.entries) { entry in
                    hairline
                    logEntryRow(entry)
                }
            }
        }
        .groupedCardSurface()
    }

    private func logEntryRow(_ e: DictationLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // Line 1: time · engine (+ raw-fallback / provider-fallback tag) · destination.
            HStack(spacing: 6) {
                Text(e.date, style: .time)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                Text("·").foregroundStyle(.white.opacity(0.3))
                Text(e.engine)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                if e.usedRawFallback {
                    Text("raw fallback")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.red)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.red.opacity(0.14)))
                } else if e.usedProviderFallback {
                    // The engine field already names the provider that produced the
                    // text; this just flags that a switch from the active one
                    // happened. Mutually exclusive with raw fallback on success.
                    Text("fallback")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.amber)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.amber.opacity(0.14)))
                }
                Spacer()
                Text(e.destination)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }

            // Line 2: model, or the status when it isn't a clean "OK".
            if e.status == "OK" {
                Text(e.model ?? "—")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(e.status)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(e.status == "No audio" ? Theme.amber : Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Line 3: per-stage timings and char delta.
            HStack(spacing: 6) {
                Text("STT \(fmt(e.transcriptionMs)) · cleanup \(fmt(e.rewriteMs)) · total \(fmt(e.totalMs))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Text("\(e.inputChars)→\(e.outputChars) chars")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// Compact duration: "850ms" under a second, one-decimal seconds above.
    private func fmt(_ ms: Int) -> String {
        ms < 1000 ? "\(ms)ms" : String(format: "%.1fs", Double(ms) / 1000)
    }

    /// A reusable API-key settings row: connected dot + "Connected" + Remove, or
    /// empty dot + "Not connected" + Add key/Cancel, with the SecureField + Save
    /// revealed while adding. Used for both the Claude and ChatGPT keys.
    private func apiKeyRow(title: String,
                           placeholder: String,
                           connected: Bool,
                           adding: Binding<Bool>,
                           draft: Binding<String>,
                           onSave: @escaping () -> Void,
                           onRemove: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                if connected {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.green).frame(width: 6, height: 6)
                        Text("Connected").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                    Button("Remove", action: onRemove)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.red)
                } else {
                    HStack(spacing: 6) {
                        Circle().fill(Color.white.opacity(0.25)).frame(width: 6, height: 6)
                        Text("Not connected").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                    Button(adding.wrappedValue ? "Cancel" : "Add key") {
                        withAnimation(.easeInOut(duration: 0.18)) { adding.wrappedValue.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                }
            }

            if !connected && adding.wrappedValue {
                HStack(spacing: 6) {
                    SecureField(placeholder, text: draft)
                        .onSubmit(onSave)
                        .insetField()
                    Button("Save", action: onSave)
                        .font(.system(size: 11))
                        .disabled(draft.wrappedValue.isEmpty)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private var shortcutSettingRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Dictation shortcut")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                if recordingShortcut {
                    Text("Press a shortcut…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.accent)
                    Button("Cancel") { stopRecordingShortcut() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    HStack(spacing: 5) { keycaps(for: currentShortcut) }
                    Button("Change") { startRecordingShortcut() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }

            // Validation hint (e.g. a modifier-less press while recording).
            if let hint = shortcutHint {
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Restore ⌃⌥Space. Only shown when the binding has drifted from it.
            if !recordingShortcut && currentShortcut != .default {
                Button("Reset to default") { resetShortcut() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        // The local monitor must never outlive the row (e.g. closing Settings
        // mid-record); also removed when recording stops.
        .onDisappear { stopRecordingShortcut() }
    }

    /// Begin capturing the next chord with a local event monitor. Returning nil
    /// from the monitor swallows the captured keys so they don't also act in the
    /// app. A valid `.keyDown` saves and stops; bare Escape cancels; a press with
    /// no modifier shows a hint and keeps recording.
    private func startRecordingShortcut() {
        // Never let both recorders run at once: two local monitors would process
        // the same press on stale state and could double-save (default + a tone
        // slot on the same key), bypassing the collision checks that run serially.
        stopRecordingChord()
        shortcutHint = nil
        recordingShortcut = true
        // Disarm the global tap while recording. It's a session-level
        // (`.cgSessionEventTap`, head-inserted) tap that sees keystrokes BEFORE
        // this local monitor, so an overlapping chord — the current binding, or
        // any superset of its main key — would otherwise engage a phantom
        // dictation and consume the keyDown before the recorder ever saw it
        // (also wedging the mic on if the main key is swapped mid-hold). Re-armed
        // in stopRecordingShortcut() with the freshly-saved binding.
        coordinator.stopHotkey()
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Still assembling modifiers — the main key hasn't been pressed yet.
            if event.type == .flagsChanged { return event }

            let hasModifier = !event.modifierFlags
                .intersection([.control, .option, .command, .shift]).isEmpty

            // Bare Escape cancels without changing the binding.
            if event.keyCode == UInt16(kVK_Escape) && !hasModifier {
                stopRecordingShortcut()
                return nil
            }

            if let shortcut = DictationShortcut(nsEvent: event) {
                // Reciprocate the tone-chord collision check (chordConflict): the
                // default chord and every tone chord must have unique keyCodes, or
                // HotkeyMonitor.matchChord (default-first) silently shadows the
                // tone chord. Reject here so the invariant holds from both sides.
                if let holder = toneSlotHolder(keyCode: shortcut.keyCode) {
                    shortcutHint = "Already used by \(holder)."
                    return nil   // keep recording
                }
                shortcutStorage = shortcut.storageString
                stopRecordingShortcut()   // re-arms the tap, picking up the new binding
                return nil
            }

            // Invalid (no modifier): hint and keep recording.
            shortcutHint = "Use at least one modifier (⌃ ⌥ ⌘ ⇧)"
            return nil
        }
    }

    private func stopRecordingShortcut() {
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutMonitor = nil
        }
        let wasRecording = recordingShortcut
        recordingShortcut = false
        shortcutHint = nil
        // Re-arm the global tap we disarmed in startRecordingShortcut(); start()
        // reloads the (possibly just-changed) binding. Guarded so a plain
        // Settings dismissal that never recorded doesn't needlessly re-arm.
        if wasRecording { coordinator.startHotkey() }
    }

    private func resetShortcut() {
        let defaultKeyCode = DictationShortcut.default.keyCode
        // Preserve keyCode-uniqueness: if a tone chord sits on the default's key,
        // the restored default would shadow it (HotkeyMonitor.matchChord is
        // default-first), so clear that tone chord's key to keep state honest —
        // it's visibly unassigned in the rows below rather than silently dead.
        var cleared = false
        for i in toneChords.slots.indices where toneChords.slots[i].keyCode == defaultKeyCode {
            toneChords.slots[i].keyCode = nil
            cleared = true
        }
        if cleared { toneChords.save() }
        shortcutStorage = DictationShortcut.default.storageString
        coordinator.updateHotkey()
    }

    // MARK: - Tone shortcuts (one-shot tone chords)

    /// Up to three ⌃⌥-only chords that each dictate once in a specific tone,
    /// without changing the active tone. Each row picks a tone and captures a key.
    private var toneChordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tone shortcuts")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Hold ⌃⌥ + a key to dictate once in a chosen tone — your active tone stays put.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 2)

            VStack(spacing: 0) {
                ForEach(0..<ToneChordStore.slotCount, id: \.self) { i in
                    if i > 0 { hairline }
                    toneChordRow(i)
                }
            }
            .groupedCardSurface()
        }
        // The local monitor must never outlive the view (e.g. closing Settings
        // mid-capture); also removed when capture finishes.
        .onDisappear { stopRecordingChord() }
    }

    private func toneChordRow(_ index: Int) -> some View {
        let slot = toneChords.slots[index]
        let isRecording = recordingChordIndex == index
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Tone selection. A native Menu keeps this row compact; "None"
                // clears the tone reference (leaving the key, if any).
                Menu {
                    Button("None") { setSlotTone(index, nil) }
                    ForEach(profiles.items) { profile in
                        Button(profile.name.isEmpty ? "Untitled" : profile.name) {
                            setSlotTone(index, profile.id)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(slotToneLabel(slot))
                            .font(.system(size: 12.5))
                            .foregroundStyle(slotToneIsSet(slot) ? .white.opacity(0.9) : .white.opacity(0.4))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 120, alignment: .leading)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)

                Spacer(minLength: 6)

                if isRecording {
                    Text("Press ⌃⌥ + a key…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                    Button("Cancel") { stopRecordingChord() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    if let keyCode = slot.keyCode {
                        HStack(spacing: 5) {
                            Keycap("⌃"); Keycap("⌥")
                            Keycap(DictationShortcut.keyName(for: keyCode))
                        }
                    }
                    Button(slot.keyCode == nil ? "Set key" : "Change") {
                        startRecordingChord(index)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)

                    if slot.toneID != nil || slot.keyCode != nil {
                        Button { clearSlot(index) } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if isRecording, let hint = chordHint {
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// True only when the slot references a tone that still exists.
    private func slotToneIsSet(_ slot: ToneChordSlot) -> Bool {
        guard let id = slot.toneID else { return false }
        return profiles.items.contains { $0.id == id }
    }

    /// The slot's tone label: the tone name, "Choose tone" when unset, or
    /// "Deleted tone" when its tone was removed (reflecting the no-op state).
    private func slotToneLabel(_ slot: ToneChordSlot) -> String {
        guard let id = slot.toneID else { return "Choose tone" }
        guard let profile = profiles.items.first(where: { $0.id == id }) else { return "Deleted tone" }
        return profile.name.isEmpty ? "Untitled" : profile.name
    }

    private func setSlotTone(_ index: Int, _ id: UUID?) {
        toneChords.slots[index].toneID = id
        toneChords.save()
        coordinator.updateHotkey()
    }

    private func clearSlot(_ index: Int) {
        toneChords.slots[index] = .empty
        toneChords.save()
        coordinator.updateHotkey()
    }

    /// Begin capturing a ⌃⌥-only chord key for `index`. Like the default-shortcut
    /// recorder, this disarms the global tap so an overlapping chord can't engage
    /// a phantom dictation, then a local monitor captures the next key — accepting
    /// ONLY Control+Option + a single key, and rejecting collisions.
    private func startRecordingChord(_ index: Int) {
        // Tear down ANY in-progress capture first — the default-shortcut recorder
        // AND a chord recorder already running on another row. The latter is
        // reachable: while one row records, the other rows still show an active
        // "Set key"/"Change" button, so the user can switch rows mid-capture.
        // Without stopRecordingChord() here, reassigning `chordMonitor` below
        // would LEAK the previous NSEvent monitor (losing the reference doesn't
        // remove it). Local monitors fire in install order, so the stale monitor —
        // which captured a DIFFERENT row's `index` — would intercept the next
        // ⌃⌥+key, write to the wrong slot, and swallow the event (return nil) so
        // the intended row's monitor never runs. Only one capture may be live.
        stopRecordingShortcut()
        stopRecordingChord()
        chordHint = nil
        recordingChordIndex = index
        coordinator.stopHotkey()
        chordMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Still assembling modifiers — the key hasn't been pressed yet.
            if event.type == .flagsChanged { return event }

            let mods = event.modifierFlags.intersection([.control, .option, .command, .shift])

            // Diagnostic: a captured keyDown reached us. If a chord SILENTLY fails
            // to record, the absence of this line for that combo is the signal it
            // was grabbed before reaching the app (vs. fired-but-rejected). Identity
            // is keyCode + the fixed ⌃⌥ flags — NEVER the Option-modified character
            // (⌥D→∂, ⌥1→¡, …), which would mishandle exactly those keys.
            Log.hotkey.notice("chord recorder keyDown keyCode=\(event.keyCode, privacy: .public) mods=\(mods.rawValue, privacy: .public)")

            // A real key arrived: cancel the "didn't reach the app" soft note.
            chordTimeoutWork?.cancel(); chordTimeoutWork = nil

            // Bare Escape cancels without changing the slot.
            if event.keyCode == UInt16(kVK_Escape) && mods.isEmpty {
                stopRecordingChord()
                return nil
            }

            // Require EXACTLY Control+Option (the fixed tone-chord modifier set) —
            // stricter than the default recorder, which allows any ≥1-modifier combo.
            guard mods == [.control, .option] else {
                chordHint = "Use exactly ⌃⌥ + a key"
                return nil
            }

            let keyCode = Int64(event.keyCode)
            // Collision: keyCode must be unique across the default chord and the
            // other tone slots, so the tap can disambiguate the press. Names the
            // holder so the block is visible, not silent.
            if let conflict = chordConflict(keyCode: keyCode, excluding: index) {
                chordHint = conflict
                return nil
            }

            toneChords.slots[index].keyCode = keyCode
            toneChords.save()
            coordinator.updateHotkey()
            stopRecordingChord()   // re-arms the tap with the new binding
            return nil
        }

        // Best-effort external-grab hint: if nothing is captured within a few
        // seconds, surface a soft note (a guess, not a lookup). Kept if a collision
        // message is already showing — that's a more specific explanation.
        let work = DispatchWorkItem {
            if recordingChordIndex == index, chordHint == nil {
                chordHint = "This combo didn't reach the app — it may be reserved by macOS or another app."
            }
        }
        chordTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    private func stopRecordingChord() {
        chordTimeoutWork?.cancel()
        chordTimeoutWork = nil
        if let monitor = chordMonitor {
            NSEvent.removeMonitor(monitor)
            chordMonitor = nil
        }
        let wasRecording = recordingChordIndex != nil
        recordingChordIndex = nil
        chordHint = nil
        // Re-arm the global tap disarmed in startRecordingChord(); start() reloads
        // the (possibly just-changed) bindings. Guarded so a plain disappear that
        // never recorded doesn't needlessly re-arm.
        if wasRecording { coordinator.startHotkey() }
    }

    /// A collision message if `keyCode` clashes with the default dictation chord
    /// or another tone slot, else nil. keyCode-level (conservative): it blocks a
    /// few technically-unambiguous combos, but guarantees the tap never co-fires.
    /// Names the holder so the block is visible feedback, not a silent no-op.
    private func chordConflict(keyCode: Int64, excluding index: Int) -> String? {
        if currentShortcut.keyCode == keyCode {
            return "Already used by the dictation shortcut."
        }
        if let holder = toneSlotHolder(keyCode: keyCode, excluding: index) {
            return "Already used by \(holder)."
        }
        return nil
    }

    /// Names the tone slot bound to `keyCode` (excluding one index), or nil if
    /// none — its tone name when set (e.g. `tone “Professional”`), else its
    /// position (`tone shortcut 2`). Shared by both recorders' collision messages.
    private func toneSlotHolder(keyCode: Int64, excluding index: Int? = nil) -> String? {
        for (i, slot) in toneChords.slots.enumerated() {
            if i == index { continue }
            guard slot.keyCode == keyCode else { continue }
            if let id = slot.toneID,
               let profile = profiles.items.first(where: { $0.id == id }), !profile.name.isEmpty {
                return "tone “\(profile.name)”"
            }
            return "tone shortcut \(i + 1)"
        }
        return nil
    }

    private func saveAPIKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Keychain.setAPIKey(key)
        apiKeyDraft = ""
        hasStoredKey = true
        addingKey = false
    }

    /// Refresh both cloud-key "connected" indicators from the Keychain. Called
    /// on every popover/Settings appearance so a key added or removed elsewhere
    /// is reflected.
    private func refreshKeyStatus() {
        hasStoredKey = Keychain.apiKey()?.isEmpty == false
        hasOpenAIKey = Keychain.openAIKey()?.isEmpty == false
    }

    private func saveOpenAIKey() {
        let key = openAIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Keychain.setOpenAIKey(key)
        openAIKeyDraft = ""
        hasOpenAIKey = true
        addingOpenAIKey = false
    }

    /// Marketing version from the bundle, or nil if unavailable (don't hardcode).
    private var versionString: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    // MARK: - Small shared pieces

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
    }

    private func appIcon(size: CGFloat) -> some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }
}

// MARK: - Design tokens
//
// `Theme` and the `Color(hex:)` initializer live in SharedVisuals.swift (shared
// with the on-screen HUD).

private extension View {
    /// Card chrome: hairline-bordered translucent rounded rectangle.
    func cardSurface() -> some View {
        background(
            RoundedRectangle(cornerRadius: 13)
                .fill(Color.white.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
        )
    }

    /// Grouped-card chrome (rows pad themselves; no outer padding).
    func groupedCardSurface() -> some View {
        background(
            RoundedRectangle(cornerRadius: 13)
                .fill(Color.white.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
        )
    }

    /// Inset, transparent text-field chrome (reads as part of the card).
    func insetField() -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            )
    }
}

// MARK: - Reusable subviews

/// A styled keycap (e.g. ⌃ ⌥ Space).
private struct Keycap: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            )
    }
}

/// The status dot in the header; a static colored circle (no animation —
/// the pulse rendered a square artifact mid-cycle).
private struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.7), radius: 1)
    }
}

// `WaveformBars` lives in SharedVisuals.swift (shared with the on-screen HUD).

/// Expanding/fading accent ring behind the recording hero.
private struct PulseRing: View {
    @State private var animate = false
    var body: some View {
        Circle()
            .strokeBorder(Color(hex: 0x9A8BFF, alpha: 0.45), lineWidth: 2)
            .frame(width: 76, height: 76)
            .scaleEffect(animate ? 1.45 : 0.95)
            .opacity(animate ? 0 : 1)
            .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: animate)
            .onAppear { animate = true }
    }
}

// `Spinner` lives in SharedVisuals.swift (shared with the on-screen HUD).

/// A 30×30 icon button with an 8pt hover background (the header gear).
private struct HoverIconButton: View {
    let system: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hover ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A full-width dashed "add" button; border tints violet on hover.
private struct DashedAddButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(hover ? Color(hex: 0x9A8BFF) : Color.white.opacity(0.18),
                                  style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The custom Local-mode toggle (violet, glowing when on).
private struct LocalToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(Color(hex: 0x9A8BFF)) : AnyShapeStyle(Color.white.opacity(0.14)))
                    .frame(width: 40, height: 24)
                    .shadow(color: isOn ? Color(hex: 0x9A8BFF, alpha: 0.4) : .clear, radius: 6)
                Circle().fill(.white).frame(width: 18, height: 18).padding(3)
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.25), value: isOn)
    }
}

/// Measures content height so the scroll area can size to content up to the cap.
private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
