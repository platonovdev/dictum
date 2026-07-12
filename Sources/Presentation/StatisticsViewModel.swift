import Application
import Domain
import Foundation

public struct DailyWordCount: Identifiable, Equatable {
    public let date: Date
    public let words: Int

    public var id: Date { date }
}

@MainActor
public final class StatisticsViewModel: ObservableObject {
    @Published public private(set) var totalDuration: TimeInterval = 0
    @Published public private(set) var totalWords = 0
    @Published public private(set) var entryCount = 0
    @Published public private(set) var dailyWordCounts: [DailyWordCount] = []
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

        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let firstDay = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let successfulEntries = entries.filter(\.countsTowardStatistics)
        let wordsByDay = Dictionary(grouping: successfulEntries) {
            calendar.startOfDay(for: $0.startedAt)
        }.mapValues { dayEntries in
            dayEntries.reduce(0) { $0 + $1.wordCount }
        }

        dailyWordCounts = (0..<30).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstDay) else {
                return nil
            }
            return DailyWordCount(date: date, words: wordsByDay[date, default: 0])
        }
    }
}
