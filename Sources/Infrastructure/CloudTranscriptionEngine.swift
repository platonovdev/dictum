import Application
import Domain
import Foundation

@MainActor
public final class CloudTranscriptionEngine: SpeechTranscriptionEngine {
    private static let preferredLanguage = "ru"

    public private(set) var apiKey: String
    private var baseURL: String

    public init(apiKey: String = "", baseURL: String = "https://api.openai.com") {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    public func updateConfiguration(apiKey: String, baseURL: String) {
        self.apiKey = apiKey
        self.baseURL = baseURL
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
        request.timeoutInterval = 120

        let audioData: Data
        do {
            audioData = try Data(contentsOf: capturedAudio.fileURL)
        } catch {
            throw AppError.transcriptionFailed("Could not read audio file: \(error.localizedDescription)")
        }

        let fileName = capturedAudio.fileURL.lastPathComponent
        let mimeType = mimeTypeForFile(fileName)

        var body = Data()
        appendFormField(&body, boundary: boundary, name: "model", value: "whisper-1")
        appendFormField(&body, boundary: boundary, name: "language", value: Self.preferredLanguage)
        appendFormField(&body, boundary: boundary, name: "response_format", value: "verbose_json")
        appendFileField(&body, boundary: boundary, name: "file", fileName: fileName, mimeType: mimeType, data: audioData)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        partialHandler(TranscriptChunk(text: "Transcribing in cloud…", isFinal: false))

        let transcriptionStart = CFAbsoluteTimeGetCurrent()

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AppError.transcriptionFailed("Cloud API request failed: \(error.localizedDescription)")
        }

        let transcriptionDuration = CFAbsoluteTimeGetCurrent() - transcriptionStart

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.transcriptionFailed("Invalid response from cloud API.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AppError.transcriptionFailed("Cloud API error (\(httpResponse.statusCode)): \(errorBody)")
        }

        let transcript = try parseResponse(data: data)
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        partialHandler(TranscriptChunk(text: text, isFinal: true))

        return FinalTranscript(
            text: text,
            duration: capturedAudio.duration,
            language: Self.preferredLanguage,
            backend: .cloud,
            transcriptionDuration: transcriptionDuration
        )
    }

    private func parseResponse(data: Data) throws -> String {
        struct VerboseResponse: Decodable {
            let text: String
        }
        struct SimpleResponse: Decodable {
            let text: String
        }

        do {
            let verbose = try JSONDecoder().decode(VerboseResponse.self, from: data)
            return verbose.text
        } catch {
            if let text = String(data: data, encoding: .utf8), !text.isEmpty, !text.contains("{") {
                return text
            }
            throw AppError.transcriptionFailed("Could not parse cloud API response.")
        }
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

    private func mimeTypeForFile(_ fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "mp4": return "audio/mp4"
        case "webm": return "audio/webm"
        case "ogg": return "audio/ogg"
        case "flac": return "audio/flac"
        default: return "audio/wav"
        }
    }
}
