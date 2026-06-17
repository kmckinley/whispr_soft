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

struct MenuBarContent: View {
    let coordinator: Coordinator
    let permissions: PermissionsManager
    @Bindable var corrections: CorrectionsStore
    @Bindable var profiles: RewriteProfilesStore
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

    /// Measured height of the current scrollable body, capped at 444 (the design
    /// cap); a `.window` MenuBarExtra sizes to content, so the scroll area needs
    /// a determinate height. Starts non-zero so the first frame doesn't collapse.
    @State private var bodyHeight: CGFloat = 380

    /// Route cleanup to the local LM Studio instead of cloud Claude. Read fresh
    /// per rewrite by RewriteLadder, so toggling takes effect immediately.
    @AppStorage("localMode") private var localMode = false

    /// Reveal the per-dictation diagnostic log at the bottom of Settings. Logs
    /// are always collected in memory; this only controls visibility.
    @AppStorage("showLogs") private var showLogs = false

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
        .onChange(of: profiles.items) { _, _ in profiles.save() }
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
                    why: "Pastes transcribed text and detects the ⌃⌥Space hotkey.",
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
                    Keycap("⌃"); Keycap("⌥"); Keycap("Space")
                }
            }
        case .recording:
            heroSub("Release to finish")
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
            Text("Replaces misheard words after cleanup, automatically.")
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
                shortcutSettingRow
            }
            .groupedCardSurface()

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
                    Text("Per-dictation diagnostics. Kept in memory only, cleared on quit.")
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
            // Line 1: time · engine (+ raw-fallback tag) · destination.
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
        HStack {
            Text("Dictation shortcut")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            HStack(spacing: 5) { Keycap("⌃"); Keycap("⌥"); Keycap("Space") }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
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

private enum Theme {
    static let accent = Color(hex: 0x9A8BFF)
    static let accentSoft = Color(hex: 0x9A8BFF, alpha: 0.16)
    static let accentBorder = Color(hex: 0x9A8BFF, alpha: 0.45)
    static let accentGlow = Color(hex: 0x9A8BFF, alpha: 0.40)
    static let violetCheck = Color(hex: 0xB6ABFF)
    static let green = Color(hex: 0x5FD39A)
    static let amber = Color(hex: 0xF5B14C)
    static let red = Color(hex: 0xFF8080)
    static let micTint = Color(hex: 0xCFC9FF)
    static let micDark = Color(hex: 0x6A59E0)
    static let knobDark = Color(hex: 0x171426)
}

private extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

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

/// Seven staggered waveform bars (recording hero).
private struct WaveformBars: View {
    private let heights: [CGFloat] = [16, 24, 30, 21, 30, 24, 16]
    @State private var animating = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 3, height: heights[i])
                    .scaleEffect(y: animating ? 1 : 0.4, anchor: .center)
                    .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true).delay(Double(i) * 0.08),
                               value: animating)
            }
        }
        .onAppear { animating = true }
    }
}

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

/// A 30pt indeterminate spinner (processing / model-loading hero).
private struct Spinner: View {
    @State private var rotate = false
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(rotate ? 360 : 0))
                .animation(.linear(duration: 0.7).repeatForever(autoreverses: false), value: rotate)
        }
        .frame(width: 30, height: 30)
        .onAppear { rotate = true }
    }
}

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
