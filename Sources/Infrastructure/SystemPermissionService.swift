import Application
import AppKit
import AVFoundation
import Domain
import Foundation

@MainActor
public final class SystemPermissionService: PermissionService {
    public init() {}

    public func currentSnapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            microphone: microphoneStatus(),
            accessibility: accessibilityStatus(),
            inputMonitoring: inputMonitoringStatus()
        )
    }

    public func requestMissingPermissions() async -> PermissionSnapshot {
        if microphoneStatus() != .authorized {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }

        if accessibilityStatus() != .authorized {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        if inputMonitoringStatus() != .authorized {
            _ = CGRequestListenEventAccess()
        }

        return currentSnapshot()
    }

    public func openSystemSettings(for permission: PermissionKind) {
        let urlString: String
        switch permission {
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        }

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        default:
            return .denied
        }
    }

    private func accessibilityStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .authorized : .denied
    }

    private func inputMonitoringStatus() -> PermissionStatus {
        CGPreflightListenEventAccess() ? .authorized : .denied
    }
}
