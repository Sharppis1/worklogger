import CSQLite
import Foundation

private final class DatabaseHandle: @unchecked Sendable {
    let pointer: OpaquePointer?

    init(_ pointer: OpaquePointer?) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}

public enum PersistenceError: Error, CustomStringConvertible {
    case open(String)
    case sqlite(String)
    case encoding

    public var description: String {
        switch self {
        case .open(let message): "Unable to open local database: \(message)"
        case .sqlite(let message): "SQLite error: \(message)"
        case .encoding: "Unable to encode persisted value"
        }
    }
}

public actor SQLiteStore {
    private let handle: DatabaseHandle
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let privateRetentionHours: Int

    public init(url: URL, privateRetentionHours: Int) throws {
        self.privateRetentionHours = privateRetentionHours
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        if sqlite3_open(url.path, &database) != SQLITE_OK {
            throw PersistenceError.open(Self.errorMessage(database))
        }
        handle = DatabaseHandle(database)
        try Self.initialize(database, sql: """
            PRAGMA journal_mode=WAL;
            PRAGMA foreign_keys=ON;
            CREATE TABLE IF NOT EXISTS observations (
                id TEXT PRIMARY KEY,
                occurred_at REAL NOT NULL,
                payload BLOB NOT NULL,
                privacy TEXT NOT NULL,
                synced_at REAL
            );
            CREATE TABLE IF NOT EXISTS corrections (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                effective_from REAL NOT NULL,
                effective_until REAL,
                payload BLOB NOT NULL,
                synced_at REAL
            );
            CREATE TABLE IF NOT EXISTS classified_intervals (
                id TEXT PRIMARY KEY,
                started_at REAL NOT NULL,
                ended_at REAL NOT NULL,
                state TEXT NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS intervals_time_idx
                ON classified_intervals(started_at, ended_at);
            """)
    }

    public func save(_ observation: Observation, privacy: String) throws {
        let payload = try encoder.encode(observation)
        try run(
            "INSERT OR IGNORE INTO observations(id, occurred_at, payload, privacy) VALUES(?, ?, ?, ?)",
            [.text(observation.id.uuidString), .double(observation.occurredAt.timeIntervalSince1970), .blob(payload), .text(privacy)]
        )
    }

    public func save(_ correction: ManualCorrection) throws {
        let payload = try encoder.encode(correction)
        try run(
            """
            INSERT OR IGNORE INTO corrections(
                id, created_at, effective_from, effective_until, payload
            ) VALUES(?, ?, ?, ?, ?)
            """,
            [
                .text(correction.id.uuidString),
                .double(correction.createdAt.timeIntervalSince1970),
                .double(correction.effectiveFrom.timeIntervalSince1970),
                correction.effectiveUntil.map { .double($0.timeIntervalSince1970) } ?? .null,
                .blob(payload)
            ]
        )
    }

    public func save(_ interval: ClassifiedInterval) throws {
        guard interval.endedAt > interval.startedAt else { return }
        let payload = try encoder.encode(interval)
        try run(
            """
            INSERT OR IGNORE INTO classified_intervals(
                id, started_at, ended_at, state, payload
            ) VALUES(?, ?, ?, ?, ?)
            """,
            [
                .text(interval.id.uuidString),
                .double(interval.startedAt.timeIntervalSince1970),
                .double(interval.endedAt.timeIntervalSince1970),
                .text(interval.classification.state.rawValue),
                .blob(payload)
            ]
        )
    }

    public func activeCorrection(at date: Date) throws -> ManualCorrection? {
        let rows = try query(
            """
            SELECT payload FROM corrections
            WHERE effective_from <= ?
              AND (effective_until IS NULL OR effective_until > ?)
              AND kind_is_not_resume(payload)
            ORDER BY created_at DESC LIMIT 1
            """.replacingOccurrences(of: " AND kind_is_not_resume(payload)", with: ""),
            [.double(date.timeIntervalSince1970), .double(date.timeIntervalSince1970)]
        )
        return try rows.first.flatMap { try decoder.decode(ManualCorrection.self, from: $0) }
    }

    public func pendingObservations(limit: Int = 200) throws -> [Observation] {
        let rows = try query(
            "SELECT payload FROM observations WHERE synced_at IS NULL ORDER BY occurred_at LIMIT ?",
            [.int(Int64(limit))]
        )
        return try rows.map { try decoder.decode(Observation.self, from: $0) }
    }

    public func pendingCorrections(limit: Int = 200) throws -> [ManualCorrection] {
        let rows = try query(
            "SELECT payload FROM corrections WHERE synced_at IS NULL ORDER BY created_at LIMIT ?",
            [.int(Int64(limit))]
        )
        return try rows.map { try decoder.decode(ManualCorrection.self, from: $0) }
    }

    public func markObservationSynced(id: UUID, at date: Date = Date()) throws {
        try run(
            "UPDATE observations SET synced_at = ? WHERE id = ?",
            [.double(date.timeIntervalSince1970), .text(id.uuidString)]
        )
    }

    public func markCorrectionSynced(id: UUID, at date: Date = Date()) throws {
        try run(
            "UPDATE corrections SET synced_at = ? WHERE id = ?",
            [.double(date.timeIntervalSince1970), .text(id.uuidString)]
        )
    }

    public func totals(for day: Date, calendar: Calendar = .current) throws -> DailyTotals {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return DailyTotals() }
        let rows = try query(
            """
            SELECT payload FROM classified_intervals
            WHERE ended_at > ? AND started_at < ?
            ORDER BY started_at
            """,
            [.double(start.timeIntervalSince1970), .double(end.timeIntervalSince1970)]
        )
        var totals = DailyTotals()
        for data in rows {
            let interval = try decoder.decode(ClassifiedInterval.self, from: data)
            let seconds = max(0, min(interval.endedAt, end).timeIntervalSince(max(interval.startedAt, start)))
            switch interval.classification.state {
            case .work: totals.work += seconds
            case .meeting: totals.meeting += seconds
            case .uncertain: totals.uncertain += seconds
            case .nonWork: totals.nonWork += seconds
            case .breakTime: totals.breakTime += seconds
            case .paused: break
            }
        }
        return totals
    }

    public func purgeExpiredPrivateDetails(now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-TimeInterval(privateRetentionHours * 3600))
        try run(
            "DELETE FROM observations WHERE privacy = 'private' AND occurred_at < ?",
            [.double(cutoff.timeIntervalSince1970)]
        )
    }

    private enum Value {
        case text(String)
        case double(Double)
        case int(Int64)
        case blob(Data)
        case null
    }

    private nonisolated static func initialize(_ database: OpaquePointer?, sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(database, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? Self.errorMessage(database)
            sqlite3_free(error)
            throw PersistenceError.sqlite(message)
        }
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle.pointer, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PersistenceError.sqlite(Self.errorMessage(handle.pointer))
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PersistenceError.sqlite(Self.errorMessage(handle.pointer))
        }
    }

    private func query(_ sql: String, _ values: [Value]) throws -> [Data] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle.pointer, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PersistenceError.sqlite(Self.errorMessage(handle.pointer))
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var rows: [Data] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            rows.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        }
        return rows
    }

    private func bind(_ values: [Value], to statement: OpaquePointer?) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let string):
                result = sqlite3_bind_text(statement, index, string, -1, transient)
            case .double(let number):
                result = sqlite3_bind_double(statement, index, number)
            case .int(let number):
                result = sqlite3_bind_int64(statement, index, number)
            case .blob(let data):
                result = data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient)
                }
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                throw PersistenceError.sqlite(Self.errorMessage(handle.pointer))
            }
        }
    }

    private static func errorMessage(_ database: OpaquePointer?) -> String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
    }
}
