@preconcurrency import AVFoundation
import Application
import CryptoKit
import Domain
import Foundation
@preconcurrency import whisper

/// Local Whisper implementation matching Handy's fast path: a quantized GGML
/// `large-v3-turbo` model running through whisper.cpp with Metal acceleration.
///
/// This deliberately avoids a separate language-classification pass. whisper.cpp
/// detects the spoken language as part of the same decode, which is both faster
/// and prevents Russian dictation from being forced through English.
@MainActor
public final class WhisperCppTranscriptionEngine: ConfigurableLocalTranscriptionEngine {
    private let modelStore = WhisperCppModelStore()
    private var context: WhisperCppContext?
    private var loadedModelURL: URL?
    private var language: DictationLanguage = .automatic
    private var customWords: [String] = []
    private var translateToEnglish = false

    public init() {}

    public func updateSettings(
        language: DictationLanguage,
        customWords: [String],
        translateToEnglish: Bool
    ) {
        self.language = language
        self.customWords = customWords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.translateToEnglish = translateToEnglish
    }

    public func prepareModel(
        named modelIdentifier: String,
        progressHandler: @escaping @Sendable (ModelPreparationStatus) -> Void
    ) async throws {
        let startedAt = Date()
        progressHandler(.init(
            title: "Checking local model",
            detail: "Looking for Whisper Turbo on this Mac.",
            progress: 0.08,
            startedAt: startedAt
        ))

        let modelURL = try await modelStore.modelURL(
            for: modelIdentifier,
            startedAt: startedAt,
            progressHandler: progressHandler
        )
        if loadedModelURL == modelURL, context != nil {
            return
        }

        await unloadModel()
        progressHandler(.init(
            title: "Loading Whisper Turbo",
            detail: "Starting the Metal-accelerated local model.",
            progress: 0.90,
            startedAt: startedAt
        ))
        // Loading and mapping a 1.6 GB GGML file must never occupy MainActor:
        // otherwise a physical key-up event waits behind model loading and a
        // quick tap can be misclassified as a long hold.
        let loadedContext = try await Task.detached(priority: .userInitiated) {
            try WhisperCppContext(modelURL: modelURL)
        }.value
        context = loadedContext
        loadedModelURL = modelURL
        progressHandler(.init(
            title: "Local model ready",
            detail: "Whisper Turbo is ready to transcribe offline.",
            progress: 1,
            startedAt: startedAt
        ))
    }

    public func unloadModel() async {
        context = nil
        loadedModelURL = nil
    }

    public func transcribe(
        _ capturedAudio: CapturedAudio,
        partialHandler: @escaping @Sendable (TranscriptChunk) -> Void
    ) async throws -> FinalTranscript {
        guard let context else {
            throw AppError.modelUnavailable
        }

        let samples = try Self.loadMono16kSamples(from: capturedAudio.fileURL)
        let startedAt = CFAbsoluteTimeGetCurrent()
        let result = try await context.transcribe(
            samples: samples,
            language: language.whisperCode,
            prompt: customWords.joined(separator: ", "),
            translateToEnglish: translateToEnglish
        )
        let transcriptionDuration = CFAbsoluteTimeGetCurrent() - startedAt
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        partialHandler(.init(text: text, isFinal: true))

        return FinalTranscript(
            text: text,
            duration: capturedAudio.duration,
            language: translateToEnglish ? "en" : result.language,
            backend: .local,
            transcriptionDuration: transcriptionDuration
        )
    }

    private static func loadMono16kSamples(from fileURL: URL) throws -> [Float] {
        let inputFile = try AVAudioFile(forReading: fileURL)
        let inputFormat = inputFile.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(inputFile.length)
        ) else {
            throw AppError.transcriptionFailed("Could not prepare recorded audio.")
        }

        try inputFile.read(into: inputBuffer)
        let expectedFrames = max(1, Int((Double(inputBuffer.frameLength) / inputFormat.sampleRate) * 16_000) + 64)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(expectedFrames)
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AppError.transcriptionFailed("Could not convert recorded audio.")
        }

        let conversionInput = ConversionInput(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            conversionInput.nextBuffer(status: outStatus)
        }
        guard status != .error, conversionError == nil, let channel = outputBuffer.floatChannelData else {
            throw AppError.transcriptionFailed("Could not convert recorded audio to Whisper format.")
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(outputBuffer.frameLength)))
    }
}

private final class ConversionInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var wasRead = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextBuffer(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        guard !wasRead else {
            status.pointee = .noDataNow
            return nil
        }
        wasRead = true
        status.pointee = .haveData
        return buffer
    }
}

private actor WhisperCppContext {
    private let handle: WhisperContextHandle

    init(modelURL: URL) throws {
        var parameters = whisper_context_default_params()
        parameters.use_gpu = true
        parameters.flash_attn = true
        guard let context = whisper_init_from_file_with_params(modelURL.path, parameters) else {
            throw AppError.modelUnavailable
        }
        self.handle = WhisperContextHandle(pointer: context)
    }

    deinit {
        whisper_free(handle.pointer)
    }

    func transcribe(
        samples: [Float],
        language: String?,
        prompt: String,
        translateToEnglish: Bool
    ) throws -> (text: String, language: String?) {
        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.print_realtime = false
        parameters.print_progress = false
        parameters.print_timestamps = false
        parameters.print_special = false
        parameters.translate = translateToEnglish
        parameters.no_context = true
        parameters.no_timestamps = true
        parameters.single_segment = false
        parameters.suppress_blank = true
        // In whisper.cpp `detect_language` means “detect only, then exit”.
        // For automatic *transcription* the language value must be `auto`.
        parameters.detect_language = false
        parameters.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

        let run: () -> Int32 = {
            samples.withUnsafeBufferPointer { samplesBuffer in
                let transcribe: (UnsafePointer<CChar>) -> Int32 = { languagePointer in
                    parameters.language = languagePointer
                    return whisper_full(self.handle.pointer, parameters, samplesBuffer.baseAddress, Int32(samplesBuffer.count))
                }

                if prompt.isEmpty {
                    return (language ?? "auto").withCString(transcribe)
                }

                return prompt.withCString { promptPointer in
                    parameters.initial_prompt = promptPointer
                    return (language ?? "auto").withCString(transcribe)
                }
            }
        }

        guard run() == 0 else {
            throw AppError.transcriptionFailed("Whisper Turbo could not process this recording.")
        }
        let text = (0..<whisper_full_n_segments(handle.pointer))
            .map { String(cString: whisper_full_get_segment_text(handle.pointer, $0)) }
            .joined(separator: " ")
        let detectedLanguage: String?
        if language == nil {
            let languageID = whisper_full_lang_id(handle.pointer)
            detectedLanguage = languageID >= 0 ? String(cString: whisper_lang_str(languageID)) : nil
        } else {
            detectedLanguage = language
        }
        return (text, detectedLanguage)
    }
}

private final class WhisperContextHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }
}

private actor WhisperCppModelStore {
    private let modelURL = URL(string: "https://blob.handy.computer/ggml-large-v3-turbo.bin")!
    private let fileName = "ggml-large-v3-turbo.bin"
    private let expectedSHA256 = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
    private let expectedSize: UInt64 = 1_624_555_275

    func modelURL(
        for modelIdentifier: String,
        startedAt: Date,
        progressHandler: @escaping @Sendable (ModelPreparationStatus) -> Void
    ) async throws -> URL {
        // Handy's production fast model is intentionally the only GGML option.
        // Other legacy Core ML identifiers are mapped here so existing settings
        // migrate without leaving the application in an unusable state.
        _ = modelIdentifier
        let destination = try storageDirectory().appendingPathComponent(fileName)
        let verificationMarker = destination.appendingPathExtension("verified")
        if Self.isVerifiedModel(
            at: destination,
            markerURL: verificationMarker,
            expectedSHA256: expectedSHA256,
            expectedSize: expectedSize
        ) {
            return destination
        }

        // This supports early builds which downloaded the same, verified model
        // before the marker was introduced. It costs one hash only once.
        if Self.isValidModel(
            at: destination,
            expectedSHA256: expectedSHA256,
            expectedSize: expectedSize
        ) {
            try expectedSHA256.write(to: verificationMarker, atomically: true, encoding: .utf8)
            return destination
        }

        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.removeItem(at: verificationMarker)
        progressHandler(.init(
            title: "Downloading Whisper Turbo",
            detail: "A one-time 1.55 GB download. It stays on this Mac and works offline afterwards.",
            progress: 0.10,
            startedAt: startedAt
        ))
        let (temporaryURL, response) = try await URLSession.shared.download(from: modelURL)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw AppError.modelUnavailable
        }

        progressHandler(.init(
            title: "Verifying local model",
            detail: "Checking the downloaded model before it is used.",
            progress: 0.88,
            startedAt: startedAt
        ))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        guard Self.isValidModel(
            at: destination,
            expectedSHA256: expectedSHA256,
            expectedSize: expectedSize
        ) else {
            try? FileManager.default.removeItem(at: destination)
            throw AppError.transcriptionFailed("The Whisper Turbo download did not pass its integrity check.")
        }
        try expectedSHA256.write(to: verificationMarker, atomically: true, encoding: .utf8)
        return destination
    }

    private func storageDirectory() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw AppError.modelUnavailable
        }
        let directory = applicationSupport
            .appendingPathComponent("Dictum", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private nonisolated static func isVerifiedModel(
        at url: URL,
        markerURL: URL,
        expectedSHA256: String,
        expectedSize: UInt64
    ) -> Bool {
        guard let marker = try? String(contentsOf: markerURL, encoding: .utf8),
              marker.trimmingCharacters(in: .whitespacesAndNewlines) == expectedSHA256,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.uint64Value == expectedSize else {
            return false
        }
        return true
    }

    private nonisolated static func isValidModel(
        at url: URL,
        expectedSHA256: String,
        expectedSize: UInt64
    ) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.uint64Value == expectedSize,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }

        var hash = SHA256()
        while autoreleasepool(invoking: {
            let data = try? handle.read(upToCount: 1_048_576)
            guard let data, !data.isEmpty else { return false }
            hash.update(data: data)
            return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == expectedSHA256
    }
}
