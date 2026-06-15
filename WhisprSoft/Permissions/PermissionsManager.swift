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
import CoreGraphics

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
    private(set) var inputMonitoring: PermissionStatus = .notDetermined

    init() {
        refresh()
    }

    var allGranted: Bool {
        microphone == .granted && accessibility == .granted && inputMonitoring == .granted
    }

    /// Re-query all three permissions and update status. Cheap; call on every
    /// appearance of the gate so returning from System Settings reflects
    /// immediately.
    func refresh() {
        microphone = currentMicrophoneStatus()
        accessibility = AXIsProcessTrusted() ? .granted : .notDetermined
        // Like Accessibility, the system exposes no "denied" state — only
        // granted vs. not-yet-enabled.
        inputMonitoring = CGPreflightListenEventAccess() ? .granted : .notDetermined
    }

    /// Triggers the inline mic TCC dialog when not yet determined;
    /// updates status with the result.
    func requestMicrophone() async {
        // requestAccess only shows the dialog when status is
        // .notDetermined; otherwise it returns the standing decision.
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphone = granted ? .granted : currentMicrophoneStatus()
    }

    /// Shows the system Accessibility prompt and opens the Accessibility
    /// settings pane. Status updates on the next refresh().
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
    }

    /// Shows the Input Monitoring prompt (first call registers the app) and
    /// opens the Input Monitoring settings pane. Status updates on refresh().
    func requestInputMonitoring() {
        CGRequestListenEventAccess()
        openInputMonitoringSettings()
    }

    /// Opens a System Settings pane directly — used for the mic `.denied`
    /// case where re-prompting is impossible.
    func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
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
