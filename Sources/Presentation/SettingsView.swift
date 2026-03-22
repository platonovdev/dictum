import Domain
import SwiftUI

public struct SettingsView: View {
    @ObservedObject private var settingsViewModel: SettingsViewModel
    @ObservedObject private var permissionsViewModel: PermissionsViewModel

    public init(
        settingsViewModel: SettingsViewModel,
        permissionsViewModel: PermissionsViewModel
    ) {
        self.settingsViewModel = settingsViewModel
        self.permissionsViewModel = permissionsViewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.system(size: 28, weight: .semibold, design: .rounded))

            Form {
                Picker("Model", selection: $settingsViewModel.settings.modelIdentifier) {
                    ForEach(TranscriptionModelOption.all, id: \.id) { option in
                        Text(option.title).tag(option.id)
                    }
                }

                if let selectedModel = TranscriptionModelOption.option(for: settingsViewModel.settings.modelIdentifier) {
                    Text(selectedModel.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Picker("Hotkey", selection: $settingsViewModel.settings.hotkey.kind) {
                    ForEach(HotkeyKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }

                Toggle("Auto paste result", isOn: $settingsViewModel.settings.autoPaste)
                Toggle("Launch at login", isOn: $settingsViewModel.settings.launchAtLogin)
            }

            permissionsSection

            Text("Dictation is optimized for Russian speech in this build. Switching to a new model downloads it once, then macOS reuses the local cache across app rebuilds.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if let message = settingsViewModel.errorMessage ?? settingsViewModel.launchAtLoginNotice {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Save Settings") {
                    settingsViewModel.save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(settingsViewModel.isSaving)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
                .font(.headline)

            permissionRow(title: "Microphone", status: permissionsViewModel.snapshot.microphone, permission: .microphone)
            permissionRow(title: "Accessibility (recommended)", status: permissionsViewModel.snapshot.accessibility, permission: .accessibility)
            permissionRow(title: "Input Monitoring (optional)", status: permissionsViewModel.snapshot.inputMonitoring, permission: .inputMonitoring)

            HStack {
                Button("Request Permissions") {
                    permissionsViewModel.requestPermissions()
                }

                Button("Refresh Status") {
                    permissionsViewModel.refresh()
                }
            }

            if !permissionsViewModel.snapshot.missingRecommendedPermissions.isEmpty {
                Text("Accessibility improves direct text insertion, and Input Monitoring can help macOS deliver the global hotkey more reliably. Neither blocks dictation startup in this build.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func permissionRow(title: String, status: PermissionStatus, permission: PermissionKind) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(status.rawValue.capitalized)
                .foregroundStyle(status == .authorized ? .green : .secondary)
            Button("Open Settings") {
                permissionsViewModel.openSystemSettings(for: permission)
            }
        }
    }
}
