import Application
import Darwin
import Domain
import Foundation

public struct WhisperWorkerRequest: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case prepare
        case transcribe
        case shutdown
    }

    public let id: UUID
    public let kind: Kind
    public let modelIdentifier: String?
    public let audioPath: String?
    public let audioDuration: TimeInterval?
    public let language: DictationLanguage?
    public let customWords: [String]?
    public let translateToEnglish: Bool?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        modelIdentifier: String? = nil,
        audioPath: String? = nil,
        audioDuration: TimeInterval? = nil,
        language: DictationLanguage? = nil,
        customWords: [String]? = nil,
        translateToEnglish: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.modelIdentifier = modelIdentifier
        self.audioPath = audioPath
        self.audioDuration = audioDuration
        self.language = language
        self.customWords = customWords
        self.translateToEnglish = translateToEnglish
    }
}

public struct WhisperWorkerResponse: Codable, Sendable {
    public let id: UUID
    public let succeeded: Bool
    public let text: String?
    public let language: String?
    public let transcriptionDuration: TimeInterval?
    public let error: String?

    public init(
        id: UUID,
        succeeded: Bool,
        text: String? = nil,
        language: String? = nil,
        transcriptionDuration: TimeInterval? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.succeeded = succeeded
        self.text = text
        self.language = language
        self.transcriptionDuration = transcriptionDuration
        self.error = error
    }
}

/// Keeps all whisper.cpp and Metal state outside the UI process. A native
/// crash, abort or non-returning decode becomes a recoverable worker failure.
@MainActor
public final class IsolatedWhisperTranscriptionEngine: ConfigurableLocalTranscriptionEngine, CancellableSpeechTranscriptionEngine {
    private var connection: WhisperWorkerConnection?
    private var preparedConnectionID: ObjectIdentifier?
    private var modelIdentifier: String?
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
        self.translateToEnglish = translateToEnglish
    }

    public func prepareModel(
        named modelIdentifier: String,
        progressHandler: @escaping @Sendable (ModelPreparationStatus) -> Void
    ) async throws {
        self.modelIdentifier = modelIdentifier
        progressHandler(.init(
            title: "Preparing local speech engine",
            detail: "Starting the isolated Whisper worker.",
            progress: 0.1
        ))
        let connection = try workerConnection()
        do {
            try await prepare(modelIdentifier: modelIdentifier, on: connection)
            progressHandler(.init(
                title: "Local model ready",
                detail: "Whisper Turbo is ready in its protected process.",
                progress: 1
            ))
        } catch {
            await invalidate(connection)
            throw error
        }
    }

    public func unloadModel() async {
        guard let connection else {
            return
        }
        await invalidate(connection)
    }

    public func cancelCurrentTranscription() async {
        guard let connection else {
            return
        }
        await invalidate(connection)
    }

    public func transcribe(
        _ capturedAudio: CapturedAudio,
        partialHandler: @escaping @Sendable (TranscriptChunk) -> Void
    ) async throws -> FinalTranscript {
        guard let modelIdentifier else {
            throw AppError.modelUnavailable
        }
        let connection = try workerConnection()
        do {
            if preparedConnectionID != ObjectIdentifier(connection) {
                try await prepare(modelIdentifier: modelIdentifier, on: connection)
            }
            let request = WhisperWorkerRequest(
                kind: .transcribe,
                audioPath: capturedAudio.fileURL.path,
                audioDuration: capturedAudio.duration,
                language: language,
                customWords: customWords,
                translateToEnglish: translateToEnglish
            )
            let response = try await perform(request, on: connection)
            guard response.succeeded else {
                throw AppError.transcriptionFailed(response.error ?? "The isolated speech engine failed.")
            }
            let text = response.text ?? ""
            partialHandler(.init(text: text, isFinal: true))
            return FinalTranscript(
                text: text,
                duration: capturedAudio.duration,
                language: response.language,
                backend: .local,
                transcriptionDuration: response.transcriptionDuration ?? 0
            )
        } catch let error as AppError {
            await invalidate(connection)
            throw error
        } catch {
            await invalidate(connection)
            throw AppError.transcriptionFailed("The isolated speech engine stopped unexpectedly: \(error.localizedDescription)")
        }
    }

    private func prepare(modelIdentifier: String, on connection: WhisperWorkerConnection) async throws {
        let response = try await perform(
            WhisperWorkerRequest(kind: .prepare, modelIdentifier: modelIdentifier),
            on: connection
        )
        guard response.succeeded else {
            throw AppError.modelUnavailable
        }
        preparedConnectionID = ObjectIdentifier(connection)
    }

    private func perform(
        _ request: WhisperWorkerRequest,
        on connection: WhisperWorkerConnection
    ) async throws -> WhisperWorkerResponse {
        try await Task.detached(priority: .userInitiated) {
            try connection.perform(request)
        }.value
    }

    private func workerConnection() throws -> WhisperWorkerConnection {
        if let connection, connection.isRunning {
            return connection
        }
        let connection = try WhisperWorkerConnection(executableURL: try Self.workerExecutableURL())
        self.connection = connection
        preparedConnectionID = nil
        return connection
    }

    private func invalidate(_ connection: WhisperWorkerConnection) async {
        if self.connection === connection {
            self.connection = nil
            preparedConnectionID = nil
        }
        connection.terminate()
        try? await Task.sleep(for: .milliseconds(180))
        connection.forceTerminateIfNeeded()
    }

    private static func workerExecutableURL() throws -> URL {
        let bundledURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("DictatorTranscriber")
        if FileManager.default.isExecutableFile(atPath: bundledURL.path) {
            return bundledURL
        }

        if let executableURL = Bundle.main.executableURL {
            let siblingURL = executableURL.deletingLastPathComponent().appendingPathComponent("DictatorTranscriber")
            if FileManager.default.isExecutableFile(atPath: siblingURL.path) {
                return siblingURL
            }
        }
        throw AppError.modelUnavailable
    }
}

private final class WhisperWorkerConnection: @unchecked Sendable {
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let requestLock = NSLock()
    private let reader: BlockingLineReader
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let nullHandle: FileHandle?

    var isRunning: Bool { process.isRunning }

    init(executableURL: URL) throws {
        reader = BlockingLineReader(handle: outputPipe.fileHandleForReading)
        nullHandle = FileHandle(forWritingAtPath: "/dev/null")
        process.executableURL = executableURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = nullHandle ?? FileHandle.standardError
        try process.run()
    }

    deinit {
        terminate()
    }

    func perform(_ request: WhisperWorkerRequest) throws -> WhisperWorkerResponse {
        let deadline = Date().addingTimeInterval(responseTimeout(for: request))
        guard requestLock.lock(before: deadline) else {
            throw WorkerConnectionError.responseTimeout
        }
        defer { requestLock.unlock() }
        guard process.isRunning else {
            throw WorkerConnectionError.notRunning
        }

        var payload = try encoder.encode(request)
        payload.append(0x0A)
        try writeAll(payload, to: inputPipe.fileHandleForWriting.fileDescriptor)
        let responseData = try reader.readLine(deadline: deadline)
        let response = try decoder.decode(WhisperWorkerResponse.self, from: responseData)
        guard response.id == request.id else {
            throw WorkerConnectionError.responseMismatch
        }
        return response
    }

    private func responseTimeout(for request: WhisperWorkerRequest) -> TimeInterval {
        switch request.kind {
        case .prepare:
            guard let modelIdentifier = request.modelIdentifier else {
                return 90
            }
            let applicationSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            let modelURL = applicationSupportURL?
                .appendingPathComponent("Dictum", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent(modelIdentifier)
                .appendingPathExtension("bin")
            // A first download may legitimately take a while. An already
            // downloaded model should load and answer well within 90 seconds.
            return modelURL.map { FileManager.default.fileExists(atPath: $0.path) } == true ? 90 : 1_800
        case .transcribe:
            let duration = request.audioDuration ?? 0
            return min(max(45, (duration * 0.75) + 30), 900)
        case .shutdown:
            return 5
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else {
                return
            }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written > 0 {
                    pointer = pointer.advanced(by: written)
                    remaining -= written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw WorkerConnectionError.writeFailed
                }
            }
        }
    }

    func terminate() {
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
    }

    func forceTerminateIfNeeded() {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

private final class BlockingLineReader: @unchecked Sendable {
    private let descriptor: Int32
    private var buffer = Data()

    init(handle: FileHandle) {
        descriptor = handle.fileDescriptor
    }

    func readLine(deadline: Date) throws -> Data {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                // Copy before mutating the backing Data. A slice can share
                // storage with `buffer` and becomes invalid after removal.
                let line = Data(buffer[..<newlineIndex])
                buffer.removeSubrange(...newlineIndex)
                return line
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw WorkerConnectionError.responseTimeout
            }
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let timeoutMilliseconds = Int32(min(max(remaining * 1_000, 1), Double(Int32.max)))
            let pollResult = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
            if pollResult == 0 {
                throw WorkerConnectionError.responseTimeout
            }
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                throw WorkerConnectionError.readFailed
            }

            var bytes = [UInt8](repeating: 0, count: 4_096)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            guard count > 0 else {
                throw WorkerConnectionError.endOfFile
            }
            buffer.append(bytes, count: count)
        }
    }
}

private enum WorkerConnectionError: LocalizedError {
    case notRunning
    case endOfFile
    case responseMismatch
    case responseTimeout
    case readFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .notRunning: "The speech worker is not running."
        case .endOfFile: "The speech worker closed its response channel."
        case .responseMismatch: "The speech worker returned an unexpected response."
        case .responseTimeout: "The speech worker did not answer before the safety timeout."
        case .readFailed: "The speech worker response could not be read."
        case .writeFailed: "The speech worker request could not be sent."
        }
    }
}
