import Domain
import Foundation
import OSLog

@MainActor
public final class DictationSessionCoordinator: DictationSessionCoordinating {
    private enum Constants {
        static let minimumSpeechDuration: TimeInterval = 0.35
        static let transientResetDelay: Duration = .milliseconds(900)
        static let quickTapMaxDuration: TimeInterval = 0.25
        static let doublePressWindow: TimeInterval = 0.35
        static let processingTimeoutFloor: TimeInterval = 120
        static let processingTimeoutMultiplier: TimeInterval = 2
        static let processingTimeoutGrace: TimeInterval = 30
    }

    private enum HotkeyGestureState: Equatable {
        case idle
        case pressing
        case handsFree
        case acceptingDoubleTap
    }

    private let transcriptionEngine: SpeechTranscriptionEngine
    private let audioCaptureService: AudioCaptureService
    private let insertionService: TextInsertionService
    private let permissionService: PermissionService
    private let settingsStore: SettingsStore
    private let historyStore: DictationHistoryStore
    private let audioArchive: DictationAudioArchive
    private let soundFeedbackService: DictationSoundFeedbackService?
    private let logger = Logger(subsystem: "com.dictator.app", category: "dictation-session")

    private let stateBroadcast = AsyncBroadcast<DictationSessionState>()
    private let partialBroadcast = AsyncBroadcast<String>()
    private let meterBroadcast = AsyncBroadcast<AudioMeterFrame>()

    private var state: DictationSessionState = .idle()
    private var settings: AppSettings = .default
    private var levelTask: Task<Void, Never>?
    private var isModelPrepared = false
    private var recordingModelPreparationTask: Task<Void, Never>?
    private var recordingModelPreparationError: AppError?
    private var activeSessionID = UUID()
    private var recordingStartedAt: Date?
    private var latestPartialText: String = ""
    private var hotkeyGestureState: HotkeyGestureState = .idle
    private var hotkeyPressStartedAt: TimeInterval?
    private var lastShortTapAt: TimeInterval?
    private var modelIdleUnloadTask: Task<Void, Never>?
    private var processingWatchdogTask: Task<Void, Never>?
    private var activeArchivedAudio: ArchivedAudio?

    public init(
        transcriptionEngine: SpeechTranscriptionEngine,
        audioCaptureService: AudioCaptureService,
        insertionService: TextInsertionService,
        permissionService: PermissionService,
        settingsStore: SettingsStore,
        historyStore: DictationHistoryStore,
        audioArchive: DictationAudioArchive = FileSystemDictationAudioArchive(),
        soundFeedbackService: DictationSoundFeedbackService? = nil
    ) {
        self.transcriptionEngine = transcriptionEngine
        self.audioCaptureService = audioCaptureService
        self.insertionService = insertionService
        self.permissionService = permissionService
        self.settingsStore = settingsStore
        self.historyStore = historyStore
        self.audioArchive = audioArchive
        self.soundFeedbackService = soundFeedbackService
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
        meterBroadcast.stream(bufferingPolicy: .bufferingNewest(1))
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
            await handleHotkeyPressed(at: ProcessInfo.processInfo.systemUptime)
        case .released:
            await handleHotkeyReleased(at: ProcessInfo.processInfo.systemUptime)
        case .pressedAt(let timestamp):
            await handleHotkeyPressed(at: timestamp)
        case .releasedAt(let timestamp):
            await handleHotkeyReleased(at: timestamp)
        case .lockRecording:
            await lockCurrentRecording()
        case .escapePressed:
            await handleEscapePressed()
        }
    }

    public func prepare() async {
        do {
            settings = try await settingsStore.load()
            await recoverInterruptedRecordings()
            try? await enforceHistoryRetention()
            await cleanupUnreferencedAudio()
            try await ensureModelPrepared(named: settings.modelIdentifier)
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
            try await enforceHistoryRetention()
            await cleanupUnreferencedAudio()

            if modelChanged {
                cancelScheduledModelUnload()
                isModelPrepared = false
                try await ensureModelPrepared(named: updatedSettings.modelIdentifier)
            }

            scheduleModelUnloadIfNeeded(resetExisting: true)

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
        cancelScheduledModelUnload()
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
            let sessionID = UUID()
            activeSessionID = sessionID
            latestPartialText = ""

            try await audioCaptureService.startRecording()
            guard isCurrent(sessionID) else {
                await audioCaptureService.cancelRecording()
                return
            }

            let startedAt = Date()
            recordingStartedAt = startedAt
            logger.info("Recording started for session \(sessionID.uuidString, privacy: .public)")
            transition(to: .recording(startedAt: startedAt))
            soundFeedbackService?.playRecordingStarted(
                theme: settings.feedbackSoundTheme,
                volume: settings.feedbackSoundVolume
            )
            forwardLevelEvents(for: sessionID)

            // Never make a thought wait for a model wake-up. If idle memory
            // management unloaded it, capture audio immediately and warm the
            // model in parallel. `stopDictation` waits only before decoding.
            if !isModelPrepared {
                prepareModelWhileRecording(named: settings.modelIdentifier)
            }
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

        hotkeyGestureState = .idle
        hotkeyPressStartedAt = nil
        lastShortTapAt = nil

        let sessionID = activeSessionID
        let startedAt = recordingStartedAt ?? Date()
        levelTask?.cancel()
        transition(to: .transcribing(partialText: nil))

        do {
            let capturedAudio = try await audioCaptureService.stopRecording()
            guard isCurrent(sessionID) else {
                return
            }
            soundFeedbackService?.playProcessingStarted(
                theme: settings.feedbackSoundTheme,
                volume: settings.feedbackSoundVolume
            )
            logger.info(
                "Recording finalized for session \(sessionID.uuidString, privacy: .public), duration \(capturedAudio.duration, format: .fixed(precision: 2))s"
            )

            // Never discard a normal-length recording because a lightweight
            // real-time VAD missed quiet speech. Whisper performs the final
            // speech/no-speech decision; this gate only rejects accidental taps.
            if capturedAudio.duration < Constants.minimumSpeechDuration {
                let recoveryAudio = await archiveAudioForRecovery(
                    capturedAudio,
                    entryID: sessionID
                )
                try await persistHistoryEntry(
                    DictationHistoryEntry.make(
                        id: sessionID,
                        startedAt: startedAt,
                        transcript: "",
                        duration: capturedAudio.duration,
                        language: nil,
                        status: .emptyTranscript,
                        statusDetail: AppError.emptyTranscript.userFacingDescription,
                        audioArtifactPath: recoveryAudio?.fileURL.path
                    )
                )
                transition(to: .idle())
                recordingStartedAt = nil
                latestPartialText = ""
                return
            }

            let archivedAudio: ArchivedAudio
            do {
                archivedAudio = try await audioArchive.archive(capturedAudio, for: sessionID)
                activeArchivedAudio = archivedAudio
                startProcessingWatchdog(for: sessionID, audioDuration: archivedAudio.duration)
                logger.info("Audio archived for session \(sessionID.uuidString, privacy: .public)")
            } catch let error as AppError {
                let recoveryPath = FileManager.default.fileExists(atPath: capturedAudio.fileURL.path)
                    ? capturedAudio.fileURL.path
                    : nil
                try await persistFailedHistoryEntry(
                    id: sessionID,
                    startedAt: startedAt,
                    duration: capturedAudio.duration,
                    transcript: latestPartialText,
                    error: error,
                    audioArtifactPath: recoveryPath,
                    retryCount: 0,
                    failureStage: .persistence
                )
                await handleError(error)
                return
            } catch {
                let failureError = AppError.audioArchiveFailed(error.localizedDescription)
                let recoveryPath = FileManager.default.fileExists(atPath: capturedAudio.fileURL.path)
                    ? capturedAudio.fileURL.path
                    : nil
                try await persistFailedHistoryEntry(
                    id: sessionID,
                    startedAt: startedAt,
                    duration: capturedAudio.duration,
                    transcript: latestPartialText,
                    error: failureError,
                    audioArtifactPath: recoveryPath,
                    retryCount: 0,
                    failureStage: .persistence
                )
                await handleError(failureError)
                return
            }

            let finalTranscript: FinalTranscript
            do {
                try await waitForModelPreparedAfterRecording()
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
                guard isCurrent(sessionID) else {
                    return
                }
                let recoveryAudio = await retainedAudioForHistory(
                    from: archivedAudio,
                    entryID: sessionID,
                    forceRetain: true
                )
                try await persistFailedHistoryEntry(
                    id: sessionID,
                    startedAt: startedAt,
                    duration: archivedAudio.duration,
                    transcript: latestPartialText,
                    error: error,
                    audioArtifactPath: recoveryAudio?.fileURL.path,
                    retryCount: 0,
                    failureStage: .transcription
                )
                await deleteOriginalArchiveIfNeeded(original: archivedAudio, retained: recoveryAudio)
                await handleError(error)
                return
            } catch {
                guard isCurrent(sessionID) else {
                    return
                }
                let failureError = AppError.transcriptionFailed(error.localizedDescription)
                let recoveryAudio = await retainedAudioForHistory(
                    from: archivedAudio,
                    entryID: sessionID,
                    forceRetain: true
                )
                try await persistFailedHistoryEntry(
                    id: sessionID,
                    startedAt: startedAt,
                    duration: archivedAudio.duration,
                    transcript: latestPartialText,
                    error: failureError,
                    audioArtifactPath: recoveryAudio?.fileURL.path,
                    retryCount: 0,
                    failureStage: .transcription
                )
                await deleteOriginalArchiveIfNeeded(original: archivedAudio, retained: recoveryAudio)
                await handleError(failureError)
                return
            }

            guard isCurrent(sessionID) else {
                return
            }
            logger.info(
                "Transcription completed for session \(sessionID.uuidString, privacy: .public) in \(finalTranscript.transcriptionDuration, format: .fixed(precision: 2))s"
            )

            let cleaned = finalTranscript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                let retainedAudio = await retainedAudioForHistory(
                    from: archivedAudio,
                    entryID: sessionID,
                    forceRetain: true
                )
                try await persistHistoryEntry(
                    DictationHistoryEntry.make(
                        id: sessionID,
                        startedAt: startedAt,
                        transcript: "",
                        duration: finalTranscript.duration,
                        language: finalTranscript.language,
                        status: .emptyTranscript,
                        statusDetail: AppError.emptyTranscript.userFacingDescription,
                        audioArtifactPath: retainedAudio?.fileURL.path,
                        transcriptionBackend: finalTranscript.backend,
                        transcriptionDuration: finalTranscript.transcriptionDuration
                    )
                )
                await deleteOriginalArchiveIfNeeded(original: archivedAudio, retained: retainedAudio)
                transition(to: .idle())
                recordingStartedAt = nil
                latestPartialText = ""
                return
            }

            let retainedAudio = await retainedAudioForHistory(from: archivedAudio, entryID: sessionID)

            if settings.autoPaste {
                transition(to: .inserting(text: cleaned))
                await Task.yield()
                let insertionText = settings.appendTrailingSpace ? cleaned + " " : cleaned
                let result = await insertionService.insert(text: insertionText)
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
                            audioArtifactPath: retainedAudio?.fileURL.path,
                            transcriptionBackend: finalTranscript.backend,
                            transcriptionDuration: finalTranscript.transcriptionDuration
                        )
                    )
                    await deleteOriginalArchiveIfNeeded(original: archivedAudio, retained: retainedAudio)
                    transition(to: .idle(lastTranscript: cleaned, insertionResult: result))
                case .failure(let error):
                    try await persistFailedHistoryEntry(
                        id: sessionID,
                        startedAt: startedAt,
                        duration: finalTranscript.duration,
                        transcript: cleaned,
                        error: error,
                        audioArtifactPath: retainedAudio?.fileURL.path,
                        retryCount: 0,
                        failureStage: .insertion
                    )
                    await deleteOriginalArchiveIfNeeded(original: archivedAudio, retained: retainedAudio)
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
                        audioArtifactPath: retainedAudio?.fileURL.path,
                        transcriptionBackend: finalTranscript.backend,
                        transcriptionDuration: finalTranscript.transcriptionDuration
                    )
                )
                await deleteOriginalArchiveIfNeeded(original: archivedAudio, retained: retainedAudio)
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
        let interruptedArchivedAudio = activeArchivedAudio
        let interruptedSessionID = activeSessionID
        let interruptedStartedAt = recordingStartedAt
        if interruptedArchivedAudio != nil {
            activeSessionID = UUID()
            if let cancellableEngine = transcriptionEngine as? CancellableSpeechTranscriptionEngine {
                await cancellableEngine.cancelCurrentTranscription()
                isModelPrepared = false
            }
        }

        if let archivedAudio = interruptedArchivedAudio,
           case .transcribing = state,
           let startedAt = interruptedStartedAt {
            let retainedAudio = await retainedAudioForHistory(
                from: archivedAudio,
                entryID: interruptedSessionID,
                forceRetain: true
            )
            try? await persistFailedHistoryEntry(
                id: interruptedSessionID,
                startedAt: startedAt,
                duration: archivedAudio.duration,
                transcript: latestPartialText,
                error: .transcriptionFailed("Processing was interrupted. The recording is safe and can be retried."),
                audioArtifactPath: retainedAudio?.fileURL.path,
                retryCount: 0,
                failureStage: .transcription
            )
            await deleteOriginalArchiveIfNeeded(original: archivedAudio, retained: retainedAudio)
        }
        cancelProcessingWatchdog()
        activeArchivedAudio = nil
        activeSessionID = UUID()
        levelTask?.cancel()
        levelTask = nil
        hotkeyGestureState = .idle
        hotkeyPressStartedAt = nil
        lastShortTapAt = nil
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
                if entry.audioArtifactPath != nil {
                    var repairedEntry = entry
                    repairedEntry.audioArtifactPath = nil
                    if entry.needsRecoveryAudio {
                        repairedEntry.status = .failed
                        repairedEntry.statusDetail = "The saved recording is no longer available."
                        repairedEntry.failureStage = .persistence
                    }
                    try await historyStore.update(repairedEntry)
                }
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
                    self.meterBroadcast.yield(meterFrame)
                }
            }
        }
    }

    private func handleHotkeyPressed(at eventTimestamp: TimeInterval) async {
        hotkeyPressStartedAt = eventTimestamp

        switch hotkeyGestureState {
        case .idle:
            if !isErrorState {
                guard case .idle = state else {
                    return
                }
            }
            await startDictation()
            hotkeyGestureState = .pressing
        case .pressing:
            return
        case .handsFree:
            if let lastShortTapAt,
               eventTimestamp - lastShortTapAt <= Constants.doublePressWindow {
                // Preserve the old double-tap gesture as a harmless
                // confirmation of hands-free mode, rather than stopping the
                // brand-new single-tap recording immediately.
                hotkeyGestureState = .acceptingDoubleTap
                return
            }
            hotkeyGestureState = .idle
            await stopDictation()
        case .acceptingDoubleTap:
            return
        }
    }

    private func handleEscapePressed() async {
        guard hotkeyGestureState == .handsFree, case .recording = state else {
            return
        }
        hotkeyGestureState = .idle
        hotkeyPressStartedAt = nil
        lastShortTapAt = nil
        await resetSession()
    }

    private func handleHotkeyReleased(at eventTimestamp: TimeInterval) async {
        guard case .recording = state else {
            hotkeyPressStartedAt = nil
            return
        }

        if hotkeyGestureState == .handsFree {
            hotkeyPressStartedAt = nil
            return
        }

        if hotkeyGestureState == .acceptingDoubleTap {
            hotkeyGestureState = .handsFree
            hotkeyPressStartedAt = nil
            return
        }

        let startedAt = hotkeyPressStartedAt ?? eventTimestamp
        hotkeyPressStartedAt = nil

        let heldFor = max(eventTimestamp - startedAt, 0)
        if heldFor > Constants.quickTapMaxDuration {
            hotkeyGestureState = .idle
            lastShortTapAt = nil
            await stopDictation()
            return
        }

        // A short tap is the predictable hands-free toggle. The next press
        // stops it; a rapid second tap remains a no-op compatibility gesture.
        hotkeyGestureState = .handsFree
        lastShortTapAt = eventTimestamp
        if case .recording(let startedAt, _) = state {
            transition(to: .recording(startedAt: startedAt, isHandsFree: true))
        }
    }

    private func lockCurrentRecording() async {
        guard hotkeyGestureState == .pressing,
              case .recording(let startedAt, _) = state else {
            return
        }
        hotkeyGestureState = .handsFree
        hotkeyPressStartedAt = nil
        lastShortTapAt = nil
        transition(to: .recording(startedAt: startedAt, isHandsFree: true))
    }

    private var isErrorState: Bool {
        if case .error = state {
            return true
        }
        return false
    }

    private func handleError(_ error: AppError) async {
        logger.error("Session failed: \(error.userFacingDescription, privacy: .public)")
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
        try await enforceHistoryRetention()
    }

    private func updateHistoryEntry(_ entry: DictationHistoryEntry) async throws {
        try await historyStore.update(entry)
    }

    private func removeHistoryEntry(id: UUID) async throws {
        try await historyStore.delete(id: id)
    }

    private func retainedAudioForHistory(
        from archivedAudio: ArchivedAudio,
        entryID: UUID,
        forceRetain: Bool = false
    ) async -> ArchivedAudio? {
        guard forceRetain || settings.audioRetention != .none else {
            return nil
        }
        do {
            return try await audioArchive.createRetainedAudioCopy(from: archivedAudio, for: entryID)
        } catch {
            return archivedAudio
        }
    }

    private func archiveAudioForRecovery(
        _ capturedAudio: CapturedAudio,
        entryID: UUID
    ) async -> ArchivedAudio? {
        do {
            let archivedAudio = try await audioArchive.archive(capturedAudio, for: entryID)
            let retainedAudio = await retainedAudioForHistory(
                from: archivedAudio,
                entryID: entryID,
                forceRetain: true
            )
            await deleteOriginalArchiveIfNeeded(original: archivedAudio, retained: retainedAudio)
            return retainedAudio
        } catch {
            // A move to Application Support can fail (for example, during a
            // transient disk error). The recorder's source is still safer than
            // discarding the only recoverable copy.
            guard FileManager.default.fileExists(atPath: capturedAudio.fileURL.path) else {
                return nil
            }
            return ArchivedAudio(fileURL: capturedAudio.fileURL, duration: capturedAudio.duration)
        }
    }

    private func deleteOriginalArchiveIfNeeded(original: ArchivedAudio, retained: ArchivedAudio?) async {
        guard let retained else {
            await audioArchive.deleteArchivedAudio(at: original.fileURL.path)
            return
        }

        guard original.fileURL.path != retained.fileURL.path else {
            return
        }

        await audioArchive.deleteArchivedAudio(at: original.fileURL.path)
    }

    private func enforceHistoryRetention(now: Date = Date()) async throws {
        let entries = try await historyStore.loadEntries().sorted { $0.startedAt > $1.startedAt }

        for entry in entries where entry.audioArtifactPath != nil
            && !entry.needsRecoveryAudio
            // A successful retry gives an older recovery recording a fresh
            // retention window; otherwise it could be deleted immediately.
            && !settings.audioRetention.keepsAudio(startedAt: entry.finishedAt, now: now) {
            if let path = entry.audioArtifactPath {
                await audioArchive.deleteArchivedAudio(at: path)
            }
            var withoutAudio = entry
            withoutAudio.audioArtifactPath = nil
            try await historyStore.update(withoutAudio)
        }

        for entry in entries.dropFirst(settings.historyLimit) {
            try await historyStore.delete(id: entry.id)
            if let path = entry.audioArtifactPath {
                await audioArchive.deleteArchivedAudio(at: path)
            }
        }
    }

    private func cleanupUnreferencedAudio(now: Date = Date()) async {
        let entries = (try? await historyStore.loadEntries()) ?? []
        let retainedPaths = Set(entries.compactMap(\.audioArtifactPath))
        await audioArchive.cleanupUnreferencedAudio(
            keepingPaths: retainedPaths,
            olderThan: now.addingTimeInterval(-3_600)
        )
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
        latestPartialText = ""
        recordingStartedAt = entry.startedAt
        transition(to: .transcribing(partialText: nil))
        startRetryWatchdog(for: entry)

        do {
            if !isModelPrepared {
                try await ensureModelPrepared(named: settings.modelIdentifier)
            }
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
                    audioArtifactPath: audioArtifactPath,
                    retryCount: entry.retryCount + 1,
                    failureStage: nil,
                    transcriptionBackend: finalTranscript.backend,
                    transcriptionDuration: finalTranscript.transcriptionDuration
                )
                try await updateHistoryEntry(emptyEntry)
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
                audioArtifactPath: audioArtifactPath,
                retryCount: entry.retryCount + 1,
                failureStage: nil,
                transcriptionBackend: finalTranscript.backend,
                transcriptionDuration: finalTranscript.transcriptionDuration
            )
            try await updateHistoryEntry(successEntry)
            try await enforceHistoryRetention()
            transition(to: .idle(lastTranscript: cleaned, insertionResult: nil))

            recordingStartedAt = nil
            latestPartialText = ""
        } catch let error as AppError {
            guard isCurrent(sessionID) else {
                return
            }
            let failedEntry = DictationHistoryEntry.make(
                id: entry.id,
                startedAt: entry.startedAt,
                finishedAt: Date(),
                transcript: latestPartialText,
                duration: entry.duration,
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
            guard isCurrent(sessionID) else {
                return
            }
            let failureError = AppError.transcriptionFailed(error.localizedDescription)
            let failedEntry = DictationHistoryEntry.make(
                id: entry.id,
                startedAt: entry.startedAt,
                finishedAt: Date(),
                transcript: latestPartialText,
                duration: entry.duration,
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

    private func prepareModelWhileRecording(named modelIdentifier: String) {
        guard recordingModelPreparationTask == nil else {
            return
        }

        recordingModelPreparationError = nil
        recordingModelPreparationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                // Deliberately discard progress here: the recording indicator
                // must stay in its live state while the user is speaking.
                try await self.transcriptionEngine.prepareModel(named: modelIdentifier) { _ in }
                self.isModelPrepared = true
                if case .idle = self.state {
                    self.scheduleModelUnloadIfNeeded()
                }
            } catch let error as AppError {
                self.recordingModelPreparationError = error
            } catch {
                self.recordingModelPreparationError = .modelUnavailable
            }
            self.recordingModelPreparationTask = nil
        }
    }

    private func waitForModelPreparedAfterRecording() async throws {
        if let task = recordingModelPreparationTask {
            await task.value
        }
        if let error = recordingModelPreparationError {
            recordingModelPreparationError = nil
            throw error
        }
        guard isModelPrepared else {
            throw AppError.modelUnavailable
        }
    }

    private func ensureModelPrepared(named modelIdentifier: String) async throws {
        guard !isModelPrepared else {
            return
        }
        prepareModelWhileRecording(named: modelIdentifier)
        if let task = recordingModelPreparationTask {
            await task.value
        }
        if let error = recordingModelPreparationError {
            recordingModelPreparationError = nil
            throw error
        }
        guard isModelPrepared else {
            throw AppError.modelUnavailable
        }
    }

    private func transition(to newState: DictationSessionState) {
        state = newState
        stateBroadcast.yield(newState)

        if case .idle = newState {
            cancelProcessingWatchdog()
            activeArchivedAudio = nil
            scheduleModelUnloadIfNeeded()
        } else if case .error = newState {
            cancelProcessingWatchdog()
            activeArchivedAudio = nil
        } else {
            cancelScheduledModelUnload()
        }
    }

    private func scheduleModelUnloadIfNeeded(resetExisting: Bool = false) {
        if resetExisting {
            cancelScheduledModelUnload()
        } else if modelIdleUnloadTask != nil {
            // Model preparation can finish while an idle transition is also
            // being delivered. Both paths request the same unload window; do
            // not create two concurrent tasks that can unload and re-prepare
            // the model twice when recording starts at that boundary.
            return
        }
        guard isModelPrepared, let idleDuration = settings.modelMemoryPolicy.idleDuration else {
            return
        }

        modelIdleUnloadTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: idleDuration)
            } catch {
                return
            }
            guard let self, self.isModelPrepared, case .idle = self.state else {
                return
            }

            await self.transcriptionEngine.unloadModel()
            // Once unload has started, always mirror the engine's real state.
            // The previous implementation returned early if recording began
            // during the await, leaving `isModelPrepared` incorrectly true.
            self.isModelPrepared = false
            self.modelIdleUnloadTask = nil

            if case .recording = self.state {
                self.prepareModelWhileRecording(named: self.settings.modelIdentifier)
            }
        }
    }

    private func cancelScheduledModelUnload() {
        modelIdleUnloadTask?.cancel()
        modelIdleUnloadTask = nil
    }

    private func startProcessingWatchdog(for sessionID: UUID, audioDuration: TimeInterval) {
        cancelProcessingWatchdog()
        let timeout = max(
            Constants.processingTimeoutFloor,
            (audioDuration * Constants.processingTimeoutMultiplier) + Constants.processingTimeoutGrace
        )
        processingWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            guard let self,
                  self.isCurrent(sessionID),
                  let archivedAudio = self.activeArchivedAudio,
                  let startedAt = self.recordingStartedAt else {
                return
            }
            guard case .transcribing = self.state else {
                return
            }

            self.logger.fault("Processing watchdog fired for session \(sessionID.uuidString, privacy: .public)")
            let timeoutError = AppError.transcriptionFailed(
                "Processing took too long. The recording is safe in History and can be retried."
            )
            self.activeSessionID = UUID()
            if let cancellableEngine = self.transcriptionEngine as? CancellableSpeechTranscriptionEngine {
                await cancellableEngine.cancelCurrentTranscription()
                self.isModelPrepared = false
            }
            let retainedAudio = await self.retainedAudioForHistory(
                from: archivedAudio,
                entryID: sessionID,
                forceRetain: true
            )
            try? await self.persistFailedHistoryEntry(
                id: sessionID,
                startedAt: startedAt,
                duration: archivedAudio.duration,
                transcript: self.latestPartialText,
                error: timeoutError,
                audioArtifactPath: retainedAudio?.fileURL.path,
                retryCount: 0,
                failureStage: .transcription
            )
            await self.deleteOriginalArchiveIfNeeded(original: archivedAudio, retained: retainedAudio)

            // Invalidate the still-running native decode. Its eventual result
            // is ignored, while the UI immediately becomes usable again.
            await self.handleError(timeoutError)
        }
    }

    private func cancelProcessingWatchdog() {
        processingWatchdogTask?.cancel()
        processingWatchdogTask = nil
    }

    private func startRetryWatchdog(for entry: DictationHistoryEntry) {
        cancelProcessingWatchdog()
        let sessionID = entry.id
        let timeout = max(
            Constants.processingTimeoutFloor,
            (entry.duration * Constants.processingTimeoutMultiplier) + Constants.processingTimeoutGrace
        )
        processingWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            guard let self, self.isCurrent(sessionID), case .transcribing = self.state else {
                return
            }

            self.logger.fault("Retry watchdog fired for session \(sessionID.uuidString, privacy: .public)")
            let timeoutError = AppError.transcriptionFailed(
                "Processing took too long. The saved recording is unchanged and can be retried."
            )
            self.activeSessionID = UUID()
            if let cancellableEngine = self.transcriptionEngine as? CancellableSpeechTranscriptionEngine {
                await cancellableEngine.cancelCurrentTranscription()
                self.isModelPrepared = false
            }
            let failedEntry = DictationHistoryEntry.make(
                id: entry.id,
                startedAt: entry.startedAt,
                finishedAt: Date(),
                transcript: self.latestPartialText,
                duration: entry.duration,
                language: nil,
                status: .failed,
                statusDetail: timeoutError.userFacingDescription,
                audioArtifactPath: entry.audioArtifactPath,
                retryCount: entry.retryCount + 1,
                failureStage: .transcription
            )
            try? await self.updateHistoryEntry(failedEntry)
            await self.handleError(timeoutError)
        }
    }

    private func recoverInterruptedRecordings() async {
        let recordings = await audioCaptureService.recoverPendingRecordings()
        guard !recordings.isEmpty else {
            return
        }

        let existingIDs = Set(((try? await historyStore.loadEntries()) ?? []).map(\.id))
        for recording in recordings {
            let recoveredID = UUID(uuidString: recording.fileURL.deletingPathExtension().lastPathComponent) ?? UUID()
            if existingIDs.contains(recoveredID) {
                try? FileManager.default.removeItem(at: recording.fileURL)
                continue
            }

            let modifiedAt = (try? recording.fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date()
            let startedAt = modifiedAt.addingTimeInterval(-recording.duration)
            let retainedAudio = await archiveAudioForRecovery(recording, entryID: recoveredID)
            let recoveryError = AppError.audioCaptureFailed(
                "Dictator recovered this recording after an interrupted session. Retry it from History."
            )
            do {
                try await persistHistoryEntry(
                    DictationHistoryEntry.make(
                        id: recoveredID,
                        startedAt: startedAt,
                        transcript: "",
                        duration: recording.duration,
                        language: nil,
                        status: .failed,
                        statusDetail: recoveryError.userFacingDescription,
                        audioArtifactPath: retainedAudio?.fileURL.path,
                        failureStage: .audioCapture
                    )
                )
                logger.notice("Recovered interrupted recording \(recoveredID.uuidString, privacy: .public)")
            } catch {
                logger.error("Could not register recovered recording \(recoveredID.uuidString, privacy: .public)")
            }
        }
    }
}
