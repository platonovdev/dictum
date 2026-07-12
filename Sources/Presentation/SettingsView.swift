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
        VStack(alignment: .leading, spacing: 16) {
            header
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12, alignment: .top),
                    GridItem(.flexible(), spacing: 12, alignment: .top)
                ],
                alignment: .leading,
                spacing: 12
            ) {
                recordingSection
                recognitionSection
                modelSection
                privacySection
                permissionsSection
                    .gridCellColumns(2)
            }
            footer
        }
        .controlSize(.small)
        .padding(20)
        .frame(maxWidth: 760, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.system(size: 23, weight: .semibold, design: .rounded))
            Text("Local dictation, shortcuts, history and privacy.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var recordingSection: some View {
        SettingsCard(title: "Recording", subtitle: "Start speaking from any app") {
            Picker("Shortcut", selection: $settingsViewModel.settings.hotkey.kind) {
                ForEach(HotkeyKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.menu)

            Toggle("Paste the result at the cursor", isOn: $settingsViewModel.settings.autoPaste)
            Toggle("Add a space after each dictation", isOn: $settingsViewModel.settings.appendTrailingSpace)
            Toggle("Show the floating recording indicator", isOn: $settingsViewModel.settings.showOverlay)
            Toggle("Launch Dictum when you log in", isOn: $settingsViewModel.settings.launchAtLogin)
        }
    }

    private var modelSection: some View {
        SettingsCard(title: "Local model", subtitle: "Private and offline after download") {
            if let option = TranscriptionModelOption.all.first {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text("Metal accelerated • \(option.downloadSize)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Divider()

            Picker("Memory", selection: $settingsViewModel.settings.modelMemoryPolicy) {
                ForEach(ModelMemoryPolicy.allCases, id: \.self) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var recognitionSection: some View {
        SettingsCard(title: "Recognition", subtitle: "Improve accuracy for the way you speak") {
            Picker("Spoken language", selection: $settingsViewModel.settings.language) {
                ForEach(DictationLanguage.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)

            Toggle("Translate to English", isOn: $settingsViewModel.settings.translateToEnglish)

            VStack(alignment: .leading, spacing: 5) {
                Text("Custom words")
                    .font(.system(size: 13, weight: .medium))
                TextEditor(text: customWordsText)
                    .font(.system(size: 12))
                    .frame(minHeight: 48)
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            }
        }
    }

    private var privacySection: some View {
        SettingsCard(title: "History & privacy", subtitle: "Transcripts stay on this Mac") {
            Picker("Keep recordings", selection: $settingsViewModel.settings.audioRetention) {
                ForEach(AudioRetentionPolicy.allCases, id: \.self) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .pickerStyle(.menu)
            Text("Failed recordings stay available for retry until deleted.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Stepper(
                value: $settingsViewModel.settings.historyLimit,
                in: 10...2_000,
                step: 10
            ) {
                HStack {
                    Text("History limit")
                    Spacer()
                    Text("\(settingsViewModel.settings.historyLimit) dictations")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13))
        }
    }

    private var permissionsSection: some View {
        SettingsCard(title: "Permissions", subtitle: "Needed to listen and write in other apps") {
            permissionRow(title: "Microphone", status: permissionsViewModel.snapshot.microphone, permission: .microphone)
            permissionRow(title: "Accessibility", status: permissionsViewModel.snapshot.accessibility, permission: .accessibility)
            permissionRow(title: "Input Monitoring", status: permissionsViewModel.snapshot.inputMonitoring, permission: .inputMonitoring)
            HStack {
                Button("Request missing permissions") { permissionsViewModel.requestPermissions() }
                Button("Refresh") { permissionsViewModel.refresh() }
                    .buttonStyle(.link)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let message = settingsViewModel.errorMessage ?? settingsViewModel.launchAtLoginNotice {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Save changes") { settingsViewModel.save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(settingsViewModel.isSaving)
        }
        .padding(.top, 2)
    }

    private var customWordsText: Binding<String> {
        Binding(
            get: { settingsViewModel.settings.customWords.joined(separator: "\n") },
            set: { newValue in
                settingsViewModel.settings.customWords = newValue
                    .split(whereSeparator: { $0 == "," || $0.isNewline })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private func permissionRow(title: String, status: PermissionStatus, permission: PermissionKind) -> some View {
        HStack {
            Circle()
                .fill(status == .authorized ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(title)
            Spacer()
            Text(status == .authorized ? "Ready" : status.rawValue.capitalized)
                .foregroundStyle(.secondary)
            Button("Open") { permissionsViewModel.openSystemSettings(for: permission) }
                .buttonStyle(.link)
        }
        .font(.system(size: 13))
    }

}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.78))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.32), lineWidth: 1)
        }
    }
}
