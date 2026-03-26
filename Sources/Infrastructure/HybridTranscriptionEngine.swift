import Application
import Domain
import Foundation

@MainActor
public final class HybridTranscriptionEngine: SpeechTranscriptionEngine {
    private let localEngine: WhisperKitTranscriptionEngine
    private let cloudEngine: CloudTranscriptionEngine
    private var durationThreshold: TimeInterval

    public init(
        localEngine: WhisperKitTranscriptionEngine,
        cloudEngine: CloudTranscriptionEngine,
        durationThreshold: TimeInterval = 20.0
    ) {
        self.localEngine = localEngine
        self.cloudEngine = cloudEngine
        self.durationThreshold = durationThreshold
    }

    public func updateSettings(apiKey: String, baseURL: String, durationThreshold: TimeInterval) {
        cloudEngine.updateConfiguration(apiKey: apiKey, baseURL: baseURL)
        self.durationThreshold = durationThreshold
    }

    public func prepareModel(
        named modelIdentifier: String,
        progressHandler: @escaping @Sendable (ModelPreparationStatus) -> Void
    ) async throws {
        try await localEngine.prepareModel(named: modelIdentifier, progressHandler: progressHandler)
    }

    public func transcribe(
        _ capturedAudio: CapturedAudio,
        partialHandler: @escaping @Sendable (TranscriptChunk) -> Void
    ) async throws -> FinalTranscript {
        let useCloud = cloudEngine.apiKey.isEmpty == false && capturedAudio.duration > durationThreshold

        if useCloud {
            do {
                return try await cloudEngine.transcribe(capturedAudio, partialHandler: partialHandler)
            } catch {
                partialHandler(TranscriptChunk(text: "Cloud failed, falling back to local…", isFinal: false))
                var result = try await localEngine.transcribe(capturedAudio, partialHandler: partialHandler)
                result.backend = .cloudWithLocalFallback
                return result
            }
        } else {
            return try await localEngine.transcribe(capturedAudio, partialHandler: partialHandler)
        }
    }
}
