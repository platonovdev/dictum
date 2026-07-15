import Application
import Darwin
import Domain
import Foundation
import Infrastructure

@main
struct DictatorTranscriberMain {
    static func main() async {
        let engine = await MainActor.run { WhisperCppTranscriptionEngine() }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let request = try? decoder.decode(WhisperWorkerRequest.self, from: data) else {
                continue
            }

            if request.kind == .shutdown {
                write(WhisperWorkerResponse(id: request.id, succeeded: true), encoder: encoder)
                return
            }

            let response = await handle(request, engine: engine)
            write(response, encoder: encoder)
        }
    }

    private static func handle(
        _ request: WhisperWorkerRequest,
        engine: WhisperCppTranscriptionEngine
    ) async -> WhisperWorkerResponse {
        do {
            switch request.kind {
            case .prepare:
                guard let modelIdentifier = request.modelIdentifier else {
                    return .init(id: request.id, succeeded: false, error: "Missing model identifier.")
                }
                try await engine.prepareModel(named: modelIdentifier) { _ in }
                return .init(id: request.id, succeeded: true)

            case .transcribe:
                guard let audioPath = request.audioPath,
                      let audioDuration = request.audioDuration else {
                    return .init(id: request.id, succeeded: false, error: "Missing audio recording.")
                }
                await engine.updateSettings(
                    language: request.language ?? .automatic,
                    customWords: request.customWords ?? [],
                    translateToEnglish: request.translateToEnglish ?? false
                )
                let result = try await engine.transcribe(
                    CapturedAudio(fileURL: URL(fileURLWithPath: audioPath), duration: audioDuration)
                ) { _ in }
                return .init(
                    id: request.id,
                    succeeded: true,
                    text: result.text,
                    language: result.language,
                    transcriptionDuration: result.transcriptionDuration
                )

            case .shutdown:
                return .init(id: request.id, succeeded: true)
            }
        } catch let error as AppError {
            return .init(id: request.id, succeeded: false, error: error.userFacingDescription)
        } catch {
            return .init(id: request.id, succeeded: false, error: error.localizedDescription)
        }
    }

    private static func write(_ response: WhisperWorkerResponse, encoder: JSONEncoder) {
        guard var data = try? encoder.encode(response) else {
            return
        }
        data.append(0x0A)
        data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else {
                return
            }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(STDOUT_FILENO, pointer, remaining)
                if written > 0 {
                    pointer = pointer.advanced(by: written)
                    remaining -= written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}
