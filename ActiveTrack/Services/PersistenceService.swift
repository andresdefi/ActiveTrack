import Foundation
import SwiftData
import SQLite3

enum PersistenceError: Error, Equatable {
    case saveFailed(underlying: String)

    static func == (lhs: PersistenceError, rhs: PersistenceError) -> Bool {
        switch (lhs, rhs) {
        case let (.saveFailed(a), .saveFailed(b)):
            return a == b
        }
    }
}

struct DailyTotal: Identifiable {
    let date: Date
    let duration: TimeInterval
    var id: Date { date }
}

struct WeeklyTotal: Identifiable {
    let weekStart: Date
    let duration: TimeInterval
    var id: Date { weekStart }
}

struct MonthlyTotal: Identifiable {
    let monthStart: Date
    let duration: TimeInterval
    var id: Date { monthStart }
}

@MainActor
@Observable
final class PersistenceService {
    private let databaseURL: URL

    init(modelContext: ModelContext, storeURL: URL? = nil) {
        _ = modelContext
        self.databaseURL = storeURL ?? Self.fallbackStoreURL()
    }

    // MARK: - CRUD

    @discardableResult
    func createInterval(startDate: Date = .now) throws -> ActiveInterval {
        do {
            try withWritableStore { db in
                _ = try executeUpdate(
                    db: db,
                    sql: """
                    INSERT INTO ZACTIVEINTERVAL (Z_ENT, Z_OPT, ZSTARTDATE, ZENDDATE)
                    VALUES (1, 1, ?1, NULL)
                    """,
                    bind: { statement in
                        sqlite3_bind_double(statement, 1, startDate.timeIntervalSinceReferenceDate)
                    }
                )
                try syncPrimaryKey(db: db)
            }
            return ActiveInterval(startDate: startDate)
        } catch {
            throw PersistenceError.saveFailed(underlying: String(describing: error))
        }
    }

    func closeInterval(_ interval: ActiveInterval, endDate: Date = .now) throws {
        do {
            try withWritableStore { db in
                _ = try executeUpdate(
                    db: db,
                    sql: """
                    UPDATE ZACTIVEINTERVAL
                    SET ZENDDATE = ?1, Z_OPT = Z_OPT + 1
                    WHERE Z_PK = (
                        SELECT Z_PK
                        FROM ZACTIVEINTERVAL
                        WHERE ZENDDATE IS NULL
                        ORDER BY ZSTARTDATE DESC
                        LIMIT 1
                    )
                    """,
                    bind: { statement in
                        sqlite3_bind_double(statement, 1, endDate.timeIntervalSinceReferenceDate)
                    }
                )
            }
        } catch {
            throw PersistenceError.saveFailed(underlying: String(describing: error))
        }
    }

    func deleteInterval(_ interval: ActiveInterval) throws {
        do {
            try withWritableStore { db in
                _ = try executeUpdate(
                    db: db,
                    sql: """
                    DELETE FROM ZACTIVEINTERVAL
                    WHERE Z_PK = (
                        SELECT Z_PK
                        FROM ZACTIVEINTERVAL
                        WHERE ABS(ZSTARTDATE - ?1) < 0.001
                        ORDER BY Z_PK DESC
                        LIMIT 1
                    )
                    """,
                    bind: { statement in
                        sqlite3_bind_double(statement, 1, interval.startDate.timeIntervalSinceReferenceDate)
                    }
                )
                try syncPrimaryKey(db: db)
            }
        } catch {
            throw PersistenceError.saveFailed(underlying: String(describing: error))
        }
    }

    func fetchOpenInterval() -> ActiveInterval? {
        let snapshots = fetchAllSnapshots()
        guard let open = snapshots.last(where: { $0.endDate == nil }) else { return nil }
        return ActiveInterval(startDate: open.startDate, endDate: nil)
    }

    func fetchAllIntervals() -> [ActiveInterval] {
        let snapshots = fetchAllSnapshots()
        return snapshots.reversed().map { snapshot in
            ActiveInterval(startDate: snapshot.startDate, endDate: snapshot.endDate)
        }
    }

    // MARK: - Midnight-Splitting Aggregation

    func durationForDay(_ date: Date, completedOnly: Bool = false) -> TimeInterval {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        let snapshots = fetchSnapshotsOverlapping(start: dayStart, end: dayEnd)
        return snapshots.reduce(0) { total, snapshot in
            if completedOnly, snapshot.endDate == nil { return total }
            return total + clampedDuration(of: snapshot, dayStart: dayStart, dayEnd: dayEnd)
        }
    }

    func dailyTotals(days: Int = 14) -> [DailyTotal] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        return (0..<days).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let duration = durationForDay(date)
            return DailyTotal(date: date, duration: duration)
        }.reversed()
    }

    func weeklyTotals(weeks: Int = 12) -> [WeeklyTotal] {
        let calendar = Calendar.current
        let todayComponents = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: .now)
        guard let currentWeekStart = calendar.date(from: todayComponents) else { return [] }

        return (0..<weeks).compactMap { offset in
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: -offset, to: currentWeekStart) else { return nil }
            let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
            let duration = durationForRange(start: weekStart, end: weekEnd)
            return WeeklyTotal(weekStart: weekStart, duration: duration)
        }.reversed()
    }

    func monthlyTotals(months: Int = 12) -> [MonthlyTotal] {
        let calendar = Calendar.current
        let todayComponents = calendar.dateComponents([.year, .month], from: .now)
        guard let currentMonthStart = calendar.date(from: todayComponents) else { return [] }

        return (0..<months).compactMap { offset in
            guard let monthStart = calendar.date(byAdding: .month, value: -offset, to: currentMonthStart),
                  let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return nil }
            let duration = durationForRange(start: monthStart, end: monthEnd)
            return MonthlyTotal(monthStart: monthStart, duration: duration)
        }.reversed()
    }

    func intervalsForDay(_ date: Date) -> [(start: Date, end: Date, duration: TimeInterval)] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        let snapshots = fetchSnapshotsOverlapping(start: dayStart, end: dayEnd)
        return snapshots.compactMap { snapshot in
            let effectiveStart = max(snapshot.startDate, dayStart)
            let effectiveEnd = min(snapshot.endDate ?? .now, dayEnd)
            let duration = max(0, effectiveEnd.timeIntervalSince(effectiveStart))
            guard duration > 0 else { return nil }
            return (start: effectiveStart, end: effectiveEnd, duration: duration)
        }
    }

    func daysWithData() -> [Date] {
        daysWithData(from: fetchAllSnapshots())
    }

    // MARK: - Private Helpers

    private struct IntervalSnapshot {
        let startDate: Date
        let endDate: Date?
    }

    private func fetchAllSnapshots() -> [IntervalSnapshot] {
        readSnapshots(rangeStart: nil, rangeEnd: nil)
    }

    private func fetchSnapshotsOverlapping(start: Date, end: Date) -> [IntervalSnapshot] {
        readSnapshots(rangeStart: start, rangeEnd: end)
    }

    private func readSnapshots(rangeStart: Date?, rangeEnd: Date?) -> [IntervalSnapshot] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        try? ensureSchema(db: db)

        let sql: String
        if let rangeStart, let rangeEnd {
            sql = """
            SELECT ZSTARTDATE, ZENDDATE
            FROM ZACTIVEINTERVAL
            WHERE ZSTARTDATE < ?1
              AND (ZENDDATE IS NULL OR ZENDDATE > ?2)
            ORDER BY ZSTARTDATE
            """
            return runSnapshotQuery(
                db: db,
                sql: sql,
                bind: { statement in
                    sqlite3_bind_double(statement, 1, rangeEnd.timeIntervalSinceReferenceDate)
                    sqlite3_bind_double(statement, 2, rangeStart.timeIntervalSinceReferenceDate)
                }
            )
        } else {
            sql = """
            SELECT ZSTARTDATE, ZENDDATE
            FROM ZACTIVEINTERVAL
            ORDER BY ZSTARTDATE
            """
            return runSnapshotQuery(db: db, sql: sql, bind: { _ in })
        }
    }

    private func runSnapshotQuery(
        db: OpaquePointer?,
        sql: String,
        bind: (OpaquePointer?) -> Void
    ) -> [IntervalSnapshot] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            return []
        }
        defer { sqlite3_finalize(statement) }

        bind(statement)

        var snapshots: [IntervalSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { continue }
            let start = sqlite3_column_double(statement, 0)
            let end: Date?
            if sqlite3_column_type(statement, 1) == SQLITE_NULL {
                end = nil
            } else {
                end = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1))
            }
            snapshots.append(
                IntervalSnapshot(
                    startDate: Date(timeIntervalSinceReferenceDate: start),
                    endDate: end
                )
            )
        }
        return snapshots
    }

    private enum SQLitePersistenceFailure: Error {
        case openFailed(String)
        case prepareFailed(String)
        case stepFailed(String)
    }

    private func withWritableStore(_ work: (OpaquePointer?) throws -> Void) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = db.flatMap { sqliteMessage(db: $0) } ?? "Failed to open sqlite store"
            if let db { sqlite3_close(db) }
            throw SQLitePersistenceFailure.openFailed(message)
        }
        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, 1000)
        try ensureSchema(db: db)
        do {
            _ = try executeUpdate(db: db, sql: "BEGIN IMMEDIATE")
            try work(db)
            _ = try executeUpdate(db: db, sql: "COMMIT")
        } catch {
            _ = try? executeUpdate(db: db, sql: "ROLLBACK")
            throw error
        }
    }

    private func executeUpdate(
        db: OpaquePointer?,
        sql: String,
        bind: (OpaquePointer?) -> Void = { _ in }
    ) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            throw SQLitePersistenceFailure.prepareFailed(sqliteMessage(db: db))
        }
        defer { sqlite3_finalize(statement) }

        bind(statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLitePersistenceFailure.stepFailed(sqliteMessage(db: db))
        }
        return Int(sqlite3_changes(db))
    }

    private func sqliteMessage(db: OpaquePointer?) -> String {
        guard let db, let cMessage = sqlite3_errmsg(db) else {
            return "Unknown sqlite error"
        }
        return String(cString: cMessage)
    }

    private func syncPrimaryKey(db: OpaquePointer?) throws {
        _ = try executeUpdate(
            db: db,
            sql: """
            UPDATE Z_PRIMARYKEY
            SET Z_MAX = COALESCE((SELECT MAX(Z_PK) FROM ZACTIVEINTERVAL), 0)
            WHERE Z_NAME = 'ActiveInterval'
            """
        )
        _ = try executeUpdate(
            db: db,
            sql: """
            INSERT INTO Z_PRIMARYKEY (Z_ENT, Z_NAME, Z_SUPER, Z_MAX)
            SELECT 1, 'ActiveInterval', 0, COALESCE((SELECT MAX(Z_PK) FROM ZACTIVEINTERVAL), 0)
            WHERE NOT EXISTS (SELECT 1 FROM Z_PRIMARYKEY WHERE Z_NAME = 'ActiveInterval')
            """
        )
    }

    private func clampedDuration(of snapshot: IntervalSnapshot, dayStart: Date, dayEnd: Date) -> TimeInterval {
        let effectiveStart = max(snapshot.startDate, dayStart)
        let effectiveEnd = min(snapshot.endDate ?? .now, dayEnd)
        return max(0, effectiveEnd.timeIntervalSince(effectiveStart))
    }

    private func daysWithData(from snapshots: [IntervalSnapshot]) -> [Date] {
        let calendar = Calendar.current
        var daySet = Set<Date>()

        for snapshot in snapshots {
            let start = snapshot.startDate
            let end = snapshot.endDate ?? .now
            guard end > start else { continue }

            var cursor = calendar.startOfDay(for: start)
            while cursor < end {
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: cursor)!
                if clampedDuration(of: snapshot, dayStart: cursor, dayEnd: dayEnd) > 0 {
                    daySet.insert(cursor)
                }
                cursor = dayEnd
            }
        }

        return daySet.sorted(by: >)
    }

    private func ensureSchema(db: OpaquePointer?) throws {
        _ = try executeUpdate(
            db: db,
            sql: """
            CREATE TABLE IF NOT EXISTS ZACTIVEINTERVAL (
                Z_PK INTEGER PRIMARY KEY,
                Z_ENT INTEGER,
                Z_OPT INTEGER,
                ZENDDATE TIMESTAMP,
                ZSTARTDATE TIMESTAMP
            )
            """
        )
        _ = try executeUpdate(
            db: db,
            sql: """
            CREATE TABLE IF NOT EXISTS Z_PRIMARYKEY (
                Z_ENT INTEGER PRIMARY KEY,
                Z_NAME VARCHAR,
                Z_SUPER INTEGER,
                Z_MAX INTEGER
            )
            """
        )
        _ = try executeUpdate(
            db: db,
            sql: """
            INSERT OR IGNORE INTO Z_PRIMARYKEY (Z_ENT, Z_NAME, Z_SUPER, Z_MAX)
            VALUES (1, 'ActiveInterval', 0, 0)
            """
        )
    }

    private static func fallbackStoreURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ActiveTrack", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ActiveTrack.store")
    }

    private func durationForRange(start: Date, end: Date) -> TimeInterval {
        let calendar = Calendar.current
        var total: TimeInterval = 0
        var current = start
        while current < end {
            total += durationForDay(current)
            current = calendar.date(byAdding: .day, value: 1, to: current)!
        }
        return total
    }
}
