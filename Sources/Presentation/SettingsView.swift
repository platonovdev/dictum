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
            settingsHeader
            Form {
                Section(L10n.text("Dictation", "Диктовка")) {
                    Picker(L10n.text("Shortcut", "Сочетание клавиш"), selection: $settingsViewModel.settings.hotkey.kind) {
                        ForEach(HotkeyKind.allCases, id: \.self) { kind in
                            Text(hotkeyTitle(kind)).tag(kind)
                        }
                    }
                    Toggle(L10n.text("Paste recognized text at cursor", "Вставлять распознанный текст в позицию курсора"), isOn: $settingsViewModel.settings.autoPaste)
                    Toggle(L10n.text("Add a space after each dictation", "Добавлять пробел после каждой диктовки"), isOn: $settingsViewModel.settings.appendTrailingSpace)
                    Toggle(L10n.text("Show floating recording indicator", "Показывать плавающий индикатор записи"), isOn: $settingsViewModel.settings.showOverlay)
                    Toggle(
                        L10n.text("Pause media while recording", "Ставить музыку на паузу во время записи"),
                        isOn: $settingsViewModel.settings.pauseMediaDuringRecording
                    )
                    .help(L10n.text(
                        "Resume only media paused by Dictator when recording ends.",
                        "После записи продолжить только то воспроизведение, которое остановил Диктатор."
                    ))
                    VStack(alignment: .leading, spacing: 7) {
                        LabeledContent(L10n.text("Sound", "Звук")) {
                            HStack(spacing: 8) {
                                Picker("", selection: $settingsViewModel.settings.feedbackSoundTheme) {
                                    ForEach(DictationSoundTheme.allCases, id: \.self) { theme in
                                        Text(soundThemeTitle(theme)).tag(theme)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 150)
                                .onChange(of: settingsViewModel.settings.feedbackSoundTheme) {
                                    settingsViewModel.previewFeedbackSound()
                                }

                                Button {
                                    settingsViewModel.previewFeedbackSound()
                                } label: {
                                    Image(systemName: "play.fill")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(settingsViewModel.settings.feedbackSoundVolume <= 0.001)
                                .help(L10n.text("Preview sound", "Прослушать звук"))
                                .accessibilityLabel(L10n.text("Preview selected sound", "Прослушать выбранный звук"))
                            }
                        }
                        LabeledContent(L10n.text("Volume", "Громкость")) {
                            Text(soundVolumeLabel)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Image(systemName: soundVolumeSymbol)
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Slider(
                                value: $settingsViewModel.settings.feedbackSoundVolume,
                                in: 0...1,
                                step: 0.05
                            )
                            .accessibilityLabel(L10n.text("Interface sound volume", "Громкость звуков интерфейса"))
                            .accessibilityValue(soundVolumeLabel)
                        }
                    }
                    Toggle(L10n.text("Launch Dictator at login", "Запускать Диктатор при входе в систему"), isOn: $settingsViewModel.settings.launchAtLogin)
                }

                Section(L10n.text("Recognition", "Распознавание")) {
                    Picker(L10n.text("Spoken language", "Язык речи"), selection: $settingsViewModel.settings.language) {
                        ForEach(DictationLanguage.allCases, id: \.self) { language in
                            Text(languageTitle(language)).tag(language)
                        }
                    }
                    Toggle(L10n.text("Translate to English", "Переводить на английский"), isOn: $settingsViewModel.settings.translateToEnglish)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("Custom words", "Пользовательские слова"))
                        TextEditor(text: customWordsText)
                            .font(.system(size: 12))
                            .frame(minHeight: 72)
                            .padding(5)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }

                Section(L10n.text("Local model", "Локальная модель")) {
                    if let option = TranscriptionModelOption.all.first {
                        LabeledContent(L10n.text("Installed model", "Установленная модель")) {
                            Label(option.title, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        LabeledContent(L10n.text("Performance", "Производительность")) {
                            Text("\(L10n.text("Metal accelerated", "Ускорение Metal")) • \(option.downloadSize)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Picker(L10n.text("Memory", "Память"), selection: $settingsViewModel.settings.modelMemoryPolicy) {
                        ForEach(ModelMemoryPolicy.allCases, id: \.self) { policy in
                            Text(memoryPolicyTitle(policy)).tag(policy)
                        }
                    }
                }

                Section(L10n.text("History & privacy", "История и конфиденциальность")) {
                    Picker(L10n.text("Keep recordings", "Хранить записи"), selection: $settingsViewModel.settings.audioRetention) {
                        ForEach(AudioRetentionPolicy.allCases, id: \.self) { policy in
                            Text(retentionTitle(policy)).tag(policy)
                        }
                    }
                    Stepper(value: $settingsViewModel.settings.historyLimit, in: 10...2_000, step: 10) {
                        LabeledContent(L10n.text("History limit", "Лимит истории")) {
                            Text("\(settingsViewModel.settings.historyLimit) \(L10n.text("dictations", "записей"))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(L10n.text(
                        "Recognized text stays on this Mac. Failed recordings remain available for retry until deleted.",
                        "Распознанный текст хранится на этом Mac. Неудачные записи доступны для повторной обработки до удаления."
                    ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(L10n.text("Permissions", "Разрешения")) {
                    permissionRow(title: L10n.text("Microphone", "Микрофон"), status: permissionsViewModel.snapshot.microphone, permission: .microphone)
                    permissionRow(title: L10n.text("Accessibility", "Универсальный доступ"), status: permissionsViewModel.snapshot.accessibility, permission: .accessibility)
                    permissionRow(title: L10n.text("Input Monitoring", "Мониторинг ввода"), status: permissionsViewModel.snapshot.inputMonitoring, permission: .inputMonitoring)
                    HStack {
                        Button(L10n.text("Request Missing Permissions", "Запросить недостающие разрешения")) { permissionsViewModel.requestPermissions() }
                        Button(L10n.text("Refresh", "Обновить")) { permissionsViewModel.refresh() }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if let message = settingsViewModel.errorMessage ?? settingsViewModel.launchAtLoginNotice {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("Save Changes", "Сохранить изменения")) { settingsViewModel.save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(settingsViewModel.isSaving)
            }
        }
        .controlSize(.regular)
        .padding(24)
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("Dictation settings", "Настройки диктовки"))
                .font(.title2.weight(.semibold))
            Text(L10n.text(
                "Control how Dictator listens, recognizes, and inserts text.",
                "Настройте, как Диктатор слушает, распознаёт и вставляет текст."
            ))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
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

    private var soundVolumeLabel: String {
        "\(Int((settingsViewModel.settings.feedbackSoundVolume * 100).rounded()))%"
    }

    private var soundVolumeSymbol: String {
        switch settingsViewModel.settings.feedbackSoundVolume {
        case ...0.001: "speaker.slash.fill"
        case ..<0.5: "speaker.wave.1.fill"
        default: "speaker.wave.2.fill"
        }
    }

    private func soundThemeTitle(_ theme: DictationSoundTheme) -> String {
        switch theme {
        case .glass: L10n.text("Glass", "Стекло")
        case .crystal: L10n.text("Crystal", "Кристалл")
        case .ripple: L10n.text("Ripple", "Рябь")
        case .softTap: L10n.text("Soft Tap", "Мягкий щелчок")
        case .bloom: L10n.text("Bloom", "Расцвет")
        case .pulse: L10n.text("Pulse", "Пульс")
        case .air: L10n.text("Air", "Воздух")
        case .wood: L10n.text("Wood", "Дерево")
        case .sonar: L10n.text("Sonar", "Сонар")
        case .bubble: L10n.text("Drop", "Капля")
        }
    }

    private func permissionRow(title: String, status: PermissionStatus, permission: PermissionKind) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Label(permissionStatusTitle(status),
                      systemImage: status == .authorized ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(status == .authorized ? .green : .orange)
                Button(L10n.text("Open…", "Открыть…")) { permissionsViewModel.openSystemSettings(for: permission) }
            }
        }
    }

    private func hotkeyTitle(_ kind: HotkeyKind) -> String {
        switch kind {
        case .rightCommandHold:
            return L10n.text("Hold Right Command", "Удерживать правый Command")
        case .optionSpaceHold:
            return L10n.text("Hold Option + Space", "Удерживать Option + Пробел")
        }
    }

    private func languageTitle(_ language: DictationLanguage) -> String {
        switch language {
        case .automatic: return L10n.text("Automatic", "Автоматически")
        case .russian: return L10n.text("Russian", "Русский")
        case .english: return L10n.text("English", "Английский")
        case .ukrainian: return L10n.text("Ukrainian", "Украинский")
        case .german: return L10n.text("German", "Немецкий")
        case .spanish: return L10n.text("Spanish", "Испанский")
        case .french: return L10n.text("French", "Французский")
        }
    }

    private func memoryPolicyTitle(_ policy: ModelMemoryPolicy) -> String {
        switch policy {
        case .keepLoaded: return L10n.text("Keep model ready", "Держать модель готовой")
        case .unloadAfterFiveMinutes: return L10n.text("Release after 5 minutes", "Освобождать через 5 минут")
        case .unloadAfterFifteenMinutes: return L10n.text("Release after 15 minutes", "Освобождать через 15 минут")
        case .unloadImmediately: return L10n.text("Release after every dictation", "Освобождать после каждой диктовки")
        }
    }

    private func retentionTitle(_ policy: AudioRetentionPolicy) -> String {
        switch policy {
        case .none: return L10n.text("Don't keep recordings", "Не хранить записи")
        case .oneDay: return L10n.text("Keep for 1 day", "Хранить 1 день")
        case .sevenDays: return L10n.text("Keep for 7 days", "Хранить 7 дней")
        case .forever: return L10n.text("Keep until deleted", "Хранить до удаления")
        }
    }

    private func permissionStatusTitle(_ status: PermissionStatus) -> String {
        switch status {
        case .authorized: return L10n.text("Ready", "Готово")
        case .denied: return L10n.text("Denied", "Запрещено")
        case .notDetermined: return L10n.text("Not requested", "Не запрошено")
        }
    }
}
