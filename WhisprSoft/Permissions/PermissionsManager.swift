//
//  PermissionsManager.swift
//  WhisprSoft
//
//  Single source of truth for permission status. The UI observes it; it
//  does NOT touch the Coordinator or the pipeline. The hard gate that
//  blocks the pipeline lives in the UI (see MenuBarContent), not here.
//

import AVFoundation
import ApplicationServices
import AppKit

enum PermissionStatus {
    case notDetermined
    case denied
    case granted
}

@MainActor
@Observable
final class PermissionsManager {
    private(set) var microphone: PermissionStatus = .notDetermined
    private(set) var accessibility: PermissionStatus = .notDetermined

    init() {
        refresh()
    }

    var allGranted: Bool {
        microphone == .granted && accessibility == .granted
    }

    /// Re-query both permissions and update status. Cheap; call on every
    /// appearance of the gate so returning from System Settings reflects
    /// immediately.
    func refresh() {
        microphone = currentMicrophoneStatus()
        accessibility = AXIsProcessTrusted() ? .granted : .notDetermined
    }

    /// Triggers the inline mic TCC dialog when not yet determined;
    /// updates status with the result.
    func requestMicrophone() async {
        // requestAccess only shows the dialog when status is
        // .notDetermined; otherwise it returns the standing decision.
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphone = granted ? .granted : currentMicrophoneStatus()
    }

    /// Shows the system Accessibility prompt (which itself offers to open
    /// System Settings). Status updates on the next refresh().
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Opens a System Settings pane directly — used for the mic `.denied`
    /// case where re-prompting is impossible.
    func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    // MARK: - Helpers

    private func currentMicrophoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:           return .granted
        case .notDetermined:        return .notDetermined
        case .denied, .restricted:  return .denied
        @unknown default:           return .denied
        }
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
