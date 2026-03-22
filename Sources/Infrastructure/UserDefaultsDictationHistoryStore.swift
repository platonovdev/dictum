import Application
import Domain
import Foundation

@MainActor
public final class UserDefaultsDictationHistoryStore: DictationHistoryStore {
    private let defaults: UserDefaults
    private let key = "com.onebtnvoice.dictation-history"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let broadcast = AsyncBroadcast<[DictationHistoryEntry]>()
    private var cachedEntries: [DictationHistoryEntry]?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func makeEntriesStream() -> AsyncStream<[DictationHistoryEntry]> {
        let stream = broadcast.stream()
        let currentEntries = (try? loadEntriesFromStorage()) ?? []
        cachedEntries = currentEntries
        broadcast.yield(currentEntries)
        return stream
    }

    public func loadEntries() async throws -> [DictationHistoryEntry] {
        let entries = try loadEntriesFromStorage()
        cachedEntries = entries
        return entries
    }

    public func append(_ entry: DictationHistoryEntry) async throws {
        var entries = try loadEntriesFromStorage()
        entries.insert(entry, at: 0)
        try persist(entries)
    }

    public func update(_ entry: DictationHistoryEntry) async throws {
        var entries = try loadEntriesFromStorage()
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            throw AppError.historyPersistenceFailed("The history item no longer exists.")
        }
        entries[index] = entry
        entries.sort { $0.startedAt > $1.startedAt }
        try persist(entries)
    }

    public func delete(id: UUID) async throws {
        var entries = try loadEntriesFromStorage()
        entries.removeAll { $0.id == id }
        try persist(entries)
    }

    private func loadEntriesFromStorage() throws -> [DictationHistoryEntry] {
        guard let data = defaults.data(forKey: key) else {
            return []
        }

        return try decoder.decode([DictationHistoryEntry].self, from: data)
    }

    private func persist(_ entries: [DictationHistoryEntry]) throws {
        let data = try encoder.encode(entries)
        defaults.set(data, forKey: key)
        cachedEntries = entries
        broadcast.yield(entries)
    }
}
