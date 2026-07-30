import Application
import Combine
import Domain
import Foundation

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var settings: AppSettings = .default
    @Published public private(set) var isSaving = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var launchAtLoginNotice: String?

    public var onSettingsSaved: ((AppSettings) -> Void)?

    private let loadSettingsUseCase: LoadSettingsUseCase
    private let updateSettingsUseCase: UpdateSettingsUseCase
    private let launchAtLoginService: LaunchAtLoginService
    private let soundFeedbackService: DictationSoundFeedbackService?

    public init(
        loadSettingsUseCase: LoadSettingsUseCase,
        updateSettingsUseCase: UpdateSettingsUseCase,
        launchAtLoginService: LaunchAtLoginService,
        soundFeedbackService: DictationSoundFeedbackService? = nil
    ) {
        self.loadSettingsUseCase = loadSettingsUseCase
        self.updateSettingsUseCase = updateSettingsUseCase
        self.launchAtLoginService = launchAtLoginService
        self.soundFeedbackService = soundFeedbackService

        Task { @MainActor in
            await self.load()
        }
    }

    public func load() async {
        do {
            let useCase = loadSettingsUseCase
            settings = try await useCase.execute()
            settings.launchAtLogin = launchAtLoginService.isEnabled()
            errorMessage = nil
            launchAtLoginNotice = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func save() {
        Task { @MainActor in
            isSaving = true
            defer { isSaving = false }

            do {
                let useCase = updateSettingsUseCase
                let currentSettings = settings
                try await useCase.execute(currentSettings)
                do {
                    try launchAtLoginService.setEnabled(currentSettings.launchAtLogin)
                    launchAtLoginNotice = currentSettings.launchAtLogin
                        ? L10n.text("Launch at login is enabled.", "Запуск при входе включён.")
                        : L10n.text("Launch at login is disabled.", "Запуск при входе выключен.")
                } catch let error as AppError {
                    launchAtLoginNotice = error.userFacingDescription
                } catch {
                    launchAtLoginNotice = error.localizedDescription
                }
                errorMessage = nil
                onSettingsSaved?(currentSettings)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func previewFeedbackSound() {
        soundFeedbackService?.playPreview(
            theme: settings.feedbackSoundTheme,
            volume: settings.feedbackSoundVolume
        )
    }
}
