import Domain
import Foundation

@MainActor
public protocol SpeechTranscriptionEngine {
    func prepareModel(
        named modelIdentifier: String,
        progressHandler: @escaping @Sendable (ModelPreparationStatus) -> Void
    ) async throws
    func transcribe(
        _ capturedAudio: CapturedAudio,
        partialHandler: @escaping @Sendable (TranscriptChunk) -> Void
    ) async throws -> FinalTranscript
}

@MainActor
public protocol AudioCaptureService {
    func makeMeterStream() -> AsyncStream<AudioMeterFrame>
    func startRecording() async throws
    func stopRecording() async throws -> CapturedAudio
    func cancelRecording() async
}

@MainActor
public protocol GlobalHotkeyService: AnyObject {
    func startListening(
        configuration: HotkeyConfiguration,
        handler: @escaping @Sendable (HotkeyEvent) -> Void
    ) throws
    func stopListening()
}

public protocol TextInsertionService: Sendable {
    func insert(text: String) async -> InsertionResult
}

public protocol ClipboardFallbackService: TextInsertionService {
    func copyToClipboard(text: String) async -> InsertionResult
}

public protocol ClipboardWriting: Sendable {
    func copy(text: String) async
}

@MainActor
public protocol PermissionService {
    func currentSnapshot() -> PermissionSnapshot
    func requestMissingPermissions() async -> PermissionSnapshot
    func openSystemSettings(for permission: PermissionKind)
}

@MainActor
public protocol SettingsStore {
    func load() async throws -> AppSettings
    func save(_ settings: AppSettings) async throws
}

@MainActor
public protocol DictationHistoryStore {
    func makeEntriesStream() -> AsyncStream<[DictationHistoryEntry]>
    func loadEntries() async throws -> [DictationHistoryEntry]
    func append(_ entry: DictationHistoryEntry) async throws
    func update(_ entry: DictationHistoryEntry) async throws
    func delete(id: UUID) async throws
}

public protocol DictationAudioArchive: Sendable {
    func archive(_ capturedAudio: CapturedAudio, for entryID: UUID) async throws -> ArchivedAudio
    func loadArchivedAudio(at path: String, duration: TimeInterval) async throws -> CapturedAudio
    func deleteArchivedAudio(at path: String) async
}

@MainActor
public protocol LaunchAtLoginService {
    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool) throws
}

@MainActor
public protocol DictationSessionCoordinating: AnyObject {
    func makeStateStream() -> AsyncStream<DictationSessionState>
    func makePartialTranscriptStream() -> AsyncStream<String>
    func makeMeterStream() -> AsyncStream<AudioMeterFrame>
    func makeHistoryStream() -> AsyncStream<[DictationHistoryEntry]>
    func loadHistoryEntries() async -> [DictationHistoryEntry]
    func handleHotkeyEvent(_ event: HotkeyEvent) async
    func prepare() async
    func reloadSettings() async
    func startDictation() async
    func stopDictation() async
    func resetSession() async
    func retryHistoryEntry(id: UUID) async
    func deleteHistoryEntry(id: UUID) async
}
