import AVFoundation
import Application
import Domain
import Foundation
import OSLog

@MainActor
public final class CloudTranscriptionEngine: SpeechTranscriptionEngine {
    private static let modelIdentifier = "gpt-4o-mini-transcribe"
    private let logger = Logger(subsystem: "com.dictum.app", category: "CloudTranscription")

    public private(set) var apiKey: String
    private var baseURL: String
    private var language: DictationLanguage = .automatic

    public init(apiKey: String = "", baseURL: String = "https://api.openai.com") {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    public func updateConfiguration(apiKey: String, baseURL: String, language: DictationLanguage) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.language = language
    }

    public func prepareModel(
        named modelIdentifier: String,
        progressHandler: @escaping @Sendable (ModelPreparationStatus) -> Void
    ) async throws {
        progressHandler(
            ModelPreparationStatus(
                title: "Cloud transcription ready",
                detail: "Audio will be sent to the cloud API for transcription.",
                progress: 1.0
            )
        )
    }

    public func unloadModel() async {}

    public func transcribe(
        _ capturedAudio: CapturedAudio,
        partialHandler: @escaping @Sendable (TranscriptChunk) -> Void
    ) async throws -> FinalTranscript {
        guard !apiKey.isEmpty else {
            throw AppError.transcriptionFailed("Cloud API key is not configured.")
        }

        let url = URL(string: "\(baseURL)/v1/audio/transcriptions")!

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180

        partialHandler(TranscriptChunk(text: "Compressing audio…", isFinal: false))

        let compressionStart = CFAbsoluteTimeGetCurrent()
        let compressedURL: URL
        do {
            compressedURL = try temporaryCompressedM4A(from: capturedAudio.fileURL)
        } catch {
            throw AppError.transcriptionFailed("Could not compress audio for cloud transcription: \(error.localizedDescription)")
        }
        let compressionDuration = CFAbsoluteTimeGetCurrent() - compressionStart
        defer { try? FileManager.default.removeItem(at: compressedURL) }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: compressedURL)
        } catch {
            throw AppError.transcriptionFailed("Could not read compressed audio file: \(error.localizedDescription)")
        }
        let fileName = compressedURL.lastPathComponent
        let mimeType = "audio/mp4"
        let fileSizeBytes = audioData.count

        var body = Data()
        appendFormField(&body, boundary: boundary, name: "model", value: Self.modelIdentifier)
        if let languageCode = language.whisperCode {
            appendFormField(&body, boundary: boundary, name: "language", value: languageCode)
        }
        appendFormField(&body, boundary: boundary, name: "response_format", value: "text")
        appendFormField(&body, boundary: boundary, name: "stream", value: "true")
        appendFileField(&body, boundary: boundary, name: "file", fileName: fileName, mimeType: mimeType, data: audioData)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        partialHandler(TranscriptChunk(text: "Uploading \(formattedBytes(fileSizeBytes)) to cloud…", isFinal: false))

        let transcriptionStart = CFAbsoluteTimeGetCurrent()
        let requestStart = transcriptionStart

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw AppError.transcriptionFailed("Cloud API request failed: \(error.localizedDescription)")
        }
        let responseHeadersDuration = CFAbsoluteTimeGetCurrent() - requestStart

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.transcriptionFailed("Invalid response from cloud API.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = try await collectResponseText(from: bytes)
            throw AppError.transcriptionFailed("Cloud API error (\(httpResponse.statusCode)): \(errorBody)")
        }

        partialHandler(TranscriptChunk(text: "Transcribing in cloud…", isFinal: false))

        let requestID = httpResponse.value(forHTTPHeaderField: "x-request-id") ?? "-"
        let streamed = try await consumeStreamingResponse(
            bytes: bytes,
            partialHandler: partialHandler
        )
        let transcriptionDuration = CFAbsoluteTimeGetCurrent() - transcriptionStart
        let firstDeltaDuration = streamed.firstDeltaAt.map { $0 - requestStart } ?? transcriptionDuration
        let text = streamed.text.trimmingCharacters(in: .whitespacesAndNewlines)

        logger.info(
            "Cloud transcription completed model=\(Self.modelIdentifier, privacy: .public) request_id=\(requestID, privacy: .public) source_duration_s=\(capturedAudio.duration, format: .fixed(precision: 2)) compressed_bytes=\(fileSizeBytes) compress_ms=\(Int(compressionDuration * 1000)) response_headers_ms=\(Int(responseHeadersDuration * 1000)) first_delta_ms=\(Int(firstDeltaDuration * 1000)) total_ms=\(Int(transcriptionDuration * 1000))"
        )

        partialHandler(TranscriptChunk(text: text, isFinal: true))

        return FinalTranscript(
            text: text,
            duration: capturedAudio.duration,
            language: language.whisperCode,
            backend: .cloud,
            transcriptionDuration: transcriptionDuration
        )
    }

    private func consumeStreamingResponse(
        bytes: URLSession.AsyncBytes,
        partialHandler: @escaping @Sendable (TranscriptChunk) -> Void
    ) async throws -> StreamedTranscript {
        var eventName: String?
        var dataLines: [String] = []
        var accumulatedText = ""
        var rawResponseLines: [String] = []
        var firstDeltaAt: CFAbsoluteTime?
        var sawStreamEvent = false

        func flushCurrentEvent() {
            let data = dataLines.joined(separator: "\n")
            defer {
                eventName = nil
                dataLines.removeAll(keepingCapacity: true)
            }

            guard !data.isEmpty else {
                return
            }

            sawStreamEvent = true

            switch Self.parseStreamEvent(name: eventName, data: data) {
            case .delta(let delta):
                guard !delta.isEmpty else {
                    return
                }
                accumulatedText += delta
                if firstDeltaAt == nil {
                    firstDeltaAt = CFAbsoluteTimeGetCurrent()
                }
                partialHandler(TranscriptChunk(text: accumulatedText, isFinal: false))
            case .done(let fullText):
                accumulatedText = fullText
            case .ignore:
                return
            case .none:
                return
            }
        }

        for try await line in bytes.lines {
            if !line.isEmpty {
                rawResponseLines.append(line)
            }

            if line.isEmpty {
                flushCurrentEvent()
                continue
            }

            if let stripped = line.removingPrefix("event:") {
                eventName = stripped.trimmingCharacters(in: .whitespaces)
                continue
            }

            if let stripped = line.removingPrefix("data:") {
                dataLines.append(stripped.trimmingCharacters(in: .whitespaces))
            }
        }

        flushCurrentEvent()

        if !accumulatedText.isEmpty {
            return StreamedTranscript(text: accumulatedText, firstDeltaAt: firstDeltaAt)
        }

        if !sawStreamEvent {
            let plainText = rawResponseLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty {
                return StreamedTranscript(text: plainText, firstDeltaAt: nil)
            }
        }

        throw AppError.transcriptionFailed("Cloud API returned an empty transcript stream.")
    }

    private func collectResponseText(from bytes: URLSession.AsyncBytes) async throws -> String {
        var lines: [String] = []
        for try await line in bytes.lines {
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func parseStreamEvent(name: String?, data: String) -> StreamEvent? {
        guard data != "[DONE]" else {
            return .ignore
        }

        let payloadText = extractPayloadText(from: data)

        switch name {
        case "transcript.text.delta":
            return .delta(payloadText)
        case "transcript.text.done":
            return .done(payloadText)
        default:
            return nil
        }
    }

    private static func extractPayloadText(from data: String) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else {
            return data
        }

        if let delta = json["delta"] as? String {
            return delta
        }

        if let text = json["text"] as? String {
            return text
        }

        if let transcript = json["transcript"] as? String {
            return transcript
        }

        return data
    }

    private func appendFormField(_ body: inout Data, boundary: String, name: String, value: String) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }

    private func appendFileField(_ body: inout Data, boundary: String, name: String, fileName: String, mimeType: String, data: Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }

    private func temporaryCompressedM4A(from sourceURL: URL) throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try AudioCompression.compressToM4A(sourceURL: sourceURL, outputURL: outputURL)
        return outputURL
    }

    private func formattedBytes(_ byteCount: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(byteCount))
    }
}

extension CloudTranscriptionEngine {
    enum StreamEvent: Equatable {
        case delta(String)
        case done(String)
        case ignore
    }

    struct StreamedTranscript {
        let text: String
        let firstDeltaAt: CFAbsoluteTime?
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else {
            return nil
        }

        return String(dropFirst(prefix.count))
    }
}
