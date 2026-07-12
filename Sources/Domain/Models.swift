import Foundation

public enum HotkeyKind: String, CaseIterable, Codable, Sendable {
    case rightCommandHold
    case optionSpaceHold

    public var displayName: String {
        switch self {
        case .rightCommandHold:
            return "Hold Right Command"
        case .optionSpaceHold:
            return "Hold Option + Space"
        }
    }
}

public enum OverlayPosition: String, CaseIterable, Codable, Sendable {
    case topCenter
}

public enum DictationLanguage: String, CaseIterable, Codable, Sendable {
    case automatic
    case russian
    case english
    case ukrainian
    case german
    case spanish
    case french

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .russian: "Russian"
        case .english: "English"
        case .ukrainian: "Ukrainian"
        case .german: "German"
        case .spanish: "Spanish"
        case .french: "French"
        }
    }

    public var whisperCode: String? {
        switch self {
        case .automatic: nil
        case .russian: "ru"
        case .english: "en"
        case .ukrainian: "uk"
        case .german: "de"
        case .spanish: "es"
        case .french: "fr"
        }
    }
}

public enum AudioRetentionPolicy: String, CaseIterable, Codable, Sendable {
    case none
    case oneDay
    case sevenDays
    case forever

    public var displayName: String {
        switch self {
        case .none: "Don't keep recordings"
        case .oneDay: "Keep for 1 day"
        case .sevenDays: "Keep for 7 days"
        case .forever: "Keep until deleted"
        }
    }

    public func keepsAudio(startedAt: Date, now: Date = Date()) -> Bool {
        switch self {
        case .none: false
        case .oneDay: now.timeIntervalSince(startedAt) <= 86_400
        case .sevenDays: now.timeIntervalSince(startedAt) <= 604_800
        case .forever: true
        }
    }
}

public enum ModelMemoryPolicy: String, CaseIterable, Codable, Sendable {
    case keepLoaded
    case unloadAfterFiveMinutes
    case unloadAfterFifteenMinutes
    case unloadImmediately

    public var displayName: String {
        switch self {
        case .keepLoaded: "Keep model ready"
        case .unloadAfterFiveMinutes: "Release after 5 minutes"
        case .unloadAfterFifteenMinutes: "Release after 15 minutes"
        case .unloadImmediately: "Release after every dictation"
        }
    }

    public var idleDuration: Duration? {
        switch self {
        case .keepLoaded: nil
        case .unloadAfterFiveMinutes: .seconds(300)
        case .unloadAfterFifteenMinutes: .seconds(900)
        case .unloadImmediately: .zero
        }
    }
}

public struct HotkeyConfiguration: Codable, Hashable, Sendable {
    public var kind: HotkeyKind

    public init(kind: HotkeyKind) {
        self.kind = kind
    }

    public static let `default` = HotkeyConfiguration(kind: .rightCommandHold)
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var modelIdentifier: String
    public var hotkey: HotkeyConfiguration
    public var autoPaste: Bool
    public var launchAtLogin: Bool
    public var overlayPosition: OverlayPosition
    public var language: DictationLanguage
    public var customWords: [String]
    public var translateToEnglish: Bool
    public var appendTrailingSpace: Bool
    public var showOverlay: Bool
    public var modelMemoryPolicy: ModelMemoryPolicy
    public var audioRetention: AudioRetentionPolicy
    public var historyLimit: Int

    public init(
        modelIdentifier: String,
        hotkey: HotkeyConfiguration,
        autoPaste: Bool,
        launchAtLogin: Bool,
        overlayPosition: OverlayPosition,
        language: DictationLanguage = .automatic,
        customWords: [String] = [],
        translateToEnglish: Bool = false,
        appendTrailingSpace: Bool = true,
        showOverlay: Bool = true,
        modelMemoryPolicy: ModelMemoryPolicy = .unloadAfterFiveMinutes,
        audioRetention: AudioRetentionPolicy = .sevenDays,
        historyLimit: Int = 200
    ) {
        self.modelIdentifier = modelIdentifier
        self.hotkey = hotkey
        self.autoPaste = autoPaste
        self.launchAtLogin = launchAtLogin
        self.overlayPosition = overlayPosition
        self.language = language
        self.customWords = customWords
        self.translateToEnglish = translateToEnglish
        self.appendTrailingSpace = appendTrailingSpace
        self.showOverlay = showOverlay
        self.modelMemoryPolicy = modelMemoryPolicy
        self.audioRetention = audioRetention
        self.historyLimit = min(max(historyLimit, 10), 2_000)
    }

    private enum CodingKeys: String, CodingKey {
        case modelIdentifier, hotkey, autoPaste, launchAtLogin, overlayPosition
        case language, customWords, translateToEnglish, appendTrailingSpace, showOverlay, modelMemoryPolicy, audioRetention, historyLimit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let persistedModelIdentifier = try container.decode(String.self, forKey: .modelIdentifier)
        // Release builds before the whisper.cpp migration stored Core ML
        // variant names. Keep those installations usable without asking the
        // user to manually revisit Settings.
        modelIdentifier = Self.migratedModelIdentifier(persistedModelIdentifier)
        hotkey = try container.decode(HotkeyConfiguration.self, forKey: .hotkey)
        autoPaste = try container.decode(Bool.self, forKey: .autoPaste)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        overlayPosition = try container.decode(OverlayPosition.self, forKey: .overlayPosition)
        language = try container.decodeIfPresent(DictationLanguage.self, forKey: .language) ?? .automatic
        customWords = try container.decodeIfPresent([String].self, forKey: .customWords) ?? []
        translateToEnglish = try container.decodeIfPresent(Bool.self, forKey: .translateToEnglish) ?? false
        appendTrailingSpace = try container.decodeIfPresent(Bool.self, forKey: .appendTrailingSpace) ?? true
        showOverlay = try container.decodeIfPresent(Bool.self, forKey: .showOverlay) ?? true
        modelMemoryPolicy = try container.decodeIfPresent(ModelMemoryPolicy.self, forKey: .modelMemoryPolicy) ?? .unloadAfterFiveMinutes
        audioRetention = try container.decodeIfPresent(AudioRetentionPolicy.self, forKey: .audioRetention) ?? .sevenDays
        historyLimit = min(max(try container.decodeIfPresent(Int.self, forKey: .historyLimit) ?? 200, 10), 2_000)
    }

    public static let `default` = AppSettings(
        modelIdentifier: "ggml-large-v3-turbo",
        hotkey: .default,
        autoPaste: true,
        launchAtLogin: false,
        overlayPosition: .topCenter
    )

    private static func migratedModelIdentifier(_ identifier: String) -> String {
        switch identifier {
        case "openai_whisper-large-v3_turbo", "large-v3", "small", "base":
            "ggml-large-v3-turbo"
        default:
            identifier
        }
    }
}

public struct TranscriptionModelOption: Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let downloadSize: String
    public let isRecommended: Bool

    public init(id: String, title: String, detail: String, downloadSize: String = "Downloaded on first use", isRecommended: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.downloadSize = downloadSize
        self.isRecommended = isRecommended
    }

    public static let all: [TranscriptionModelOption] = [
        TranscriptionModelOption(
            id: "ggml-large-v3-turbo",
            title: "Whisper Turbo",
            detail: "Handy-style GGML model: fast, accurate multilingual dictation with Metal.",
            downloadSize: "1.55 GB",
            isRecommended: true
        )
    ]

    public static func option(for id: String) -> TranscriptionModelOption? {
        all.first(where: { $0.id == id })
    }
}

public enum PermissionStatus: String, Codable, Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

public enum PermissionKind: String, CaseIterable, Codable, Equatable, Sendable {
    case microphone
    case accessibility
    case inputMonitoring

    public var displayName: String {
        switch self {
        case .microphone:
            return "Microphone"
        case .accessibility:
            return "Accessibility"
        case .inputMonitoring:
            return "Input Monitoring"
        }
    }
}

public struct PermissionSnapshot: Equatable, Sendable {
    public var microphone: PermissionStatus
    public var accessibility: PermissionStatus
    public var inputMonitoring: PermissionStatus

    public init(
        microphone: PermissionStatus,
        accessibility: PermissionStatus,
        inputMonitoring: PermissionStatus
    ) {
        self.microphone = microphone
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }

    public static let empty = PermissionSnapshot(
        microphone: .notDetermined,
        accessibility: .notDetermined,
        inputMonitoring: .notDetermined
    )

    public var missingRequiredPermissions: [PermissionKind] {
        var missing: [PermissionKind] = []
        if microphone != .authorized {
            missing.append(.microphone)
        }
        return missing
    }

    public var missingRecommendedPermissions: [PermissionKind] {
        var missing: [PermissionKind] = []
        if accessibility != .authorized {
            missing.append(.accessibility)
        }
        if inputMonitoring != .authorized {
            missing.append(.inputMonitoring)
        }
        return missing
    }
}

public struct TranscriptChunk: Equatable, Sendable {
    public var text: String
    public var isFinal: Bool
    public var createdAt: Date

    public init(text: String, isFinal: Bool, createdAt: Date = Date()) {
        self.text = text
        self.isFinal = isFinal
        self.createdAt = createdAt
    }
}

public enum TranscriptionBackend: String, Codable, Equatable, Sendable {
    case local
    // Decode-only compatibility for history created by earlier releases.
    case cloud
    case cloudWithLocalFallback
}

public struct FinalTranscript: Equatable, Sendable {
    public var text: String
    public var duration: TimeInterval
    public var language: String?
    public var backend: TranscriptionBackend
    public var transcriptionDuration: TimeInterval

    public init(
        text: String,
        duration: TimeInterval,
        language: String?,
        backend: TranscriptionBackend = .local,
        transcriptionDuration: TimeInterval = 0
    ) {
        self.text = text
        self.duration = duration
        self.language = language
        self.backend = backend
        self.transcriptionDuration = transcriptionDuration
    }
}

public enum DictationHistoryStatus: String, Codable, Equatable, Sendable {
    case inserted
    case clipboardFallback
    case savedWithoutInsertion
    case emptyTranscript
    case failed
}

public enum DictationFailureStage: String, Codable, Equatable, Sendable {
    case audioCapture
    case transcription
    case insertion
    case persistence
}

public struct DictationHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date
    public var transcript: String
    public var duration: TimeInterval
    public var wordCount: Int
    public var language: String?
    public var status: DictationHistoryStatus
    public var statusDetail: String?
    public var audioArtifactPath: String?
    public var retryCount: Int
    public var failureStage: DictationFailureStage?
    public var transcriptionBackend: TranscriptionBackend?
    public var transcriptionDuration: TimeInterval?

    private enum CodingKeys: String, CodingKey {
        case id
        case startedAt
        case finishedAt
        case transcript
        case duration
        case wordCount
        case language
        case status
        case statusDetail
        case audioArtifactPath
        case retryCount
        case failureStage
        case transcriptionBackend
        case transcriptionDuration
    }

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        finishedAt: Date,
        transcript: String,
        duration: TimeInterval,
        wordCount: Int,
        language: String?,
        status: DictationHistoryStatus,
        statusDetail: String? = nil,
        audioArtifactPath: String? = nil,
        retryCount: Int = 0,
        failureStage: DictationFailureStage? = nil,
        transcriptionBackend: TranscriptionBackend? = nil,
        transcriptionDuration: TimeInterval? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.transcript = transcript
        self.duration = duration
        self.wordCount = wordCount
        self.language = language
        self.status = status
        self.statusDetail = statusDetail
        self.audioArtifactPath = audioArtifactPath
        self.retryCount = retryCount
        self.failureStage = failureStage
        self.transcriptionBackend = transcriptionBackend
        self.transcriptionDuration = transcriptionDuration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        finishedAt = try container.decode(Date.self, forKey: .finishedAt)
        transcript = try container.decode(String.self, forKey: .transcript)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount) ?? transcript.split {
            $0.isWhitespace || $0.isNewline
        }.count
        language = try container.decodeIfPresent(String.self, forKey: .language)
        status = try container.decode(DictationHistoryStatus.self, forKey: .status)
        statusDetail = try container.decodeIfPresent(String.self, forKey: .statusDetail)
        audioArtifactPath = try container.decodeIfPresent(String.self, forKey: .audioArtifactPath)
        retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        failureStage = try container.decodeIfPresent(DictationFailureStage.self, forKey: .failureStage)
        transcriptionBackend = try container.decodeIfPresent(TranscriptionBackend.self, forKey: .transcriptionBackend)
        transcriptionDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .transcriptionDuration)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(finishedAt, forKey: .finishedAt)
        try container.encode(transcript, forKey: .transcript)
        try container.encode(duration, forKey: .duration)
        try container.encode(wordCount, forKey: .wordCount)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(statusDetail, forKey: .statusDetail)
        try container.encodeIfPresent(audioArtifactPath, forKey: .audioArtifactPath)
        try container.encode(retryCount, forKey: .retryCount)
        try container.encodeIfPresent(failureStage, forKey: .failureStage)
        try container.encodeIfPresent(transcriptionBackend, forKey: .transcriptionBackend)
        try container.encodeIfPresent(transcriptionDuration, forKey: .transcriptionDuration)
    }
}

public extension DictationHistoryEntry {
    static func make(
        id: UUID = UUID(),
        startedAt: Date,
        finishedAt: Date = Date(),
        transcript: String,
        duration: TimeInterval,
        language: String?,
        status: DictationHistoryStatus,
        statusDetail: String? = nil,
        audioArtifactPath: String? = nil,
        retryCount: Int = 0,
        failureStage: DictationFailureStage? = nil,
        transcriptionBackend: TranscriptionBackend? = nil,
        transcriptionDuration: TimeInterval? = nil
    ) -> DictationHistoryEntry {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return DictationHistoryEntry(
            id: id,
            startedAt: startedAt,
            finishedAt: finishedAt,
            transcript: cleaned,
            duration: duration,
            wordCount: cleaned.split { $0.isWhitespace || $0.isNewline }.count,
            language: language,
            status: status,
            statusDetail: statusDetail,
            audioArtifactPath: audioArtifactPath,
            retryCount: retryCount,
            failureStage: failureStage,
            transcriptionBackend: transcriptionBackend,
            transcriptionDuration: transcriptionDuration
        )
    }

    var isRetryable: Bool {
        guard let audioArtifactPath else {
            return false
        }
        return FileManager.default.fileExists(atPath: audioArtifactPath)
    }

    /// Failed recognition and empty-result recordings are recovery artifacts.
    /// They stay available until a successful retry or explicit deletion,
    /// even when normal successful-recording retention is disabled.
    var needsRecoveryAudio: Bool {
        status == .emptyTranscript || (status == .failed && failureStage != .insertion)
    }

    var countsTowardStatistics: Bool {
        switch status {
        case .inserted, .clipboardFallback, .savedWithoutInsertion:
            return true
        case .emptyTranscript, .failed:
            return false
        }
    }
}

public struct DictationStatistics: Equatable, Sendable {
    public var totalDuration: TimeInterval
    public var totalWords: Int

    public init(totalDuration: TimeInterval, totalWords: Int) {
        self.totalDuration = totalDuration
        self.totalWords = totalWords
    }

    public static let zero = DictationStatistics(totalDuration: 0, totalWords: 0)
}

public extension DictationStatistics {
    static func make(from entries: [DictationHistoryEntry]) -> DictationStatistics {
        entries.reduce(into: .zero) { partial, entry in
            guard entry.countsTowardStatistics else {
                return
            }

            partial.totalDuration += entry.duration
            partial.totalWords += entry.wordCount
        }
    }
}

public struct ModelPreparationStatus: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var progress: Double?
    public var startedAt: Date

    public init(title: String, detail: String, progress: Double?, startedAt: Date = Date()) {
        self.title = title
        self.detail = detail
        self.progress = progress
        self.startedAt = startedAt
    }
}

public struct AudioMeterFrame: Equatable, Sendable {
    public var overallLevel: Float
    public var visualLevel: Float
    public var speechConfidence: Float
    public var isSpeechDetected: Bool
    public var frameDuration: TimeInterval
    public var bands: [Float]

    public init(
        overallLevel: Float,
        visualLevel: Float? = nil,
        speechConfidence: Float = 0,
        isSpeechDetected: Bool = false,
        frameDuration: TimeInterval = 0,
        bands: [Float]
    ) {
        self.overallLevel = overallLevel
        self.visualLevel = visualLevel ?? overallLevel
        self.speechConfidence = speechConfidence
        self.isSpeechDetected = isSpeechDetected
        self.frameDuration = frameDuration
        self.bands = bands
    }

    public static let silent = AudioMeterFrame(
        overallLevel: 0,
        visualLevel: 0,
        speechConfidence: 0,
        isSpeechDetected: false,
        frameDuration: 0,
        bands: Array(repeating: 0, count: 9)
    )
}

public struct CapturedAudio: Equatable, Sendable {
    public var fileURL: URL
    public var duration: TimeInterval

    public init(fileURL: URL, duration: TimeInterval) {
        self.fileURL = fileURL
        self.duration = duration
    }
}

public struct ArchivedAudio: Equatable, Sendable {
    public var fileURL: URL
    public var duration: TimeInterval

    public init(fileURL: URL, duration: TimeInterval) {
        self.fileURL = fileURL
        self.duration = duration
    }
}

public enum AppError: Error, Equatable, Sendable {
    case permissionsMissing([PermissionKind])
    case modelUnavailable
    case audioCaptureFailed(String)
    case transcriptionFailed(String)
    case insertionFailed(String)
    case audioArchiveFailed(String)
    case historyPersistenceFailed(String)
    case historyEntryNotFound(UUID)
    case archivedAudioUnavailable(String)
    case launchAtLoginFailed(String)
    case secureInputField
    case emptyTranscript
    case hotkeyUnavailable
    case unsupportedPlatform
}

public enum InsertionResult: Equatable, Sendable {
    case success
    case clipboardFallback
    case failure(AppError)
}

public enum HotkeyEvent: Equatable, Sendable {
    case pressed
    case released
    case pressedAt(TimeInterval)
    case releasedAt(TimeInterval)
    case lockRecording
    case escapePressed
}

public enum DictationSessionState: Equatable, Sendable {
    case idle(lastTranscript: String? = nil, insertionResult: InsertionResult? = nil)
    case preparingModel(ModelPreparationStatus)
    case recording(startedAt: Date, isHandsFree: Bool = false)
    case transcribing(partialText: String?)
    case inserting(text: String)
    case error(AppError)
}

public extension AppError {
    var userFacingDescription: String {
        switch self {
        case .permissionsMissing(let permissions):
            let names = permissions.map(\.displayName).joined(separator: ", ")
            return "Missing required permissions: \(names)."
        case .modelUnavailable:
            return "The local Whisper model is not ready yet."
        case .audioCaptureFailed(let message):
            return "Audio capture failed: \(message)"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .insertionFailed(let message):
            return "Text insertion failed: \(message)"
        case .audioArchiveFailed(let message):
            return "Could not archive the audio for retry: \(message)"
        case .historyPersistenceFailed(let message):
            return "History could not be saved: \(message)"
        case .historyEntryNotFound(let id):
            return "History entry was not found: \(id.uuidString)"
        case .archivedAudioUnavailable(let path):
            return "Archived audio is unavailable: \(path)"
        case .launchAtLoginFailed(let message):
            return "Launch at login could not be updated: \(message)"
        case .secureInputField:
            return "The current field is secure. The transcript was copied to the clipboard."
        case .emptyTranscript:
            return "No speech was detected."
        case .hotkeyUnavailable:
            return "The global hotkey could not be started."
        case .unsupportedPlatform:
            return "This app currently supports Apple Silicon on macOS only."
        }
    }
}
