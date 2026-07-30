#if canImport(XCTest)
import AVFoundation
import Application
import Domain
import Foundation
import XCTest

final class RecoveryFlowXCTests: XCTestCase {
    @MainActor
    func testRecordingRestartsPreparationIfIdleUnloadWasAlreadyInFlight() async throws {
        var settings = AppSettings.default
        settings.modelMemoryPolicy = .unloadImmediately
        let engine = DelayedUnloadRecoverySpeechEngine()
        let history = RecoveryHistoryStore()
        let archive = try RecoveryArchive()
        defer { archive.removeTestDirectory() }
        let coordinator = makeCoordinator(
            engine: engine,
            settings: settings,
            history: history,
            archive: archive
        )

        await coordinator.prepare()
        for _ in 0..<30 where !engine.unloadStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(engine.unloadStarted)

        var states = coordinator.makeStateStream().makeAsyncIterator()
        _ = await states.next()
        await coordinator.handleHotkeyEvent(.pressedAt(200))
        guard case .recording = await states.next() else {
            return XCTFail("Recording should start while idle unload finishes.")
        }
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(engine.prepareCount, 2)
    }

    @MainActor
    func testPhysicalTapDurationIsNotInflatedByDelayedEventHandling() async throws {
        let history = RecoveryHistoryStore()
        let archive = try RecoveryArchive()
        defer { archive.removeTestDirectory() }
        let coordinator = makeCoordinator(
            engine: RecoverySpeechEngine(result: .success("Unused")),
            settings: .default,
            history: history,
            archive: archive
        )
        var states = coordinator.makeStateStream().makeAsyncIterator()
        _ = await states.next()

        await coordinator.handleHotkeyEvent(.pressedAt(100))
        _ = await states.next()
        // Simulate MainActor being busy much longer than the 250 ms gesture
        // threshold. The physical event itself was still a 50 ms tap.
        try await Task.sleep(for: .milliseconds(350))
        await coordinator.handleHotkeyEvent(.releasedAt(100.05))

        guard case .recording(_, let isHandsFree) = await states.next() else {
            return XCTFail("A delayed key-up should keep the tap recording active.")
        }
        XCTAssertTrue(isHandsFree)
    }

    @MainActor
    func testTranscriptionFailureKeepsAudioWhenSuccessfulRecordingRetentionIsDisabled() async throws {
        var settings = AppSettings.default
        settings.audioRetention = .none
        let history = RecoveryHistoryStore()
        let archive = try RecoveryArchive()
        defer { archive.removeTestDirectory() }
        let coordinator = makeCoordinator(
            engine: RecoverySpeechEngine(result: .failure(.transcriptionFailed("Expected failure"))),
            settings: settings,
            history: history,
            archive: archive
        )

        await coordinator.prepare()
        await coordinator.startDictation()
        try await Task.sleep(for: .milliseconds(30))
        await coordinator.stopDictation()

        let entries = history.allEntries()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.status, .failed)
        XCTAssertEqual(entry.failureStage, .transcription)
        XCTAssertTrue(entry.isRetryable)
        let deletedFileNames = await archive.deletedFileNames()
        XCTAssertEqual(deletedFileNames, ["original.wav"])
    }

    @MainActor
    func testRetryPreparesAnUnloadedModelAndUpdatesTheSameHistoryEntry() async throws {
        let archive = try RecoveryArchive()
        defer { archive.removeTestDirectory() }
        let audioURL = try archive.makeExistingAudio(named: "retry.m4a")
        let entryID = UUID()
        let original = DictationHistoryEntry.make(
            id: entryID,
            startedAt: Date(),
            transcript: "",
            duration: 2,
            language: nil,
            status: .failed,
            statusDetail: "Failed",
            audioArtifactPath: audioURL.path,
            failureStage: .transcription
        )
        let history = RecoveryHistoryStore(entries: [original])
        let engine = RecoverySpeechEngine(result: .success("Recovered text"))
        let coordinator = makeCoordinator(
            engine: engine,
            settings: .default,
            history: history,
            archive: archive
        )

        await coordinator.retryHistoryEntry(id: entryID)

        let entries = history.allEntries()
        let updated = try XCTUnwrap(entries.first)
        XCTAssertEqual(updated.id, entryID)
        XCTAssertEqual(updated.transcript, "Recovered text")
        XCTAssertEqual(updated.status, .savedWithoutInsertion)
        XCTAssertEqual(updated.retryCount, 1)
        let prepareCount = engine.prepareCount()
        XCTAssertEqual(prepareCount, 1)
    }

    @MainActor
    func testRetryRepairsHistoryWhenTheAudioFileHasDisappeared() async throws {
        let archive = try RecoveryArchive()
        defer { archive.removeTestDirectory() }
        let entryID = UUID()
        let missingPath = archive.directoryURL
            .appendingPathComponent("missing.m4a")
            .path
        let original = DictationHistoryEntry.make(
            id: entryID,
            startedAt: Date(),
            transcript: "",
            duration: 2,
            language: nil,
            status: .failed,
            statusDetail: "Failed",
            audioArtifactPath: missingPath,
            failureStage: .transcription
        )
        let history = RecoveryHistoryStore(entries: [original])
        let coordinator = makeCoordinator(
            engine: RecoverySpeechEngine(result: .success("Unused")),
            settings: .default,
            history: history,
            archive: archive
        )

        await coordinator.retryHistoryEntry(id: entryID)

        let entries = history.allEntries()
        let repaired = try XCTUnwrap(entries.first)
        XCTAssertNil(repaired.audioArtifactPath)
        XCTAssertEqual(repaired.status, .failed)
        XCTAssertEqual(repaired.failureStage, .persistence)
    }

    @MainActor
    func testColdLaunchPreparationDoesNotOverwriteAnActiveRecording() async throws {
        let history = RecoveryHistoryStore()
        let archive = try RecoveryArchive()
        defer { archive.removeTestDirectory() }
        let insertion = RecoveryTrackingInsertionService()
        let engine = SlowRecoverySpeechEngine()
        let coordinator = DictationSessionCoordinator(
            transcriptionEngine: engine,
            audioCaptureService: RecoveryAudioCapture(),
            insertionService: insertion,
            permissionService: RecoveryPermissionService(),
            settingsStore: RecoverySettingsStore(settings: .default),
            historyStore: history,
            audioArchive: archive
        )

        let preparation = Task { @MainActor in
            await coordinator.prepare()
        }
        try await Task.sleep(for: .milliseconds(20))
        await coordinator.startDictation()
        await preparation.value
        await coordinator.stopDictation()

        let insertedText = await insertion.insertedText()
        XCTAssertEqual(insertedText, "Cold launch survives ")
    }

    @MainActor
    func testPendingRecordingReferencedByHistoryIsNeverDeletedAsDuplicate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dictator-Pending-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let entryID = UUID()
        let pendingURL = directory.appendingPathComponent("\(entryID.uuidString).wav")
        try writeSilentRecoveryAudio(to: pendingURL)
        let entry = DictationHistoryEntry.make(
            id: entryID,
            startedAt: Date(),
            transcript: "",
            duration: 1,
            language: nil,
            status: .failed,
            statusDetail: "Interrupted",
            audioArtifactPath: pendingURL.path,
            failureStage: .audioCapture
        )
        let history = RecoveryHistoryStore(entries: [entry])
        let archive = try RecoveryArchive()
        defer { archive.removeTestDirectory() }
        let coordinator = makeCoordinator(
            engine: RecoverySpeechEngine(result: .success("Unused")),
            settings: .default,
            history: history,
            archive: archive,
            audioCapture: PendingRecoveryAudioCapture(
                recording: CapturedAudio(fileURL: pendingURL, duration: 1)
            )
        )

        await coordinator.prepare()

        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL.path))
        XCTAssertEqual(history.allEntries().first?.audioArtifactPath, pendingURL.path)
    }

    @MainActor
    func testArchivedWAVWithoutHistoryIsRecoveredOnLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dictator-Archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let entryID = UUID()
        let archivedURL = directory.appendingPathComponent("\(entryID.uuidString).wav")
        try writeSilentRecoveryAudio(to: archivedURL)
        let history = RecoveryHistoryStore()
        let archive = FileSystemDictationAudioArchive(
            fileManager: .default,
            archiveDirectoryURL: directory
        )
        let coordinator = DictationSessionCoordinator(
            transcriptionEngine: RecoverySpeechEngine(result: .success("Unused")),
            audioCaptureService: RecoveryAudioCapture(),
            insertionService: RecoveryInsertionService(),
            permissionService: RecoveryPermissionService(),
            settingsStore: RecoverySettingsStore(settings: .default),
            historyStore: history,
            audioArchive: archive
        )

        await coordinator.prepare()

        let recovered = try XCTUnwrap(history.allEntries().first)
        XCTAssertEqual(recovered.id, entryID)
        XCTAssertEqual(
            recovered.audioArtifactPath.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            },
            archivedURL.standardizedFileURL.path
        )
        XCTAssertEqual(recovered.failureStage, .transcription)
        XCTAssertTrue(recovered.isRetryable)
    }

    @MainActor
    func testRecoveryRowCommitsBeforeTranscriptionStarts() async throws {
        let history = RecoveryHistoryStore()
        let archive = try RecoveryArchive()
        defer { archive.removeTestDirectory() }
        let engine = RecoveryOrderingSpeechEngine(history: history)
        let coordinator = makeCoordinator(
            engine: engine,
            settings: .default,
            history: history,
            archive: archive
        )

        await coordinator.prepare()
        await coordinator.startDictation()
        await coordinator.stopDictation()

        XCTAssertTrue(engine.sawDurableRecoveryEntry)
        XCTAssertEqual(history.allEntries().count, 1)
        XCTAssertEqual(history.allEntries().first?.status, .inserted)
    }

    @MainActor
    private func makeCoordinator(
        engine: any SpeechTranscriptionEngine,
        settings: AppSettings,
        history: RecoveryHistoryStore,
        archive: any DictationAudioArchive,
        audioCapture: any AudioCaptureService = RecoveryAudioCapture()
    ) -> DictationSessionCoordinator {
        DictationSessionCoordinator(
            transcriptionEngine: engine,
            audioCaptureService: audioCapture,
            insertionService: RecoveryInsertionService(),
            permissionService: RecoveryPermissionService(),
            settingsStore: RecoverySettingsStore(settings: settings),
            historyStore: history,
            audioArchive: archive
        )
    }
}

@MainActor
private final class SlowRecoverySpeechEngine: SpeechTranscriptionEngine {
    func prepareModel(
        named modelIdentifier: String,
        progressHandler: @escaping @Sendable (ModelPreparationStatus) -> Void
    ) async throws {
        try await Task.sleep(for: .milliseconds(120))
    }

    func unloadModel() async {}

    func transcribe(
        _ capturedAudio: CapturedAudio,
        partialHandler: @escaping @Sendable (TranscriptChunk) -> Void
    ) async throws -> FinalTranscript {
        FinalTranscript(text: "Cold launch survives", duration: capturedAudio.duration, language: "en")
    }
}

@MainActor
private final class RecoveryOrderingSpeechEngine: SpeechTranscriptionEngine {
    private let history: RecoveryHistoryStore
    private(set) var sawDurableRecoveryEntry = false

    init(history: RecoveryHistoryStore) {
        self.history = history
    }

    func prepareModel(
        named modelIdentifier: String,
        progressHandler: @escaping @Sendable (ModelPreparationStatus) -> Void
    ) async throws {}

    func unloadModel() async {}

    func transcribe(
        _ capturedAudio: CapturedAudio,
        partialHandler: @escaping @Sendable (TranscriptChunk) -> Void
    ) async throws -> FinalTranscript {
        sawDurableRecoveryEntry = history.allEntries().contains { entry in
            entry.status == .failed
                && entry.failureStage == .transcription
                && entry.audioArtifactPath == capturedAudio.fileURL.path
                && entry.isRetryable
        }
        return FinalTranscript(text: "Committed first", duration: capturedAudio.duration, language: "en")
    }
}

@MainActor
private final class DelayedUnloadRecoverySpeechEngine: SpeechTranscriptionEngine {
    private(set) var prepareCount = 0
    private(set) var unloadStarted = false

    func prepareModel(
        named modelIdentifier: String,
        progressHandler: @escaping @Sendable (ModelPreparationStatus) -> Void
    ) async throws {
        prepareCount += 1
    }

    func unloadModel() async {
        unloadStarted = true
        try? await Task.sleep(for: .milliseconds(120))
    }

    func transcribe(
        _ capturedAudio: CapturedAudio,
        partialHandler: @escaping @Sendable (TranscriptChunk) -> Void
    ) async throws -> FinalTranscript {
        FinalTranscript(text: "", duration: capturedAudio.duration, language: nil)
    }
}

@MainActor
private final class RecoverySpeechEngine: SpeechTranscriptionEngine {
    private let result: Result<String, AppError>
    private var preparations = 0

    init(result: Result<String, AppError>) {
        self.result = result
    }

    func prepareModel(
        named modelIdentifier: String,
        progressHandler: @escaping @Sendable (ModelPreparationStatus) -> Void
    ) async throws {
        preparations += 1
    }

    func unloadModel() async {}

    func transcribe(
        _ capturedAudio: CapturedAudio,
        partialHandler: @escaping @Sendable (TranscriptChunk) -> Void
    ) async throws -> FinalTranscript {
        switch result {
        case .success(let text):
            partialHandler(.init(text: text, isFinal: true))
            return FinalTranscript(text: text, duration: capturedAudio.duration, language: "en")
        case .failure(let error):
            throw error
        }
    }

    func prepareCount() -> Int { preparations }
}

@MainActor
private final class RecoveryAudioCapture: AudioCaptureService {
    func makeMeterStream() -> AsyncStream<AudioMeterFrame> {
        AsyncStream { continuation in
            for _ in 0..<5 {
                continuation.yield(.init(
                    overallLevel: 0.5,
                    speechConfidence: 0.95,
                    isSpeechDetected: true,
                    frameDuration: 0.1,
                    bands: Array(repeating: 0.5, count: 15)
                ))
            }
            continuation.finish()
        }
    }

    func startRecording() async throws {}

    func stopRecording() async throws -> CapturedAudio {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try Data([1, 2, 3]).write(to: url)
        return CapturedAudio(fileURL: url, duration: 1)
    }

    func cancelRecording() async {}
}

@MainActor
private final class PendingRecoveryAudioCapture: AudioCaptureService {
    private let recording: CapturedAudio

    init(recording: CapturedAudio) {
        self.recording = recording
    }

    func makeMeterStream() -> AsyncStream<AudioMeterFrame> {
        AsyncStream { $0.finish() }
    }

    func startRecording() async throws {}
    func stopRecording() async throws -> CapturedAudio { recording }
    func cancelRecording() async {}
    func recoverPendingRecordings() async -> [CapturedAudio] { [recording] }
}

@MainActor
private final class RecoveryHistoryStore: DictationHistoryStore {
    private var entries: [DictationHistoryEntry]

    init(entries: [DictationHistoryEntry] = []) {
        self.entries = entries
    }

    func makeEntriesStream() -> AsyncStream<[DictationHistoryEntry]> {
        AsyncStream { continuation in
            continuation.yield(entries)
            continuation.finish()
        }
    }

    func loadEntries() async throws -> [DictationHistoryEntry] { entries }
    func append(_ entry: DictationHistoryEntry) async throws { entries.insert(entry, at: 0) }
    func update(_ entry: DictationHistoryEntry) async throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
    }
    func delete(id: UUID) async throws { entries.removeAll { $0.id == id } }
    func allEntries() -> [DictationHistoryEntry] { entries }
}

@MainActor
private final class RecoverySettingsStore: SettingsStore {
    private var settings: AppSettings
    init(settings: AppSettings) { self.settings = settings }
    func load() async throws -> AppSettings { settings }
    func save(_ settings: AppSettings) async throws { self.settings = settings }
}

private struct RecoveryPermissionService: PermissionService {
    func currentSnapshot() -> PermissionSnapshot {
        PermissionSnapshot(microphone: .authorized, accessibility: .authorized, inputMonitoring: .authorized)
    }
    func requestMissingPermissions() async -> PermissionSnapshot { currentSnapshot() }
    func openSystemSettings(for permission: PermissionKind) {}
}

private actor RecoveryInsertionService: TextInsertionService {
    func insert(text: String) async -> InsertionResult { .success }
}

private actor RecoveryTrackingInsertionService: TextInsertionService {
    private var text: String?

    func insert(text: String) async -> InsertionResult {
        self.text = text
        return .success
    }

    func insertedText() -> String? {
        text
    }
}

private final class RecoveryArchive: DictationAudioArchive, @unchecked Sendable {
    let directoryURL: URL
    private let lock = NSLock()
    private var deletedNames: [String] = []

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictumRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func archive(_ capturedAudio: CapturedAudio, for entryID: UUID) async throws -> ArchivedAudio {
        let destination = directoryURL.appendingPathComponent("original.wav")
        try FileManager.default.moveItem(at: capturedAudio.fileURL, to: destination)
        return ArchivedAudio(fileURL: destination, duration: capturedAudio.duration)
    }

    func createRetainedAudioCopy(from archivedAudio: ArchivedAudio, for entryID: UUID) async throws -> ArchivedAudio {
        let destination = directoryURL.appendingPathComponent("retained.m4a")
        try FileManager.default.copyItem(at: archivedAudio.fileURL, to: destination)
        return ArchivedAudio(fileURL: destination, duration: archivedAudio.duration)
    }

    func loadArchivedAudio(at path: String, duration: TimeInterval) async throws -> CapturedAudio {
        guard FileManager.default.fileExists(atPath: path) else {
            throw AppError.archivedAudioUnavailable(path)
        }
        return CapturedAudio(fileURL: URL(fileURLWithPath: path), duration: duration)
    }

    func deleteArchivedAudio(at path: String) async {
        try? FileManager.default.removeItem(atPath: path)
        lock.withLock {
            deletedNames.append(URL(fileURLWithPath: path).lastPathComponent)
        }
    }

    func makeExistingAudio(named name: String) throws -> URL {
        let url = directoryURL.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    func deletedFileNames() async -> [String] {
        lock.withLock { deletedNames }
    }

    func removeTestDirectory() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func writeSilentRecoveryAudio(to url: URL) throws {
    let format = try XCTUnwrap(
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
    )
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)
    )
    buffer.frameLength = 48_000
    if let channel = buffer.floatChannelData?[0] {
        channel.initialize(repeating: 0, count: 48_000)
    }
    try file.write(from: buffer)
}
#endif
