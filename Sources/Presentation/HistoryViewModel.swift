import AppKit
import Application
import Domain
import Foundation

@MainActor
public final class HistoryViewModel: ObservableObject {
    @Published public private(set) var entries: [DictationHistoryEntry] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var actionEntryID: UUID?

    private let coordinator: DictationSessionCoordinating
    private let clipboardWriter: ClipboardWriting
    private var tasks: [Task<Void, Never>] = []

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
            statusMessage = "This item has no transcript to copy."
            return
        }

        Task { @MainActor in
            await clipboardWriter.copy(text: transcript)
            statusMessage = "Transcript copied to clipboard."
            errorMessage = nil
        }
    }

    public func retry(_ entry: DictationHistoryEntry) {
        guard entry.isRetryable else {
            statusMessage = "Retry is only available when archived audio still exists."
            return
        }

        Task { @MainActor in
            actionEntryID = entry.id
            await coordinator.retryHistoryEntry(id: entry.id)
            actionEntryID = nil
            statusMessage = "Retry finished."
        }
    }

    public func delete(_ entry: DictationHistoryEntry) {
        Task { @MainActor in
            actionEntryID = entry.id
            await coordinator.deleteHistoryEntry(id: entry.id)
            actionEntryID = nil
            statusMessage = "Entry deleted."
        }
    }
}
