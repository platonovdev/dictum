#if canImport(Testing)
import Domain
import Foundation
import Testing

@Test
func defaultSettingsFavorLocalAutopasteFlow() {
    #expect(AppSettings.default.modelIdentifier == "openai_whisper-large-v3_turbo")
    #expect(AppSettings.default.hotkey.kind == .rightCommandHold)
    #expect(AppSettings.default.autoPaste)
    #expect(!AppSettings.default.launchAtLogin)
}

@Test
func missingPermissionsListEveryUnauthorizedCapability() {
    let snapshot = PermissionSnapshot(
        microphone: .authorized,
        accessibility: .denied,
        inputMonitoring: .notDetermined
    )

    #expect(snapshot.missingRequiredPermissions.isEmpty)
    #expect(snapshot.missingRecommendedPermissions == [.accessibility, .inputMonitoring])
}

@Test
func dictationHistoryEntryDecodesLegacyPayload() throws {
    let json = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "startedAt": "2026-03-23T00:00:00Z",
      "finishedAt": "2026-03-23T00:00:03Z",
      "transcript": "hello world",
      "duration": 3,
      "wordCount": 2,
      "language": "en",
      "status": "failed",
      "statusDetail": "transcription failed"
    }
    """

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let entry = try decoder.decode(DictationHistoryEntry.self, from: Data(json.utf8))

    #expect(entry.audioArtifactPath == nil)
    #expect(entry.retryCount == 0)
    #expect(entry.failureStage == nil)
    #expect(entry.wordCount == 2)
}

@Test
func dictationStatisticsCountOnlySuccessfulEntries() {
    let started = Date(timeIntervalSince1970: 1_700_000_000)
    let success = DictationHistoryEntry.make(
        id: UUID(),
        startedAt: started,
        finishedAt: started.addingTimeInterval(2),
        transcript: "hello world",
        duration: 2,
        language: "en",
        status: .inserted
    )
    let failed = DictationHistoryEntry.make(
        id: UUID(),
        startedAt: started,
        finishedAt: started.addingTimeInterval(1),
        transcript: "partial",
        duration: 1,
        language: nil,
        status: .failed,
        statusDetail: "oops",
        audioArtifactPath: "/tmp/test.wav",
        retryCount: 1,
        failureStage: .transcription
    )

    let stats = DictationStatistics.make(from: [success, failed])

    #expect(stats.totalDuration == 2)
    #expect(stats.totalWords == 2)
}
#endif
