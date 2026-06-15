//
//  OnboardingView.swift
//  WhisprSoft
//
//  The permission checklist shown in the popover while the hard gate is
//  closed. Observes PermissionsManager and drives its request/settings
//  actions. Rendered by MenuBarContent when !permissions.allGranted.
//

import SwiftUI

struct OnboardingView: View {
    let permissions: PermissionsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions needed")
                .font(.headline)

            Text("WhisprSoft can't run until all three are granted. Input Monitoring may require relaunching the app after you grant it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            permissionRow(
                title: "Microphone",
                why: "Records your voice to transcribe it.",
                status: permissions.microphone
            ) {
                switch permissions.microphone {
                case .notDetermined:
                    Button("Grant") {
                        Task { await permissions.requestMicrophone() }
                    }
                case .denied:
                    Button("Open Settings") { permissions.openMicrophoneSettings() }
                case .granted:
                    EmptyView()
                }
            }

            permissionRow(
                title: "Accessibility",
                why: "Pastes the transcribed text into the app you're using.",
                status: permissions.accessibility
            ) {
                if permissions.accessibility != .granted {
                    HStack(spacing: 8) {
                        Button("Grant Access") { permissions.requestAccessibility() }
                        Button("Open Settings") { permissions.openAccessibilitySettings() }
                    }
                }
            }

            permissionRow(
                title: "Input Monitoring",
                why: "Detects the ⌃⌥Space hotkey so you can start dictation from any app. May require relaunching after granting.",
                status: permissions.inputMonitoring
            ) {
                if permissions.inputMonitoring != .granted {
                    HStack(spacing: 8) {
                        Button("Grant Access") { permissions.requestInputMonitoring() }
                        Button("Open Settings") { permissions.openInputMonitoringSettings() }
                    }
                }
            }

            Divider()

            HStack {
                Button("Re-check") { permissions.refresh() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 280)
        .onAppear { permissions.refresh() }
    }

    /// One checklist row: status glyph + title/why on the left, the
    /// permission-specific action on the right.
    @ViewBuilder
    private func permissionRow<Action: View>(
        title: String,
        why: String,
        status: PermissionStatus,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(status == .granted ? .green : .orange)
                .imageScale(.large)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(why).font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            action()
        }
    }
}
