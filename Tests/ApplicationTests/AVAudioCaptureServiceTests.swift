#if canImport(Testing)
import AVFoundation
import Foundation
@testable import Infrastructure
import Testing

@Test
@MainActor
func recoveryRemovesHeaderOnlyPendingRecordings() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let emptyRecordingURL = directory.appendingPathComponent("empty.wav")
    try autoreleasepool {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        _ = try AVAudioFile(forWriting: emptyRecordingURL, settings: format.settings)
    }

    let service = AVAudioCaptureService(
        fileManager: .default,
        pendingDirectoryURL: directory
    )
    let recovered = await service.recoverPendingRecordings()

    #expect(recovered.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: emptyRecordingURL.path))
}

@Test
@MainActor
func cachedAudioEngineIsReusedOnlyForTheSameCompleteRoute() {
    let airPodsRoute = AudioCaptureRoute(
        inputDeviceID: 100,
        outputDeviceID: 94,
        inputSampleRate: 24_000,
        outputSampleRate: 44_100
    )
    let builtInRoute = AudioCaptureRoute(
        inputDeviceID: 71,
        outputDeviceID: 69,
        inputSampleRate: 48_000,
        outputSampleRate: 48_000
    )

    #expect(AVAudioCaptureService.canReuseEngine(
        hasEngine: true,
        preparedRoute: airPodsRoute,
        currentRoute: airPodsRoute
    ))
    #expect(!AVAudioCaptureService.canReuseEngine(
        hasEngine: true,
        preparedRoute: airPodsRoute,
        currentRoute: builtInRoute
    ))
    #expect(!AVAudioCaptureService.canReuseEngine(
        hasEngine: true,
        preparedRoute: airPodsRoute,
        currentRoute: nil
    ))
}

@Test
@MainActor
func staleAudioFormatsForceAnEngineRefresh() throws {
    let mono24k = try #require(AVAudioFormat(
        standardFormatWithSampleRate: 24_000,
        channels: 1
    ))
    let mono48k = try #require(AVAudioFormat(
        standardFormatWithSampleRate: 48_000,
        channels: 1
    ))

    #expect(AVAudioCaptureService.formatsAreCompatible(mono24k, mono24k))
    #expect(!AVAudioCaptureService.formatsAreCompatible(mono48k, mono24k))
}
#endif
