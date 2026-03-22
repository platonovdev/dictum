import Application
import Domain
import Foundation

@MainActor
public final class StatisticsViewModel: ObservableObject {
    @Published public private(set) var totalDuration: TimeInterval = 0
    @Published public private(set) var totalWords = 0
    @Published public private(set) var entryCount = 0
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?

    private let coordinator: DictationSessionCoordinating
    private var tasks: [Task<Void, Never>] = []

    public init(coordinator: DictationSessionCoordinating) {
        self.coordinator = coordinator

        tasks.append(Task { [weak self] in
            guard let self else {
                return
            }
            for await entries in coordinator.makeHistoryStream() {
                await MainActor.run {
                    self.apply(entries: entries)
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
        let entries = await coordinator.loadHistoryEntries()
        apply(entries: entries)
        errorMessage = nil
        isLoading = false
    }

    private func apply(entries: [DictationHistoryEntry]) {
        let statistics = DictationStatistics.make(from: entries)
        totalDuration = statistics.totalDuration
        totalWords = statistics.totalWords
        entryCount = entries.filter(\.countsTowardStatistics).count
    }
}
