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
        VStack(alignment: .leading, spacing: 24) {
            header
            recordingSection
            modelSection
            recognitionSection
            privacySection
            permissionsSection
            footer
        }
        .padding(28)
        .frame(maxWidth: 860, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dictation, on your terms")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Everything stays on this Mac. Choose how Dictum listens, writes, and keeps your recordings.")
                .font(.system(size: 14))
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

            Divider()

            Toggle("Paste the result at the cursor", isOn: $settingsViewModel.settings.autoPaste)
            Toggle("Add a space after each dictation", isOn: $settingsViewModel.settings.appendTrailingSpace)
            Toggle("Show the floating recording indicator", isOn: $settingsViewModel.settings.showOverlay)
            Toggle("Launch Dictum when you log in", isOn: $settingsViewModel.settings.launchAtLogin)
        }
    }

    private var modelSection: some View {
        SettingsCard(title: "Local model", subtitle: "Models download once, then run privately on this Mac") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                ForEach(TranscriptionModelOption.all, id: \.id) { option in
                    Button {
                        settingsViewModel.settings.modelIdentifier = option.id
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text(option.title)
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                if option.isRecommended {
                                    Text("RECOMMENDED")
                                        .font(.system(size: 8, weight: .bold, design: .rounded))
                                        .foregroundStyle(.tint)
                                }
                                Spacer(minLength: 0)
                                if settingsViewModel.settings.modelIdentifier == option.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                            Text(option.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                            Text(option.downloadSize)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                        .padding(12)
                        .background(modelCardBackground(isSelected: settingsViewModel.settings.modelIdentifier == option.id))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use \(option.title)")
                }
            }
            Picker("Memory", selection: $settingsViewModel.settings.modelMemoryPolicy) {
                ForEach(ModelMemoryPolicy.allCases, id: \.self) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .pickerStyle(.menu)
            Text("Releasing the model saves memory. The downloaded model stays on disk and is loaded again automatically when you dictate.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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

            VStack(alignment: .leading, spacing: 7) {
                Text("Custom words")
                    .font(.system(size: 13, weight: .medium))
                Text("Names, brands, abbreviations, and domain terms. Separate entries with commas or new lines.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextEditor(text: customWordsText)
                    .font(.system(size: 13))
                    .frame(minHeight: 66)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
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
            Text("Recordings with failed or empty transcription are kept for recovery until you retranscribe or delete them.")
                .font(.system(size: 11))
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
        .padding(.bottom, 8)
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

    private func modelCardBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor).opacity(0.35), lineWidth: isSelected ? 1.5 : 1)
            }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.32), lineWidth: 1)
        }
    }
}
