import Application
import Domain
import Foundation
#if canImport(WhisperKit)
@preconcurrency import WhisperKit
#endif

@MainActor
public final class WhisperKitTranscriptionEngine: SpeechTranscriptionEngine {
    private static let preferredDictationLanguage = "ru"

    #if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    private var loadedModelIdentifier: String?
    #endif

    public init() {}

    public func prepareModel(
        named modelIdentifier: String,
        progressHandler: @escaping @Sendable (ModelPreparationStatus) -> Void
    ) async throws {
        #if canImport(WhisperKit)
        if loadedModelIdentifier == modelIdentifier, whisperKit != nil {
            return
        }

        let startedAt = Date()
        progressHandler(
            ModelPreparationStatus(
                title: "Checking local model",
                detail: "Looking for an already downloaded model on this Mac.",
                progress: 0.05,
                startedAt: startedAt
            )
        )

        let downloadProgressCallback: @Sendable (Progress) -> Void = { progress in
                let fraction = progress.totalUnitCount > 0 ? progress.fractionCompleted : 0.0
                let normalized = min(max(0.08 + (fraction * 0.62), 0.08), 0.70)
                progressHandler(
                    ModelPreparationStatus(
                        title: "Downloading local model",
                        detail: "First launch can take a few minutes while model files are downloaded.",
                        progress: normalized,
                        startedAt: startedAt
                    )
                )
        }

        let modelFolder = try await WhisperKit.download(
            variant: modelIdentifier,
            progressCallback: downloadProgressCallback
        )

        let configuration = WhisperKitConfig(
            model: modelIdentifier,
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: false,
            load: false,
            download: false
        )
        let kit = try await WhisperKit(configuration)

        kit.modelStateCallback = { _, newState in
            let mapped: (String, String, Double?) = switch newState {
            case .downloading:
                (
                    "Downloading local model",
                    "Model files are being downloaded for offline dictation.",
                    0.45
                )
            case .downloaded:
                (
                    "Model downloaded",
                    "Files are ready. Preparing them for this Mac.",
                    0.72
                )
            case .prewarming:
                (
                    "Optimizing for this Mac",
                    "Core ML is specializing the model for your chip. This is normal on first launch.",
                    0.82
                )
            case .prewarmed:
                (
                    "Optimization complete",
                    "Finishing the local setup.",
                    0.9
                )
            case .loading:
                (
                    "Loading local model",
                    "Starting the speech model in memory.",
                    0.95
                )
            case .loaded:
                (
                    "Local model ready",
                    "You can start dictating now.",
                    1.0
                )
            case .unloading:
                (
                    "Refreshing model",
                    "Switching to the selected local model.",
                    nil
                )
            case .unloaded:
                (
                    "Preparing local model",
                    "Getting the model ready for use.",
                    0.75
                )
            }

            progressHandler(
                ModelPreparationStatus(
                    title: mapped.0,
                    detail: mapped.1,
                    progress: mapped.2,
                    startedAt: startedAt
                )
            )
        }

        progressHandler(
            ModelPreparationStatus(
                title: "Optimizing for this Mac",
                detail: "Core ML may compile and specialize the model on the first run.",
                progress: 0.8,
                startedAt: startedAt
            )
        )
        try await kit.prewarmModels()

        progressHandler(
            ModelPreparationStatus(
                title: "Loading local model",
                detail: "Almost done. Starting the model in memory.",
                progress: 0.95,
                startedAt: startedAt
            )
        )
        try await kit.loadModels()

        whisperKit = kit
        loadedModelIdentifier = modelIdentifier
        #else
        throw AppError.modelUnavailable
        #endif
    }

    public func transcribe(
        _ capturedAudio: CapturedAudio,
        partialHandler: @escaping @Sendable (TranscriptChunk) -> Void
    ) async throws -> FinalTranscript {
        #if canImport(WhisperKit)
        guard let whisperKit else {
            throw AppError.modelUnavailable
        }

        let decodeOptions = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: Self.preferredDictationLanguage,
            temperature: 0,
            usePrefillPrompt: true,
            usePrefillCache: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            chunkingStrategy: .vad
        )
        let callback: @Sendable (TranscriptionProgress) -> Bool? = { progress in
            let partial = progress.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty {
                partialHandler(TranscriptChunk(text: partial, isFinal: false))
            }
            return true
        }

        let results = try await whisperKit.transcribe(
            audioPath: capturedAudio.fileURL.path,
            decodeOptions: decodeOptions,
            callback: callback
        )
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        partialHandler(TranscriptChunk(text: text, isFinal: true))

        return FinalTranscript(
            text: text,
            duration: capturedAudio.duration,
            language: Self.preferredDictationLanguage
        )
        #else
        throw AppError.modelUnavailable
        #endif
    }
}
