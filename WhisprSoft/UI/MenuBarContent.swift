//
//  MenuBarContent.swift
//  WhisprSoft
//
//  The menu-bar popover. Observes the Coordinator and PermissionsManager.
//

import SwiftUI

struct MenuBarContent: View {
    let coordinator: Coordinator
    let permissions: PermissionsManager
    @Bindable var corrections: CorrectionsStore

    /// Draft API key being typed in the field; cleared after Save.
    @State private var apiKeyDraft = ""
    /// Whether a key is currently stored. Refreshed on appear and after edits.
    @State private var hasStoredKey = false
    /// Route cleanup to the local LM Studio instead of cloud Claude. Read fresh
    /// per rewrite by RewriteLadder, so toggling takes effect immediately.
    @AppStorage("localMode") private var localMode = false

    var body: some View {
        // Hard gate: until both permissions are granted the popover shows
        // only the onboarding checklist — the pipeline control is not even
        // rendered, so a run is unreachable from the UI.
        Group {
            if permissions.allGranted {
                pipelineControls
            } else {
                OnboardingView(permissions: permissions)
            }
        }
        // Re-evaluate the gate on every popover appearance so a permission
        // changed in System Settings (granted OR revoked) is reflected when
        // the menu reopens — in both branches, not just onboarding.
        .onAppear { permissions.refresh() }
        // Arm the hotkey the moment all permissions are granted and disarm it
        // on revocation. `initial: true` covers the popover opening while
        // already granted; the AppDelegate handles the launch-time arming.
        .onChange(of: permissions.allGranted, initial: true) { _, granted in
            if granted { coordinator.startHotkey() } else { coordinator.stopHotkey() }
        }
    }

    private var pipelineControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(statusLine)
                .font(.headline)

            if coordinator.isModelLoading {
                Text("Preparing transcription model…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Hold ⌃⌥Space to dictate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            localModeSection

            apiKeySection

            Divider()

            correctionsSection

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear { hasStoredKey = Keychain.apiKey()?.isEmpty == false }
        .onChange(of: corrections.items) { _, _ in corrections.save() }
    }

    /// One correction row's approximate laid-out height (rounded-border caption
    /// TextField) and the inter-row spacing, used to size the scroll viewport.
    private static let correctionRowHeight: CGFloat = 28
    private static let correctionRowSpacing: CGFloat = 4

    /// Height that shows up to five rows; a longer list scrolls inside it.
    private var correctionsScrollHeight: CGFloat {
        let visible = CGFloat(min(corrections.items.count, 5))
        return visible * Self.correctionRowHeight
            + max(visible - 1, 0) * Self.correctionRowSpacing
    }

    /// Always-visible editor for the deterministic keyword corrections applied
    /// after cleanup. Persists on any change via the `.onChange` above — no
    /// Save button. Blank rows are harmless (the corrector skips blank `from`).
    private var correctionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Corrections")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Replaces misheard words after cleanup.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if corrections.items.isEmpty {
                Text("No corrections yet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            } else {
                ScrollView {
                    VStack(spacing: Self.correctionRowSpacing) {
                        ForEach($corrections.items) { $item in
                            HStack(spacing: 4) {
                                // `heard` is forced lowercase as typed — matching
                                // is case-insensitive anyway, so this just keeps
                                // the stored key tidy. `replace with` stays verbatim.
                                TextField("heard", text: Binding(
                                    get: { item.from },
                                    set: { $item.from.wrappedValue = $0.lowercased() }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                TextField("replace with", text: $item.to)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                Button {
                                    corrections.remove(item)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                // A ScrollView has no intrinsic height — in the self-sizing
                // popover it would collapse under `maxHeight`, so pin a fixed
                // height sized to show up to five rows (more then scroll).
                .frame(height: correctionsScrollHeight)
            }

            Button {
                corrections.add()
            } label: {
                Label("Add correction", systemImage: "plus")
            }
            .font(.caption)
        }
    }

    /// Local Mode toggle: route cleanup to a local LM Studio instead of cloud
    /// Claude. Local-only — audio-derived text never leaves the Mac.
    private var localModeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Local Mode", isOn: $localMode)
                .font(.caption)
            Text("Cleanup runs on your local LM Studio (127.0.0.1:1234); audio-derived text never leaves your Mac.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Compact Claude API-key entry. Secondary to the dictation hint: without a
    /// key, dictation still works but pastes raw (uncleaned) text. Unused while
    /// Local Mode is on, so it's dimmed with a note.
    @ViewBuilder
    private var apiKeySection: some View {
        if localMode {
            Text(hasStoredKey
                 ? "✓ Claude key saved — unused in Local Mode."
                 : "Claude API key — unused in Local Mode.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if hasStoredKey {
            HStack(spacing: 6) {
                Text("✓ Claude key saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Remove") {
                    Keychain.deleteAPIKey()
                    hasStoredKey = false
                }
                .font(.caption)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    SecureField("Claude API key", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveAPIKey)
                    Button("Save", action: saveAPIKey)
                        .disabled(apiKeyDraft.isEmpty)
                }
                Text("Optional — without a key, dictation pastes raw text.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func saveAPIKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Keychain.setAPIKey(key)
        apiKeyDraft = ""
        hasStoredKey = true
    }

    /// Human-readable description of the current pipeline state.
    private var statusLine: String {
        switch coordinator.state {
        case .idle:          return "Idle"
        case .recording:     return "Recording…"
        case .transcribing:  return "Transcribing…"
        case .rewriting:     return "Rewriting…"
        case .injecting:     return "Injecting…"
        case .error(let m):  return "Error: \(m)"
        }
    }
}
