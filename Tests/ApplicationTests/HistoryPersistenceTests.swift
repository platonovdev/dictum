#if canImport(Testing)
import AVFoundation
import Application
import Domain
import Foundation
import Infrastructure
import Testing

@Test
@MainActor
func historyStoreSupportsStreamUpdateAndDelete() async throws {
    let suiteName = "com.onebtnvoice.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let store = UserDefaultsDictationHistoryStore(defaults: defaults)

    let stream = store.makeEntriesStream()
    var iterator = stream.makeAsyncIterator()

    let initial = await iterator.next()
    #expect(initial == [])

    let entryID = UUID()
    let entry = DictationHistoryEntry.make(
        id: entryID,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        transcript: "hello world",
        duration: 1.5,
        language: "en",
        status: .inserted
    )

    try await store.append(entry)
    let appended = await iterator.next()
    #expect(appended?.first == entry)

    let updated = DictationHistoryEntry.make(
        id: entryID,
        startedAt: entry.startedAt,
        finishedAt: entry.finishedAt.addingTimeInterval(1),
        transcript: "hello again",
        duration: 2.0,
        language: "en",
        status: .failed,
        statusDetail: "transcription failed",
        audioArtifactPath: "/tmp/example.wav",
        retryCount: 1,
        failureStage: .transcription
    )

    try await store.update(updated)
    let afterUpdate = await iterator.next()
    #expect(afterUpdate?.first?.transcript == "hello again")
    #expect(afterUpdate?.first?.retryCount == 1)
    #expect(afterUpdate?.first?.audioArtifactPath == "/tmp/example.wav")

    try await store.delete(id: entryID)
    let afterDelete = await iterator.next()
    #expect(afterDelete?.isEmpty == true)
}

@Test
@MainActor
func sqliteHistoryMigratesLegacyEntriesAndSurvivesReopen() async throws {
    let suiteName = "com.dictator.sqlite-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let databaseDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Dictator-SQLite-\(UUID().uuidString)", isDirectory: true)
    let databaseURL = databaseDirectory.appendingPathComponent("History.sqlite3")
    defer { try? FileManager.default.removeItem(at: databaseDirectory) }

    let legacyStore = UserDefaultsDictationHistoryStore(defaults: defaults)
    let legacyEntry = DictationHistoryEntry.make(
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        transcript: "legacy survives",
        duration: 2,
        language: "en",
        status: .inserted
    )
    try await legacyStore.append(legacyEntry)

    var store: SQLiteDictationHistoryStore? = SQLiteDictationHistoryStore(
        databaseURL: databaseURL,
        legacyStore: legacyStore
    )
    let migrated = try await store?.loadEntries()
    #expect(migrated == [legacyEntry])

    let newEntry = DictationHistoryEntry.make(
        startedAt: Date(timeIntervalSince1970: 1_700_000_100),
        transcript: "transactional row",
        duration: 3,
        language: "en",
        status: .savedWithoutInsertion
    )
    try await store?.append(newEntry)
    #expect(try await store?.loadEntries() == [newEntry, legacyEntry])
    store = nil

    let reopened = SQLiteDictationHistoryStore(
        databaseURL: databaseURL,
        legacyStore: legacyStore
    )
    let afterReopen = try await reopened.loadEntries()
    #expect(afterReopen == [newEntry, legacyEntry])
    #expect(try await legacyStore.loadEntries() == [legacyEntry])
}

@Test
@MainActor
func fileSystemArchiveCopiesLoadsAndDeletesAudio() async throws {
    let archive = FileSystemDictationAudioArchive()
    let sourceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("wav")
    try Data([0x01, 0x02, 0x03]).write(to: sourceURL)
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    let entryID = UUID()
    let archived = try await archive.archive(
        CapturedAudio(fileURL: sourceURL, duration: 3.25),
        for: entryID
    )

    #expect(FileManager.default.fileExists(atPath: archived.fileURL.path))

    let loaded = try await archive.loadArchivedAudio(
        at: archived.fileURL.path,
        duration: 3.25
    )
    #expect(loaded.fileURL == archived.fileURL)
    #expect(loaded.duration == 3.25)

    await archive.deleteArchivedAudio(at: archived.fileURL.path)
    #expect(!FileManager.default.fileExists(atPath: archived.fileURL.path))
}

@Test
@MainActor
func retainedCompressionKeepsApproximateDuration() async throws {
    let archive = FileSystemDictationAudioArchive()
    let sourceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("wav")
    try writeSilentAudioFile(to: sourceURL, duration: 1.25, sampleRate: 48_000)
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    let retained = try await archive.createRetainedAudioCopy(
        from: ArchivedAudio(fileURL: sourceURL, duration: 1.25),
        for: UUID()
    )
    defer { try? FileManager.default.removeItem(at: retained.fileURL) }

    let retainedFile = try AVAudioFile(forReading: retained.fileURL)
    let retainedDuration = Double(retainedFile.length) / retainedFile.processingFormat.sampleRate

    #expect(abs(retainedDuration - 1.25) < 0.15)
}

@Test
@MainActor
func coordinatorRetryUpdatesTheSameHistoryEntry() async throws {
    let entryID = UUID()
    let audioURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("wav")
    try Data([0x01, 0x02, 0x03]).write(to: audioURL)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let failedEntry = DictationHistoryEntry.make(
        id: entryID,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        finishedAt: Date(timeIntervalSince1970: 1_700_000_004),
        transcript: "partial",
        duration: 4.0,
        language: nil,
        status: .failed,
        statusDetail: "transcription failed",
        audioArtifactPath: audioURL.path,
        retryCount: 0,
        failureStage: .transcription
    )

    let historyStore = MockHistoryStore(entries: [failedEntry])
    let archive = MockRetryArchive(audioURL: audioURL)
    let insertionService = MockInsertionService()
    let coordinator = DictationSessionCoordinator(
        transcriptionEngine: MockSpeechEngine(finalText: "retried transcript"),
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

    await coordinator.retryHistoryEntry(id: entryID)

    let entries = await historyStore.entries
    #expect(entries.count == 1)
    #expect(entries.first?.id == entryID)
    #expect(entries.first?.transcript == "retried transcript")
    #expect(entries.first?.status == .savedWithoutInsertion)
    #expect(entries.first?.audioArtifactPath == audioURL.path)
    #expect(entries.first?.retryCount == 1)
    #expect(await insertionService.insertedText == nil)
    #expect(await archive.deletedPaths.isEmpty)
}

@MainActor
private final class MockHistoryStore: DictationHistoryStore {
    private(set) var entries: [DictationHistoryEntry]

    init(entries: [DictationHistoryEntry] = []) {
        self.entries = entries
    }

    func makeEntriesStream() -> AsyncStream<[DictationHistoryEntry]> {
        AsyncStream { continuation in
            continuation.yield(entries)
            continuation.finish()
        }
    }

    func loadEntries() async throws -> [DictationHistoryEntry] {
        entries
    }

    func append(_ entry: DictationHistoryEntry) async throws {
        entries.insert(entry, at: 0)
    }

    func update(_ entry: DictationHistoryEntry) async throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            throw AppError.historyEntryNotFound(entry.id)
        }
        entries[index] = entry
    }

    func delete(id: UUID) async throws {
        entries.removeAll { $0.id == id }
    }
}

private actor MockRetryArchive: DictationAudioArchive {
    let audioURL: URL
    private(set) var deletedPaths: [String] = []

    init(audioURL: URL) {
        self.audioURL = audioURL
    }

    func archive(_ capturedAudio: CapturedAudio, for entryID: UUID) async throws -> ArchivedAudio {
        ArchivedAudio(fileURL: audioURL, duration: capturedAudio.duration)
    }

    func loadArchivedAudio(at path: String, duration: TimeInterval) async throws -> CapturedAudio {
        CapturedAudio(fileURL: audioURL, duration: duration)
    }

    func createRetainedAudioCopy(from archivedAudio: ArchivedAudio, for entryID: UUID) async throws -> ArchivedAudio {
        archivedAudio
    }

    func deleteArchivedAudio(at path: String) async {
        deletedPaths.append(path)
    }
}

private func writeSilentAudioFile(to url: URL, duration: TimeInterval, sampleRate: Double) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let frameCount = AVAudioFrameCount(duration * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount

    if let channelData = buffer.floatChannelData {
        channelData[0].initialize(repeating: 0, count: Int(frameCount))
    }

    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}
#endif
