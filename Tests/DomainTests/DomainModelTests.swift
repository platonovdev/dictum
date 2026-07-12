#if canImport(Testing)
import Domain
import Foundation
import Testing

@Test
func defaultSettingsFavorLocalAutopasteFlow() {
    #expect(AppSettings.default.modelIdentifier == "ggml-large-v3-turbo")
    #expect(AppSettings.default.hotkey.kind == .rightCommandHold)
    #expect(AppSettings.default.autoPaste)
    #expect(!AppSettings.default.launchAtLogin)
    #expect(AppSettings.default.language == .automatic)
    #expect(AppSettings.default.appendTrailingSpace)
    #expect(AppSettings.default.modelMemoryPolicy == .unloadAfterFiveMinutes)
    #expect(AppSettings.default.audioRetention == .sevenDays)
}

@Test
func settingsDecodeSafelyFromThePreviousSchema() throws {
    let json = """
    {
      "modelIdentifier": "small",
      "hotkey": { "kind": "rightCommandHold" },
      "autoPaste": true,
      "launchAtLogin": false,
      "overlayPosition": "topCenter",
      "cloudAPIKey": "",
      "cloudBaseURL": "https://api.openai.com",
      "cloudDurationThreshold": 20
    }
    """

    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

    #expect(settings.language == .automatic)
    #expect(settings.customWords.isEmpty)
    #expect(!settings.translateToEnglish)
    #expect(settings.appendTrailingSpace)
    #expect(settings.showOverlay)
    #expect(settings.modelMemoryPolicy == .unloadAfterFiveMinutes)
    #expect(settings.audioRetention == .sevenDays)
    #expect(settings.historyLimit == 200)
}

@Test
func modelMemoryPoliciesExposeTheIntendedIdleWindows() {
    #expect(ModelMemoryPolicy.keepLoaded.idleDuration == nil)
    #expect(ModelMemoryPolicy.unloadImmediately.idleDuration == .zero)
    #expect(ModelMemoryPolicy.unloadAfterFiveMinutes.idleDuration == .seconds(300))
    #expect(ModelMemoryPolicy.unloadAfterFifteenMinutes.idleDuration == .seconds(900))
}

@Test
func recordingRetentionPoliciesExpireOnlyWhenExpected() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let twoDaysAgo = now.addingTimeInterval(-172_800)

    #expect(!AudioRetentionPolicy.none.keepsAudio(startedAt: now, now: now))
    #expect(!AudioRetentionPolicy.oneDay.keepsAudio(startedAt: twoDaysAgo, now: now))
    #expect(AudioRetentionPolicy.sevenDays.keepsAudio(startedAt: twoDaysAgo, now: now))
    #expect(AudioRetentionPolicy.forever.keepsAudio(startedAt: twoDaysAgo, now: now))
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
