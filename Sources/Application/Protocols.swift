import Domain
import Foundation

@MainActor
public protocol SpeechTranscriptionEngine {
    func prepareModel(
        named modelIdentifier: String,
        progressHandler: @escaping @Sendable (ModelPreparationStatus) -> Void
    ) async throws
    func unloadModel() async
    func transcribe(
        _ capturedAudio: CapturedAudio,
        partialHandler: @escaping @Sendable (TranscriptChunk) -> Void
    ) async throws -> FinalTranscript
}

/// A local engine whose decoding behaviour is controlled by Dictum settings.
@MainActor
public protocol ConfigurableLocalTranscriptionEngine: SpeechTranscriptionEngine {
    func updateSettings(
        language: DictationLanguage,
        customWords: [String],
        translateToEnglish: Bool
    )
}

/// Engines backed by an isolated worker can abort a wedged native decode
/// without taking the host app down with it.
@MainActor
public protocol CancellableSpeechTranscriptionEngine: SpeechTranscriptionEngine {
    func cancelCurrentTranscription() async
}

@MainActor
public protocol AudioCaptureService {
    func makeMeterStream() -> AsyncStream<AudioMeterFrame>
    func startRecording() async throws
    /// Excludes a short, app-generated output cue from the saved microphone
    /// stream without delaying the visual start of dictation.
    func suppressSystemFeedback(for duration: TimeInterval)
    func stopRecording() async throws -> CapturedAudio
    func cancelRecording() async
    /// Returns complete recordings left behind by an interrupted app process.
    /// Implementations that only keep ephemeral audio can use the default.
    func recoverPendingRecordings() async -> [CapturedAudio]
}

public extension AudioCaptureService {
    func suppressSystemFeedback(for duration: TimeInterval) {}
    func recoverPendingRecordings() async -> [CapturedAudio] { [] }
}

/// Short, optional audio cues that reinforce the visible dictation state.
/// A volume of zero is the accessible, fully silent mode.
@MainActor
public protocol DictationSoundFeedbackService {
    func playRecordingStarted(theme: DictationSoundTheme, volume: Double)
    func playProcessingStarted(theme: DictationSoundTheme, volume: Double)
    func playPreview(theme: DictationSoundTheme, volume: Double)
}

public extension DictationSoundFeedbackService {
    func playPreview(theme: DictationSoundTheme, volume: Double) {
        playRecordingStarted(theme: theme, volume: volume)
    }
}

/// Coordinates other media with a dictation without ever becoming a
/// prerequisite for recording. Implementations must be fast and best-effort.
@MainActor
public protocol BackgroundMediaPlaybackService: AnyObject {
    @discardableResult
    func pauseActivePlayback() -> Bool
    func resumePausedPlayback()
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
    func createRetainedAudioCopy(from archivedAudio: ArchivedAudio, for entryID: UUID) async throws -> ArchivedAudio
    func loadArchivedAudio(at path: String, duration: TimeInterval) async throws -> CapturedAudio
    /// Finds durable source recordings that were moved out of Pending before
    /// their history transaction could commit.
    func recoverArchivedRecordings() async -> [ArchivedAudio]
    func deleteArchivedAudio(at path: String) async
    func cleanupUnreferencedAudio(keepingPaths: Set<String>, olderThan cutoff: Date) async
}

public extension DictationAudioArchive {
    func recoverArchivedRecordings() async -> [ArchivedAudio] { [] }
    func cleanupUnreferencedAudio(keepingPaths: Set<String>, olderThan cutoff: Date) async {}
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
