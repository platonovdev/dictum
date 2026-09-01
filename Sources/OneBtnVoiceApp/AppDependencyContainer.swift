import Application
import Domain
import Infrastructure
import Presentation

@MainActor
final class AppDependencyContainer {
    let settingsStore = UserDefaultsSettingsStore()
    let historyStore = SQLiteDictationHistoryStore()
    let permissionService = SystemPermissionService()
    let audioCaptureService = AVAudioCaptureService()
    // Handy's whisper.cpp + Metal execution path is the default local engine.
    // Native Whisper/Metal work lives in a supervised helper so a decoder
    // crash or hang cannot freeze the menu bar app or lose the recording.
    let transcriptionEngine = IsolatedWhisperTranscriptionEngine()
    let hotkeyService = QuartzHotkeyService()
    let launchAtLoginService = SystemLaunchAtLoginService()
    let audioArchive = FileSystemDictationAudioArchive()
    let soundFeedbackService = BundledDictationSoundFeedbackService()
    let mediaPlaybackService = SystemMediaPlaybackService()
    let caretAnchorProvider = AccessibilityCaretAnchorProvider()

    let loadSettingsUseCase: LoadSettingsUseCase
    let updateSettingsUseCase: UpdateSettingsUseCase
    let requestPermissionsUseCase: RequestPermissionsUseCase
    let prepareModelUseCase: PrepareModelUseCase
    let coordinator: DictationSessionCoordinator
    let overlayViewModel: OverlayViewModel
    let settingsViewModel: SettingsViewModel
    let permissionsViewModel: PermissionsViewModel
    let historyViewModel: HistoryViewModel
    let statisticsViewModel: StatisticsViewModel
    let mainAppViewModel: MainAppViewModel

    init() {
        let accessibilityInsertion = AccessibilityTextInsertionService()
        let clipboardFallback = ClipboardPasteFallbackService()
        let textInsertionService = CompositeTextInsertionService(
            pasteboardInsertion: clipboardFallback,
            accessibilityInsertion: accessibilityInsertion
        )

        loadSettingsUseCase = LoadSettingsUseCase(settingsStore: settingsStore)
        updateSettingsUseCase = UpdateSettingsUseCase(settingsStore: settingsStore)
        requestPermissionsUseCase = RequestPermissionsUseCase(permissionService: permissionService)
        prepareModelUseCase = PrepareModelUseCase(
            settingsStore: settingsStore,
            transcriptionEngine: transcriptionEngine
        )

        coordinator = DictationSessionCoordinator(
            transcriptionEngine: transcriptionEngine,
            audioCaptureService: audioCaptureService,
            insertionService: textInsertionService,
            permissionService: permissionService,
            settingsStore: settingsStore,
            historyStore: historyStore,
            audioArchive: audioArchive,
            soundFeedbackService: soundFeedbackService,
            mediaPlaybackService: mediaPlaybackService
        )

        overlayViewModel = OverlayViewModel(coordinator: coordinator)
        settingsViewModel = SettingsViewModel(
            loadSettingsUseCase: loadSettingsUseCase,
            updateSettingsUseCase: updateSettingsUseCase,
            launchAtLoginService: launchAtLoginService,
            soundFeedbackService: soundFeedbackService
        )
        permissionsViewModel = PermissionsViewModel(
            permissionService: permissionService,
            requestPermissionsUseCase: requestPermissionsUseCase
        )
        historyViewModel = HistoryViewModel(
            coordinator: coordinator,
            clipboardWriter: clipboardFallback
        )
        statisticsViewModel = StatisticsViewModel(coordinator: coordinator)
        mainAppViewModel = MainAppViewModel(
            settingsViewModel: settingsViewModel,
            permissionsViewModel: permissionsViewModel,
            historyViewModel: historyViewModel,
            statisticsViewModel: statisticsViewModel
        )
    }
}
