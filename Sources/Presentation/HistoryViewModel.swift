import AppKit
import Application
@preconcurrency import AVFoundation
import Domain
import Foundation

@MainActor
public final class HistoryViewModel: ObservableObject {
    @Published public private(set) var entries: [DictationHistoryEntry] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var actionEntryID: UUID?
    @Published public private(set) var playingEntryID: UUID?

    private let coordinator: DictationSessionCoordinating
    private let clipboardWriter: ClipboardWriting
    private var tasks: [Task<Void, Never>] = []
    private var playbackTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?

    public init(
        coordinator: DictationSessionCoordinating,
        clipboardWriter: ClipboardWriting
    ) {
        self.coordinator = coordinator
        self.clipboardWriter = clipboardWriter

        tasks.append(Task { [weak self] in
            guard let self else {
                return
            }
            for await entries in coordinator.makeHistoryStream() {
                await MainActor.run {
                    self.entries = entries.sorted { $0.startedAt > $1.startedAt }
                    self.isLoading = false
                }
            }
        })

        Task { @MainActor in
            await reload()
        }
    }

    deinit {
        tasks.forEach { $0.cancel() }
        playbackTask?.cancel()
    }

    public func reload() async {
        isLoading = true
        let loadedEntries = await coordinator.loadHistoryEntries()
        entries = loadedEntries.sorted { $0.startedAt > $1.startedAt }
        errorMessage = nil
        isLoading = false
    }

    public func copyTranscript(for entry: DictationHistoryEntry) {
        let transcript = entry.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            statusMessage = L10n.text("This item has no text to copy.", "В этой записи нет текста для копирования.")
            return
        }

        Task { @MainActor in
            await clipboardWriter.copy(text: transcript)
            statusMessage = L10n.text("Text copied to clipboard.", "Текст скопирован в буфер обмена.")
            errorMessage = nil
        }
    }

    public func retry(_ entry: DictationHistoryEntry) {
        guard entry.isRetryable else {
            statusMessage = L10n.text("Retry is only available while the saved audio exists.", "Повтор возможен, пока сохранена аудиозапись.")
            return
        }

        Task { @MainActor in
            stopPlayback()
            actionEntryID = entry.id
            await coordinator.retryHistoryEntry(id: entry.id)
            actionEntryID = nil
            await reload()

            guard let updated = entries.first(where: { $0.id == entry.id }) else {
                errorMessage = L10n.text("The history item disappeared during retry.", "Запись исчезла из истории во время повтора.")
                statusMessage = nil
                return
            }
            switch updated.status {
            case .inserted, .clipboardFallback, .savedWithoutInsertion:
                statusMessage = updated.isRetryable
                    ? L10n.text("Recognition completed. The recording remains available.", "Распознавание завершено. Аудиозапись сохранена.")
                    : L10n.text("Recognition completed.", "Распознавание завершено.")
                errorMessage = nil
            case .emptyTranscript, .failed:
                errorMessage = updated.statusDetail ?? L10n.text("Recognition produced no text. The recording is still saved.", "Текст не распознан. Аудиозапись сохранена.")
                statusMessage = nil
            }
        }
    }

    public func togglePlayback(for entry: DictationHistoryEntry) {
        if playingEntryID == entry.id {
            stopPlayback()
            return
        }
        guard let path = entry.audioArtifactPath,
              FileManager.default.fileExists(atPath: path) else {
            errorMessage = L10n.text("The saved recording is no longer available.", "Сохранённая аудиозапись больше недоступна.")
            statusMessage = nil
            return
        }

        do {
            stopPlayback()
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            player.prepareToPlay()
            guard player.play() else {
                throw AppError.audioArchiveFailed(L10n.text("Playback could not start.", "Не удалось начать воспроизведение."))
            }
            audioPlayer = player
            playingEntryID = entry.id
            errorMessage = nil
            statusMessage = L10n.text("Playing saved recording.", "Воспроизводится сохранённая запись.")
            playbackTask = Task { @MainActor [weak self] in
                while let self, self.audioPlayer?.isPlaying == true, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                }
                guard !Task.isCancelled else { return }
                self?.stopPlayback(clearMessage: false)
                self?.statusMessage = L10n.text("Playback finished.", "Воспроизведение завершено.")
            }
        } catch {
            errorMessage = "\(L10n.text("Could not play the saved recording", "Не удалось воспроизвести сохранённую запись")): \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    public func stopPlayback(clearMessage: Bool = true) {
        playbackTask?.cancel()
        playbackTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        playingEntryID = nil
        if clearMessage, statusMessage == L10n.text("Playing saved recording.", "Воспроизводится сохранённая запись.") {
            statusMessage = nil
        }
    }

    public func delete(_ entry: DictationHistoryEntry) {
        Task { @MainActor in
            if playingEntryID == entry.id {
                stopPlayback()
            }
            actionEntryID = entry.id
            await coordinator.deleteHistoryEntry(id: entry.id)
            actionEntryID = nil
            await reload()
            if entries.contains(where: { $0.id == entry.id }) {
                errorMessage = L10n.text("The dictation could not be deleted.", "Не удалось удалить диктовку.")
                statusMessage = nil
            } else {
                statusMessage = L10n.text("Dictation and its saved recording were deleted.", "Диктовка и сохранённая аудиозапись удалены.")
                errorMessage = nil
            }
        }
    }
}
