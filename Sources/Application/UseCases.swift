import Domain
import Foundation

@MainActor
public struct PrepareModelUseCase {
    private let settingsStore: SettingsStore
    private let transcriptionEngine: SpeechTranscriptionEngine

    public init(settingsStore: SettingsStore, transcriptionEngine: SpeechTranscriptionEngine) {
        self.settingsStore = settingsStore
        self.transcriptionEngine = transcriptionEngine
    }

    public func execute() async throws {
        let settings = try await settingsStore.load()
        try await transcriptionEngine.prepareModel(named: settings.modelIdentifier) { _ in }
    }
}

@MainActor
public struct LoadSettingsUseCase {
    private let settingsStore: SettingsStore

    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    public func execute() async throws -> AppSettings {
        try await settingsStore.load()
    }
}

@MainActor
public struct UpdateSettingsUseCase {
    private let settingsStore: SettingsStore

    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    public func execute(_ settings: AppSettings) async throws {
        try await settingsStore.save(settings)
    }
}

@MainActor
public struct RequestPermissionsUseCase {
    private let permissionService: PermissionService

    public init(permissionService: PermissionService) {
        self.permissionService = permissionService
    }

    public func execute() async -> PermissionSnapshot {
        await permissionService.requestMissingPermissions()
    }
}

@MainActor
public struct InsertTranscriptUseCase {
    private let insertionService: TextInsertionService

    public init(insertionService: TextInsertionService) {
        self.insertionService = insertionService
    }

    public func execute(_ transcript: FinalTranscript) async -> InsertionResult {
        await insertionService.insert(text: transcript.text)
    }
}

@MainActor
public struct StartDictationUseCase {
    private weak var coordinator: DictationSessionCoordinating?

    public init(coordinator: DictationSessionCoordinating) {
        self.coordinator = coordinator
    }

    public func execute() async {
        await coordinator?.startDictation()
    }
}

@MainActor
public struct StopDictationUseCase {
    private weak var coordinator: DictationSessionCoordinating?

    public init(coordinator: DictationSessionCoordinating) {
        self.coordinator = coordinator
    }

    public func execute() async {
        await coordinator?.stopDictation()
    }
}
