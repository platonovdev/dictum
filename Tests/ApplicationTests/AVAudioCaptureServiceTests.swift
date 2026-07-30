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
#endif
