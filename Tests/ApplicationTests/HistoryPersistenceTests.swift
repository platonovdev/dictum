#if canImport(Testing)
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
    #expect(entries.first?.audioArtifactPath == nil)
    #expect(entries.first?.retryCount == 1)
    #expect(await insertionService.insertedText == nil)
    #expect(await archive.deletedPaths == [audioURL.path])
}

private actor MockHistoryStore: DictationHistoryStore {
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

    func deleteArchivedAudio(at path: String) async {
        deletedPaths.append(path)
    }
}
#endif
