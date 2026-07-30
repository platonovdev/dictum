import Application
import Domain
import Foundation
import SQLite3

/// Row-oriented, transactional history storage. The transcript payload remains
/// Codable so future fields can be added without destructive schema changes,
/// while SQLite provides atomic commits, WAL recovery and indexed ordering.
@MainActor
public final class SQLiteDictationHistoryStore: DictationHistoryStore {
    private enum Constants {
        static let legacyMigrationKey = "legacy-user-defaults-import-v1"
    }

    private let databaseURL: URL
    private let legacyStore: UserDefaultsDictationHistoryStore?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let broadcast = AsyncBroadcast<[DictationHistoryEntry]>()
    // Access remains MainActor-confined; `nonisolated(unsafe)` only lets deinit
    // close SQLite's non-Sendable C pointer under Swift 6 isolation rules.
    nonisolated(unsafe) private var database: OpaquePointer?
    private var migrationChecked = false

    public convenience init(
        fileManager: FileManager = .default,
        legacyDefaults: UserDefaults = .standard
    ) {
        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directoryURL = applicationSupportURL.appendingPathComponent("Dictator", isDirectory: true)
        self.init(
            databaseURL: directoryURL.appendingPathComponent("History.sqlite3"),
            legacyStore: UserDefaultsDictationHistoryStore(defaults: legacyDefaults)
        )
    }

    public init(
        databaseURL: URL,
        legacyStore: UserDefaultsDictationHistoryStore? = nil
    ) {
        self.databaseURL = databaseURL
        self.legacyStore = legacyStore
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    public func makeEntriesStream() -> AsyncStream<[DictationHistoryEntry]> {
        let stream = broadcast.stream(bufferingPolicy: .bufferingNewest(1))
        Task { @MainActor [weak self] in
            guard let self, let entries = try? await self.loadEntries() else {
                return
            }
            self.broadcast.yield(entries)
        }
        return stream
    }

    public func loadEntries() async throws -> [DictationHistoryEntry] {
        try await ensureReady()
        return try readEntries()
    }

    public func append(_ entry: DictationHistoryEntry) async throws {
        try await ensureReady()
        try write(entry, replaceExisting: false)
        broadcast.yield(try readEntries())
    }

    public func update(_ entry: DictationHistoryEntry) async throws {
        try await ensureReady()
        let changed = try write(entry, replaceExisting: true)
        guard changed else {
            throw AppError.historyPersistenceFailed("The history item no longer exists.")
        }
        broadcast.yield(try readEntries())
    }

    public func delete(id: UUID) async throws {
        try await ensureReady()
        let statement = try prepare("DELETE FROM history_entries WHERE id = ?1;")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, at: 1, to: statement)
        try stepDone(statement)
        broadcast.yield(try readEntries())
    }

    private func ensureReady() async throws {
        try openDatabaseIfNeeded()
        guard !migrationChecked else {
            return
        }

        if try metadataValue(for: Constants.legacyMigrationKey) == nil {
            let legacyEntries = try await legacyStore?.loadEntries() ?? []
            try transaction {
                for entry in legacyEntries {
                    _ = try write(entry, replaceExisting: false, ignoreConflict: true)
                }
                try setMetadataValue("complete", for: Constants.legacyMigrationKey)
            }
        }
        migrationChecked = true
    }

    private func openDatabaseIfNeeded() throws {
        guard database == nil else {
            return
        }

        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        var openedDatabase: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &openedDatabase, flags, nil) == SQLITE_OK,
              let openedDatabase else {
            let message = openedDatabase.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error."
            if let openedDatabase {
                sqlite3_close_v2(openedDatabase)
            }
            throw AppError.historyPersistenceFailed(message)
        }
        database = openedDatabase
        sqlite3_busy_timeout(openedDatabase, 3_000)

        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=FULL;")
            try execute("PRAGMA foreign_keys=ON;")
            try execute("""
                CREATE TABLE IF NOT EXISTS history_entries (
                    id TEXT PRIMARY KEY NOT NULL,
                    started_at REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                """)
            try execute("CREATE INDEX IF NOT EXISTS history_started_at_idx ON history_entries(started_at DESC);")
            try execute("""
                CREATE TABLE IF NOT EXISTS metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                """)
            try execute("PRAGMA user_version=1;")
        } catch {
            sqlite3_close_v2(openedDatabase)
            database = nil
            throw error
        }
    }

    private func readEntries() throws -> [DictationHistoryEntry] {
        let statement = try prepare("SELECT payload FROM history_entries ORDER BY started_at DESC;")
        defer { sqlite3_finalize(statement) }

        var entries: [DictationHistoryEntry] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return entries
            }
            guard result == SQLITE_ROW else {
                throw databaseError()
            }
            guard let bytes = sqlite3_column_blob(statement, 0) else {
                throw AppError.historyPersistenceFailed("A history row contains no payload.")
            }
            let count = Int(sqlite3_column_bytes(statement, 0))
            do {
                entries.append(try decoder.decode(DictationHistoryEntry.self, from: Data(bytes: bytes, count: count)))
            } catch {
                throw AppError.historyPersistenceFailed("A history row could not be decoded: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    private func write(
        _ entry: DictationHistoryEntry,
        replaceExisting: Bool,
        ignoreConflict: Bool = false
    ) throws -> Bool {
        let sql: String
        if ignoreConflict {
            sql = "INSERT OR IGNORE INTO history_entries(id, started_at, payload) VALUES (?1, ?2, ?3);"
        } else if replaceExisting {
            sql = "UPDATE history_entries SET started_at = ?2, payload = ?3 WHERE id = ?1;"
        } else {
            sql = "INSERT INTO history_entries(id, started_at, payload) VALUES (?1, ?2, ?3);"
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let payload = try encoder.encode(entry)
        try bind(entry.id.uuidString, at: 1, to: statement)
        guard sqlite3_bind_double(statement, 2, entry.startedAt.timeIntervalSince1970) == SQLITE_OK else {
            throw databaseError()
        }
        let bindResult = payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
        guard bindResult == SQLITE_OK else {
            throw databaseError()
        }
        try stepDone(statement)
        return sqlite3_changes(database) > 0
    }

    private func metadataValue(for key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM metadata WHERE key = ?1;")
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            return nil
        }
        guard result == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            throw databaseError()
        }
        return String(cString: value)
    }

    private func setMetadataValue(_ value: String, for key: String) throws {
        let statement = try prepare("INSERT OR REPLACE INTO metadata(key, value) VALUES (?1, ?2);")
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        try bind(value, at: 2, to: statement)
        try stepDone(statement)
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else {
            throw AppError.historyPersistenceFailed("The history database is not open.")
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            throw AppError.historyPersistenceFailed(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else {
            throw AppError.historyPersistenceFailed("The history database is not open.")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError()
        }
        return statement
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
            throw databaseError()
        }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
        }
    }

    private func databaseError() -> AppError {
        guard let database else {
            return .historyPersistenceFailed("The history database is not open.")
        }
        return .historyPersistenceFailed(String(cString: sqlite3_errmsg(database)))
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
