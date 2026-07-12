import Domain
import Foundation

@MainActor
public final class DictationSessionCoordinator: DictationSessionCoordinating {
    private enum Constants {
        static let minimumSpeechDuration: TimeInterval = 0.35
        static let transientResetDelay: Duration = .milliseconds(900)
        static let quickTapMaxDuration: TimeInterval = 0.25
        static let doublePressWindow: TimeInterval = 0.35
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
    private var detectedSpeechDuration: TimeInterval = 0
    private var recordingStartedAt: Date?
    private var latestPartialText: String = ""
    private var hotkeyGestureState: HotkeyGestureState = .idle
    private var hotkeyPressStartedAt: TimeInterval?
    private var lastShortTapAt: TimeInterval?
    private var modelIdleUnloadTask: Task<Void, Never>?

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
            try? await enforceHistoryRetention()
            await cleanupUnreferencedAudio()
            try await prepareLocalModel(named: settings.modelIdentifier)
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
            try await enforceHistoryRetention()
            await cleanupUnreferencedAudio()

            if modelChanged {
                cancelScheduledModelUnload()
                try await prepareLocalModel(named: updatedSettings.modelIdentifier)
                isModelPrepared = true
            }

            scheduleModelUnloadIfNeeded()

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
            detectedSpeechDuration = 0
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

            if detectedSpeechDuration < Constants.minimumSpeechDuration || capturedAudio.duration < Constants.minimumSpeechDuration {
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
        activeSessionID = UUID()
        detectedSpeechDuration = 0
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
                    if meterFrame.isSpeechDetected {
                        self.detectedSpeechDuration += meterFrame.frameDuration
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
            && !settings.audioRetention.keepsAudio(startedAt: entry.startedAt, now: now) {
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
        detectedSpeechDuration = 0
        latestPartialText = ""
        recordingStartedAt = entry.startedAt
        transition(to: .transcribing(partialText: nil))

        do {
            if !isModelPrepared {
                try await prepareLocalModel(named: settings.modelIdentifier)
                isModelPrepared = true
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

    private func prepareLocalModel(named modelIdentifier: String) async throws {
        // Model preparation is intentionally silent. Recording starts first
        // when needed, and only actionable failures surface in the overlay.
        try await transcriptionEngine.prepareModel(named: modelIdentifier) { _ in }
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

    private func transition(to newState: DictationSessionState) {
        state = newState
        stateBroadcast.yield(newState)

        if case .idle = newState {
            scheduleModelUnloadIfNeeded()
        } else {
            cancelScheduledModelUnload()
        }
    }

    private func scheduleModelUnloadIfNeeded() {
        cancelScheduledModelUnload()
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
}
