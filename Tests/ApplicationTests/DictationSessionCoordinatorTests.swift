#if canImport(Testing)
import Application
import Domain
import Foundation
@testable import Infrastructure
import Testing

@Test
@MainActor
func startDictationTransitionsToPermissionErrorWhenPermissionsMissing() async {
    let coordinator = DictationSessionCoordinator(
        transcriptionEngine: MockSpeechEngine(),
        audioCaptureService: MockAudioCaptureService(),
        insertionService: MockInsertionService(),
        permissionService: MockPermissionService(
            snapshot: PermissionSnapshot(
                microphone: .denied,
                accessibility: .denied,
                inputMonitoring: .authorized
            )
        ),
        settingsStore: MockSettingsStore(),
        historyStore: MockHistoryStore()
    )

    let states = coordinator.makeStateStream()

    var iterator = states.makeAsyncIterator()
    _ = await iterator.next()
    await coordinator.startDictation()
    let finalState = await iterator.next()

    #expect(finalState == .error(.permissionsMissing([.microphone])))
}

@Test
@MainActor
func stopDictationInsertsTranscriptWhenAutoPasteEnabled() async {
    let insertionService = MockInsertionService()
    let historyStore = MockHistoryStore()
    let archive = MockArchive()
    let coordinator = DictationSessionCoordinator(
        transcriptionEngine: MockSpeechEngine(finalText: "hello world"),
        audioCaptureService: MockAudioCaptureService(),
        insertionService: insertionService,
        permissionService: MockPermissionService(
            snapshot: PermissionSnapshot(
                microphone: .authorized,
                accessibility: .authorized,
                inputMonitoring: .authorized
            )
        ),
        settingsStore: MockSettingsStore(),
        historyStore: historyStore,
        audioArchive: archive
    )

    await coordinator.prepare()
    await coordinator.startDictation()
    await coordinator.stopDictation()

    let insertedText = await insertionService.insertedText
    let entries = await historyStore.entries
    #expect(insertedText == "hello world")
    #expect(entries.count == 1)
    #expect(entries.first?.transcript == "hello world")
    #expect(entries.first?.status == .inserted)
    #expect(entries.first?.audioArtifactPath == "/tmp/retained.m4a")
    #expect(await archive.deletedPaths == ["/tmp/original.wav"])
}

@Test
@MainActor
func stopDictationTreatsNoiseOnlyAsEmptyTranscript() async {
    let insertionService = MockInsertionService()
    let historyStore = MockHistoryStore()
    let coordinator = DictationSessionCoordinator(
        transcriptionEngine: MockSpeechEngine(finalText: "hallucinated"),
        audioCaptureService: MockAudioCaptureService(meterFrames: [
            AudioMeterFrame(
                overallLevel: 0.55,
                visualLevel: 0.42,
                speechConfidence: 0.08,
                isSpeechDetected: false,
                frameDuration: 0.12,
                bands: Array(repeating: 0.35, count: 9)
            ),
            AudioMeterFrame(
                overallLevel: 0.58,
                visualLevel: 0.40,
                speechConfidence: 0.10,
                isSpeechDetected: false,
                frameDuration: 0.12,
                bands: Array(repeating: 0.33, count: 9)
            ),
            AudioMeterFrame(
                overallLevel: 0.52,
                visualLevel: 0.38,
                speechConfidence: 0.05,
                isSpeechDetected: false,
                frameDuration: 0.12,
                bands: Array(repeating: 0.31, count: 9)
            )
        ]),
        insertionService: insertionService,
        permissionService: MockPermissionService(
            snapshot: PermissionSnapshot(
                microphone: .authorized,
                accessibility: .authorized,
                inputMonitoring: .authorized
            )
        ),
        settingsStore: MockSettingsStore(),
        historyStore: historyStore
    )

    await coordinator.prepare()
    await coordinator.startDictation()
    await coordinator.stopDictation()

    let entries = await historyStore.entries
    #expect(await insertionService.insertedText == nil)
    #expect(entries.count == 1)
    #expect(entries.first?.status == .emptyTranscript)
}

@Test
@MainActor
func holdToTalkStillStopsOnRelease() async {
    let insertionService = MockInsertionService()
    let coordinator = makeCoordinator(insertionService: insertionService)

    await coordinator.prepare()

    var iterator = coordinator.makeStateStream().makeAsyncIterator()
    _ = await iterator.next()

    await coordinator.handleHotkeyEvent(.pressed)
    let recordingState = await iterator.next()
    #expect(isRecording(recordingState))

    try? await Task.sleep(for: .milliseconds(300))
    await coordinator.handleHotkeyEvent(.released)

    let transcribingState = await iterator.next()
    let idleState = await iterator.next()

    #expect(isTranscribing(transcribingState))
    #expect(isIdle(idleState))
    #expect(await insertionService.insertedText == "hello world")
}

@Test
@MainActor
func quickDoublePressEnablesHandsFreeUntilNextPressStopsIt() async {
    let insertionService = MockInsertionService()
    let coordinator = makeCoordinator(insertionService: insertionService)

    await coordinator.prepare()

    var iterator = coordinator.makeStateStream().makeAsyncIterator()
    _ = await iterator.next()

    await coordinator.handleHotkeyEvent(.pressed)
    let recordingState = await iterator.next()
    #expect(isRecording(recordingState))

    await coordinator.handleHotkeyEvent(.released)
    try? await Task.sleep(for: .milliseconds(100))
    await coordinator.handleHotkeyEvent(.pressed)
    try? await Task.sleep(for: .milliseconds(450))

    #expect(await insertionService.insertedText == nil)

    await coordinator.handleHotkeyEvent(.pressed)
    let transcribingState = await iterator.next()
    let idleState = await iterator.next()

    #expect(isTranscribing(transcribingState))
    #expect(isIdle(idleState))
    #expect(await insertionService.insertedText == "hello world")
}

private func makeCoordinator(insertionService: MockInsertionService) -> DictationSessionCoordinator {
    DictationSessionCoordinator(
        transcriptionEngine: MockSpeechEngine(finalText: "hello world"),
        audioCaptureService: MockAudioCaptureService(),
        insertionService: insertionService,
        permissionService: MockPermissionService(
            snapshot: PermissionSnapshot(
                microphone: .authorized,
                accessibility: .authorized,
                inputMonitoring: .authorized
            )
        ),
        settingsStore: MockSettingsStore(),
        historyStore: MockHistoryStore()
    )
}

private func isRecording(_ state: DictationSessionState?) -> Bool {
    if case .recording = state {
        return true
    }
    return false
}

private func isTranscribing(_ state: DictationSessionState?) -> Bool {
    if case .transcribing = state {
        return true
    }
    return false
}

private func isIdle(_ state: DictationSessionState?) -> Bool {
    if case .idle = state {
        return true
    }
    return false
}

private actor MockSettingsStore: SettingsStore {
    func load() async throws -> AppSettings { .default }
    func save(_ settings: AppSettings) async throws {}
}

private actor MockHistoryStore: DictationHistoryStore {
    private(set) var entries: [DictationHistoryEntry] = []

    func makeEntriesStream() -> AsyncStream<[DictationHistoryEntry]> {
        AsyncStream { continuation in
            continuation.yield(entries)
            continuation.finish()
        }
    }

    func loadEntries() async throws -> [DictationHistoryEntry] { entries }

    func append(_ entry: DictationHistoryEntry) async throws {
        entries.insert(entry, at: 0)
    }

    func update(_ entry: DictationHistoryEntry) async throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            return
        }
        entries[index] = entry
    }

    func delete(id: UUID) async throws {
        entries.removeAll { $0.id == id }
    }
}

private actor MockSpeechEngine: SpeechTranscriptionEngine {
    private let finalText: String

    init(finalText: String = "test transcript") {
        self.finalText = finalText
    }

    func prepareModel(
        named modelIdentifier: String,
        progressHandler: @escaping @Sendable (ModelPreparationStatus) -> Void
    ) async throws {}

    func transcribe(
        _ capturedAudio: CapturedAudio,
        partialHandler: @escaping @Sendable (TranscriptChunk) -> Void
    ) async throws -> FinalTranscript {
        partialHandler(TranscriptChunk(text: finalText, isFinal: true))
        return FinalTranscript(text: finalText, duration: 1.0, language: "en")
    }
}

private final class MockAudioCaptureService: AudioCaptureService {
    private let meterFrames: [AudioMeterFrame]

    init(
        meterFrames: [AudioMeterFrame] = Array(
            repeating: AudioMeterFrame(
                overallLevel: 0.2,
                visualLevel: 0.24,
                speechConfidence: 0.92,
                isSpeechDetected: true,
                frameDuration: 0.1,
                bands: Array(repeating: 0.2, count: 9)
            ),
            count: 5
        )
    ) {
        self.meterFrames = meterFrames
    }

    func makeMeterStream() -> AsyncStream<AudioMeterFrame> {
        AsyncStream { continuation in
            meterFrames.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func startRecording() async throws {}

    func stopRecording() async throws -> CapturedAudio {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try Data([0x01, 0x02, 0x03]).write(to: url)
        return CapturedAudio(fileURL: url, duration: 1.0)
    }

    func cancelRecording() async {}
}

private actor MockInsertionService: TextInsertionService {
    private(set) var insertedText: String?

    func insert(text: String) async -> InsertionResult {
        insertedText = text
        return .success
    }
}

private actor MockArchive: DictationAudioArchive {
    private(set) var deletedPaths: [String] = []

    func archive(_ capturedAudio: CapturedAudio, for entryID: UUID) async throws -> ArchivedAudio {
        ArchivedAudio(fileURL: URL(fileURLWithPath: "/tmp/original.wav"), duration: capturedAudio.duration)
    }

    func createRetainedAudioCopy(from archivedAudio: ArchivedAudio, for entryID: UUID) async throws -> ArchivedAudio {
        ArchivedAudio(fileURL: URL(fileURLWithPath: "/tmp/retained.m4a"), duration: archivedAudio.duration)
    }

    func loadArchivedAudio(at path: String, duration: TimeInterval) async throws -> CapturedAudio {
        CapturedAudio(fileURL: URL(fileURLWithPath: path), duration: duration)
    }

    func deleteArchivedAudio(at path: String) async {
        deletedPaths.append(path)
    }
}

private struct MockPermissionService: PermissionService {
    let snapshot: PermissionSnapshot

    func currentSnapshot() -> PermissionSnapshot { snapshot }
    func requestMissingPermissions() async -> PermissionSnapshot { snapshot }
    func openSystemSettings(for permission: PermissionKind) {}
}
#endif
