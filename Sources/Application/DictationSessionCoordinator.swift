import Domain
import Foundation

@MainActor
public final class DictationSessionCoordinator: DictationSessionCoordinating {
    private enum Constants {
        static let minimumSpeechLevel: Float = 0.045
        static let minimumSpeechDuration: TimeInterval = 0.35
        static let transientResetDelay: Duration = .milliseconds(900)
        static let quickTapMaxDuration: TimeInterval = 0.25
        static let doublePressWindow: Duration = .milliseconds(350)
    }

    private enum HotkeyGestureState: Equatable {
        case idle
        case awaitingSecondPress
        case handsFree
    }

    private let transcriptionEngine: SpeechTranscriptionEngine
    private let audioCaptureService: AudioCaptureService
    private let insertionService: TextInsertionService
    private let permissionService: PermissionService
    private let settingsStore: SettingsStore
    private let historyStore: DictationHistoryStore
    private let audioArchive: DictationAudioArchive

    private let stateBroadcast = AsyncBroadcast<DictationSessionState>()
    private let partialBroadcast = AsyncBroadcast<String>()
    private let meterBroadcast = AsyncBroadcast<AudioMeterFrame>()

    private var state: DictationSessionState = .idle()
    private var settings: AppSettings = .default
    private var levelTask: Task<Void, Never>?
    private var isModelPrepared = false
    private var activeSessionID = UUID()
    private var peakInputLevel: Float = 0
    private var recordingStartedAt: Date?
    private var latestPartialText: String = ""
    private var hotkeyGestureState: HotkeyGestureState = .idle
    private var hotkeyPressStartedAt: Date?
    private var hotkeyDecisionTask: Task<Void, Never>?

    public init(
        transcriptionEngine: SpeechTranscriptionEngine,
        audioCaptureService: AudioCaptureService,
        insertionService: TextInsertionService,
        permissionService: PermissionService,
        settingsStore: SettingsStore,
        historyStore: DictationHistoryStore,
        audioArchive: DictationAudioArchive = FileSystemDictationAudioArchive()
    ) {
        self.transcriptionEngine = transcriptionEngine
        self.audioCaptureService = audioCaptureService
        self.insertionService = insertionService
        self.permissionService = permissionService
        self.settingsStore = settingsStore
        self.historyStore = historyStore
        self.audioArchive = audioArchive
    }

    public func makeStateStream() -> AsyncStream<DictationSessionState> {
        let stream = stateBroadcast.stream()
        stateBroadcast.yield(state)
        return stream
    }

    public func makePartialTranscriptStream() -> AsyncStream<String> {
        partialBroadcast.stream()
    }

    public func makeMeterStream() -> AsyncStream<AudioMeterFrame> {
        meterBroadcast.stream()
    }

    public func makeHistoryStream() -> AsyncStream<[DictationHistoryEntry]> {
        historyStore.makeEntriesStream()
    }

    public func loadHistoryEntries() async -> [DictationHistoryEntry] {
        (try? await historyStore.loadEntries()) ?? []
    }

    public func handleHotkeyEvent(_ event: HotkeyEvent) async {
        switch event {
        case .pressed:
            await handleHotkeyPressed()
        case .released:
            await handleHotkeyReleased()
        }
    }

    public func prepare() async {
        do {
            settings = try await settingsStore.load()
            try await transcriptionEngine.prepareModel(named: settings.modelIdentifier) { [weak self] status in
                Task { @MainActor in
                    self?.transition(to: .preparingModel(status))
                }
            }
            isModelPrepared = true
            transition(to: .idle())
        } catch let error as AppError {
            transition(to: .error(error))
        } catch {
            transition(to: .error(.modelUnavailable))
        }
    }

    public func reloadSettings() async {
        do {
            let updatedSettings = try await settingsStore.load()
            let modelChanged = updatedSettings.modelIdentifier != settings.modelIdentifier
            settings = updatedSettings

            if modelChanged {
                try await transcriptionEngine.prepareModel(named: updatedSettings.modelIdentifier) { [weak self] status in
                    Task { @MainActor in
                        self?.transition(to: .preparingModel(status))
                    }
                }
                isModelPrepared = true
            }

            if case .error = state {
                transition(to: .idle())
            }
        } catch let error as AppError {
            transition(to: .error(error))
        } catch {
            transition(to: .error(.modelUnavailable))
        }
    }

    public func startDictation() async {
        if case .error = state {
            await resetSession()
        }

        guard case .idle = state else {
            return
        }

        let permissions = permissionService.currentSnapshot()
        guard permissions.missingRequiredPermissions.isEmpty else {
            transition(to: .error(.permissionsMissing(permissions.missingRequiredPermissions)))
            return
        }

        do {
            if !isModelPrepared {
                try await transcriptionEngine.prepareModel(named: settings.modelIdentifier) { [weak self] status in
                    Task { @MainActor in
                        self?.transition(to: .preparingModel(status))
                    }
                }
                isModelPrepared = true
            }

            let sessionID = UUID()
            activeSessionID = sessionID
            peakInputLevel = 0
            latestPartialText = ""

            try await audioCaptureService.startRecording()
            guard isCurrent(sessionID) else {
                await audioCaptureService.cancelRecording()
                return
            }

            let startedAt = Date()
            recordingStartedAt = startedAt
            transition(to: .recording(startedAt: startedAt))
            forwardLevelEvents(for: sessionID)
        } catch let error as AppError {
            await handleError(error)
        } catch {
            await handleError(.audioCaptureFailed(error.localizedDescription))
        }
    }

    public func stopDictation() async {
        guard case .recording = state else {
            return
        }

        cancelHotkeyDecisionTask()
        hotkeyGestureState = .idle
        hotkeyPressStartedAt = nil

        let sessionID = activeSessionID
        let startedAt = recordingStartedAt ?? Date()
        levelTask?.cancel()
        transition(to: .transcribing(partialText: nil))

        do {
            let capturedAudio = try await audioCaptureService.stopRecording()
            guard isCurrent(sessionID) else {
                return
            }

            if peakInputLevel < Constants.minimumSpeechLevel || capturedAudio.duration < Constants.minimumSpeechDuration {
                try await persistHistoryEntry(
                    DictationHistoryEntry.make(
                        id: sessionID,
                        startedAt: startedAt,
                        transcript: "",
                        duration: capturedAudio.duration,
                        language: nil,
                        status: .emptyTranscript,
                        statusDetail: AppError.emptyTranscript.userFacingDescription
                    )
                )
                try? FileManager.default.removeItem(at: capturedAudio.fileURL)
                transition(to: .idle())
                recordingStartedAt = nil
                latestPartialText = ""
                return
            }

            let archivedAudio: ArchivedAudio
            do {
                archivedAudio = try await audioArchive.archive(capturedAudio, for: sessionID)
            } catch let error as AppError {
                try await persistFailedHistoryEntry(
                    id: sessionID,
                    startedAt: startedAt,
                    duration: capturedAudio.duration,
                    transcript: latestPartialText,
                    error: error,
                    audioArtifactPath: nil,
                    retryCount: 0,
                    failureStage: .persistence
                )
                await handleError(error)
                return
            } catch {
                let failureError = AppError.audioArchiveFailed(error.localizedDescription)
                try await persistFailedHistoryEntry(
                    id: sessionID,
                    startedAt: startedAt,
                    duration: capturedAudio.duration,
                    transcript: latestPartialText,
                    error: failureError,
                    audioArtifactPath: nil,
                    retryCount: 0,
                    failureStage: .persistence
                )
                await handleError(failureError)
                return
            }

            let finalTranscript: FinalTranscript
            do {
                finalTranscript = try await transcriptionEngine.transcribe(
                    CapturedAudio(fileURL: archivedAudio.fileURL, duration: archivedAudio.duration)
                ) { [weak self] chunk in
                    Task { @MainActor in
                        guard let self, self.isCurrent(sessionID) else {
                            return
                        }
                        self.latestPartialText = chunk.text
                        self.partialBroadcast.yield(chunk.text)
                        self.transition(to: .transcribing(partialText: chunk.text))
                    }
                }
            } catch let error as AppError {
                try await persistFailedHistoryEntry(
                    id: sessionID,
                    startedAt: startedAt,
                    duration: archivedAudio.duration,
                    transcript: latestPartialText,
                    error: error,
                    audioArtifactPath: archivedAudio.fileURL.path,
                    retryCount: 0,
                    failureStage: .transcription
                )
                await handleError(error)
                return
            } catch {
                let failureError = AppError.transcriptionFailed(error.localizedDescription)
                try await persistFailedHistoryEntry(
                    id: sessionID,
                    startedAt: startedAt,
                    duration: archivedAudio.duration,
                    transcript: latestPartialText,
                    error: failureError,
                    audioArtifactPath: archivedAudio.fileURL.path,
                    retryCount: 0,
                    failureStage: .transcription
                )
                await handleError(failureError)
                return
            }

            guard isCurrent(sessionID) else {
                return
            }

            let cleaned = finalTranscript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                try await persistHistoryEntry(
                    DictationHistoryEntry.make(
                        id: sessionID,
                        startedAt: startedAt,
                        transcript: "",
                        duration: finalTranscript.duration,
                        language: finalTranscript.language,
                        status: .emptyTranscript,
                        statusDetail: AppError.emptyTranscript.userFacingDescription
                    )
                )
                await audioArchive.deleteArchivedAudio(at: archivedAudio.fileURL.path)
                transition(to: .idle())
                recordingStartedAt = nil
                latestPartialText = ""
                return
            }

            if settings.autoPaste {
                transition(to: .inserting(text: cleaned))
                await Task.yield()
                let result = await insertionService.insert(text: cleaned)
                guard isCurrent(sessionID) else {
                    return
                }

                switch result {
                case .success, .clipboardFallback:
                    try await persistHistoryEntry(
                        DictationHistoryEntry.make(
                            id: sessionID,
                            startedAt: startedAt,
                            transcript: cleaned,
                            duration: finalTranscript.duration,
                            language: finalTranscript.language,
                            status: historyStatus(for: result),
                            statusDetail: historyStatusDetail(for: result),
                            transcriptionBackend: finalTranscript.backend,
                            transcriptionDuration: finalTranscript.transcriptionDuration
                        )
                    )
                    await audioArchive.deleteArchivedAudio(at: archivedAudio.fileURL.path)
                    transition(to: .idle(lastTranscript: cleaned, insertionResult: result))
                case .failure(let error):
                    try await persistFailedHistoryEntry(
                        id: sessionID,
                        startedAt: startedAt,
                        duration: finalTranscript.duration,
                        transcript: cleaned,
                        error: error,
                        audioArtifactPath: archivedAudio.fileURL.path,
                        retryCount: 0,
                        failureStage: .transcription
                    )
                    await handleError(error)
                    return
                }
            } else {
                try await persistHistoryEntry(
                    DictationHistoryEntry.make(
                        id: sessionID,
                        startedAt: startedAt,
                        transcript: cleaned,
                        duration: finalTranscript.duration,
                        language: finalTranscript.language,
                        status: .savedWithoutInsertion,
                        transcriptionBackend: finalTranscript.backend,
                        transcriptionDuration: finalTranscript.transcriptionDuration
                    )
                )
                await audioArchive.deleteArchivedAudio(at: archivedAudio.fileURL.path)
                transition(to: .idle(lastTranscript: cleaned, insertionResult: nil))
            }

            recordingStartedAt = nil
            latestPartialText = ""
        } catch let error as AppError {
            try? await persistFailedHistoryEntry(
                id: sessionID,
                startedAt: startedAt,
                duration: max(Date().timeIntervalSince(startedAt), 0),
                transcript: latestPartialText,
                error: error,
                audioArtifactPath: nil,
                retryCount: 0,
                failureStage: .audioCapture
            )
            await handleError(error)
        } catch {
            let failureError = AppError.audioCaptureFailed(error.localizedDescription)
            try? await persistFailedHistoryEntry(
                id: sessionID,
                startedAt: startedAt,
                duration: max(Date().timeIntervalSince(startedAt), 0),
                transcript: latestPartialText,
                error: failureError,
                audioArtifactPath: nil,
                retryCount: 0,
                failureStage: .audioCapture
            )
            await handleError(failureError)
        }
    }

    public func resetSession() async {
        activeSessionID = UUID()
        peakInputLevel = 0
        levelTask?.cancel()
        levelTask = nil
        cancelHotkeyDecisionTask()
        hotkeyGestureState = .idle
        hotkeyPressStartedAt = nil
        partialBroadcast.yield("")
        meterBroadcast.yield(.silent)
        await audioCaptureService.cancelRecording()
        recordingStartedAt = nil
        latestPartialText = ""
        transition(to: .idle())
    }

    public func retryHistoryEntry(id: UUID) async {
        do {
            let entries = try await historyStore.loadEntries()
            guard let entry = entries.first(where: { $0.id == id }) else {
                throw AppError.historyEntryNotFound(id)
            }

            guard entry.isRetryable else {
                throw AppError.archivedAudioUnavailable(entry.audioArtifactPath ?? "")
            }

            try await retryHistoryEntry(entry)
        } catch let error as AppError {
            transition(to: .error(error))
        } catch {
            transition(to: .error(.historyPersistenceFailed(error.localizedDescription)))
        }
    }

    public func deleteHistoryEntry(id: UUID) async {
        do {
            let entries = try await historyStore.loadEntries()
            guard let entry = entries.first(where: { $0.id == id }) else {
                throw AppError.historyEntryNotFound(id)
            }

            try await removeHistoryEntry(id: id)
            if let path = entry.audioArtifactPath {
                await audioArchive.deleteArchivedAudio(at: path)
            }
        } catch let error as AppError {
            transition(to: .error(error))
        } catch {
            transition(to: .error(.historyPersistenceFailed(error.localizedDescription)))
        }
    }

    private func forwardLevelEvents(for sessionID: UUID) {
        levelTask?.cancel()
        let stream = audioCaptureService.makeMeterStream()
        levelTask = Task { [weak self] in
            for await meterFrame in stream {
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard let self, self.isCurrent(sessionID) else {
                        return
                    }
                    self.peakInputLevel = max(self.peakInputLevel, meterFrame.overallLevel)
                    self.meterBroadcast.yield(meterFrame)
                }
            }
        }
    }

    private func handleHotkeyPressed() async {
        hotkeyPressStartedAt = Date()

        switch hotkeyGestureState {
        case .idle:
            if !isErrorState {
                guard case .idle = state else {
                    return
                }
            }
            await startDictation()
        case .awaitingSecondPress:
            cancelHotkeyDecisionTask()
            hotkeyGestureState = .handsFree
        case .handsFree:
            cancelHotkeyDecisionTask()
            hotkeyGestureState = .idle
            await stopDictation()
        }
    }

    private func handleHotkeyReleased() async {
        guard case .recording = state else {
            hotkeyPressStartedAt = nil
            return
        }

        guard hotkeyGestureState != .handsFree else {
            hotkeyPressStartedAt = nil
            return
        }

        let startedAt = hotkeyPressStartedAt ?? Date()
        hotkeyPressStartedAt = nil

        let heldFor = Date().timeIntervalSince(startedAt)
        if heldFor > Constants.quickTapMaxDuration {
            cancelHotkeyDecisionTask()
            hotkeyGestureState = .idle
            await stopDictation()
            return
        }

        scheduleDoublePressDecision()
    }

    private func scheduleDoublePressDecision() {
        cancelHotkeyDecisionTask()
        hotkeyGestureState = .awaitingSecondPress

        hotkeyDecisionTask = Task { [weak self] in
            try? await Task.sleep(for: Constants.doublePressWindow)
            guard let self else {
                return
            }

            let shouldStop = await MainActor.run { () -> Bool in
                guard self.hotkeyGestureState == .awaitingSecondPress,
                      case .recording = self.state else {
                    self.hotkeyDecisionTask = nil
                    return false
                }

                self.hotkeyGestureState = .idle
                self.hotkeyDecisionTask = nil
                return true
            }

            guard shouldStop else {
                return
            }

            await self.stopDictation()
        }
    }

    private func cancelHotkeyDecisionTask() {
        hotkeyDecisionTask?.cancel()
        hotkeyDecisionTask = nil
    }

    private var isErrorState: Bool {
        if case .error = state {
            return true
        }
        return false
    }

    private func handleError(_ error: AppError) async {
        switch error {
        case .permissionsMissing:
            transition(to: .error(error))
        case .emptyTranscript:
            transition(to: .idle())
        default:
            transition(to: .error(error))
            let sessionID = activeSessionID
            Task { @MainActor in
                try? await Task.sleep(for: Constants.transientResetDelay)
                guard self.isCurrent(sessionID), case .error = self.state else {
                    return
                }
                await self.resetSession()
            }
        }
    }

    private func isCurrent(_ sessionID: UUID) -> Bool {
        activeSessionID == sessionID
    }

    private func persistFailedHistoryEntry(
        id: UUID,
        startedAt: Date,
        duration: TimeInterval,
        transcript: String,
        error: AppError,
        audioArtifactPath: String?,
        retryCount: Int,
        failureStage: DictationFailureStage
    ) async throws {
        let entry = DictationHistoryEntry.make(
            id: id,
            startedAt: startedAt,
            transcript: transcript,
            duration: duration,
            language: nil,
            status: .failed,
            statusDetail: error.userFacingDescription,
            audioArtifactPath: audioArtifactPath,
            retryCount: retryCount,
            failureStage: failureStage
        )
        try await persistHistoryEntry(entry)
        recordingStartedAt = nil
        latestPartialText = ""
    }

    private func persistHistoryEntry(_ entry: DictationHistoryEntry) async throws {
        try await historyStore.append(entry)
    }

    private func updateHistoryEntry(_ entry: DictationHistoryEntry) async throws {
        try await historyStore.update(entry)
    }

    private func removeHistoryEntry(id: UUID) async throws {
        try await historyStore.delete(id: id)
    }

    private func retryHistoryEntry(_ entry: DictationHistoryEntry) async throws {
        guard entry.isRetryable, let audioArtifactPath = entry.audioArtifactPath else {
            throw AppError.archivedAudioUnavailable(entry.audioArtifactPath ?? "")
        }

        let archivedAudio = try await audioArchive.loadArchivedAudio(
            at: audioArtifactPath,
            duration: entry.duration
        )

        let sessionID = entry.id
        activeSessionID = sessionID
        peakInputLevel = 0
        latestPartialText = ""
        recordingStartedAt = entry.startedAt
        transition(to: .transcribing(partialText: nil))

        do {
            let finalTranscript = try await transcriptionEngine.transcribe(
                archivedAudio
            ) { [weak self] chunk in
                Task { @MainActor in
                    guard let self, self.isCurrent(sessionID) else {
                        return
                    }
                    self.latestPartialText = chunk.text
                    self.partialBroadcast.yield(chunk.text)
                    self.transition(to: .transcribing(partialText: chunk.text))
                }
            }

            guard isCurrent(sessionID) else {
                return
            }

            let cleaned = finalTranscript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                let emptyEntry = DictationHistoryEntry.make(
                    id: entry.id,
                    startedAt: entry.startedAt,
                    finishedAt: Date(),
                    transcript: "",
                    duration: finalTranscript.duration,
                    language: finalTranscript.language,
                    status: .emptyTranscript,
                    statusDetail: AppError.emptyTranscript.userFacingDescription,
                    audioArtifactPath: nil,
                    retryCount: entry.retryCount + 1,
                    failureStage: nil
                )
                try await updateHistoryEntry(emptyEntry)
                await audioArchive.deleteArchivedAudio(at: audioArtifactPath)
                transition(to: .idle())
                recordingStartedAt = nil
                latestPartialText = ""
                return
            }

            let successEntry = DictationHistoryEntry.make(
                id: entry.id,
                startedAt: entry.startedAt,
                finishedAt: Date(),
                transcript: cleaned,
                duration: finalTranscript.duration,
                language: finalTranscript.language,
                status: .savedWithoutInsertion,
                audioArtifactPath: nil,
                retryCount: entry.retryCount + 1,
                failureStage: nil
            )
            try await updateHistoryEntry(successEntry)
            await audioArchive.deleteArchivedAudio(at: audioArtifactPath)
            transition(to: .idle(lastTranscript: cleaned, insertionResult: nil))

            recordingStartedAt = nil
            latestPartialText = ""
        } catch let error as AppError {
            let failedEntry = DictationHistoryEntry.make(
                id: entry.id,
                startedAt: entry.startedAt,
                finishedAt: Date(),
                transcript: latestPartialText,
                duration: max(Date().timeIntervalSince(entry.startedAt), 0),
                language: nil,
                status: .failed,
                statusDetail: error.userFacingDescription,
                audioArtifactPath: audioArtifactPath,
                retryCount: entry.retryCount + 1,
                failureStage: .transcription
            )
            try await updateHistoryEntry(failedEntry)
            await handleError(error)
        } catch {
            let failureError = AppError.transcriptionFailed(error.localizedDescription)
            let failedEntry = DictationHistoryEntry.make(
                id: entry.id,
                startedAt: entry.startedAt,
                finishedAt: Date(),
                transcript: latestPartialText,
                duration: max(Date().timeIntervalSince(entry.startedAt), 0),
                language: nil,
                status: .failed,
                statusDetail: failureError.userFacingDescription,
                audioArtifactPath: audioArtifactPath,
                retryCount: entry.retryCount + 1,
                failureStage: .transcription
            )
            try await updateHistoryEntry(failedEntry)
            await handleError(failureError)
        }
    }

    private func persistFailureIfNeeded(_ error: AppError, startedAt: Date) async {
        let transcript = latestPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = max(Date().timeIntervalSince(startedAt), 0)
        let entry = DictationHistoryEntry.make(
            startedAt: startedAt,
            transcript: transcript,
            duration: duration,
            language: nil,
            status: .failed,
            statusDetail: error.userFacingDescription
        )
        try? await persistHistoryEntry(entry)
        recordingStartedAt = nil
        latestPartialText = ""
    }

    private func historyStatus(for result: InsertionResult) -> DictationHistoryStatus {
        switch result {
        case .success:
            return .inserted
        case .clipboardFallback:
            return .clipboardFallback
        case .failure:
            return .failed
        }
    }

    private func historyStatusDetail(for result: InsertionResult) -> String? {
        switch result {
        case .success, .clipboardFallback:
            return nil
        case .failure(let error):
            return error.userFacingDescription
        }
    }

    private func transition(to newState: DictationSessionState) {
        state = newState
        stateBroadcast.yield(newState)
    }
}
