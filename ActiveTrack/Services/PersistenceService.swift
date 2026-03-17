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
    private let modelContext: ModelContext
    private let databaseURL: URL?
    private(set) var startupWarning: String?

    init(modelContext: ModelContext, storeURL: URL? = nil) {
        self.modelContext = modelContext
        self.databaseURL = storeURL
        self.startupWarning = runStartupChecks()
    }

    // MARK: - CRUD

    @discardableResult
    func createInterval(startDate: Date = .now) throws -> ActiveInterval {
        guard databaseURL != nil else {
            let interval = ActiveInterval(startDate: startDate)
            modelContext.insert(interval)
            do {
                try modelContext.save()
                return interval
            } catch {
                throw PersistenceError.saveFailed(underlying: error.localizedDescription)
            }
        }

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
        guard databaseURL != nil else {
            interval.endDate = endDate
            do {
                try modelContext.save()
                return
            } catch {
                throw PersistenceError.saveFailed(underlying: error.localizedDescription)
            }
        }

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
        guard databaseURL != nil else {
            modelContext.delete(interval)
            do {
                try modelContext.save()
                return
            } catch {
                throw PersistenceError.saveFailed(underlying: error.localizedDescription)
            }
        }

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

    func resetToday() throws {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: .now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        guard databaseURL != nil else {
            let all = fetchAllIntervals()
            for interval in all {
                if interval.startDate >= dayStart && interval.startDate < dayEnd {
                    modelContext.delete(interval)
                } else if interval.startDate < dayStart,
                          (interval.endDate == nil || interval.endDate! > dayStart) {
                    interval.endDate = dayStart
                }
            }
            do {
                try modelContext.save()
                return
            } catch {
                throw PersistenceError.saveFailed(underlying: error.localizedDescription)
            }
        }

        do {
            try withWritableStore { db in
                _ = try executeUpdate(
                    db: db,
                    sql: """
                    UPDATE ZACTIVEINTERVAL
                    SET ZENDDATE = ?1, Z_OPT = Z_OPT + 1
                    WHERE ZSTARTDATE < ?1
                      AND (ZENDDATE IS NULL OR ZENDDATE > ?1)
                    """,
                    bind: { statement in
                        sqlite3_bind_double(statement, 1, dayStart.timeIntervalSinceReferenceDate)
                    }
                )
                _ = try executeUpdate(
                    db: db,
                    sql: """
                    DELETE FROM ZACTIVEINTERVAL
                    WHERE ZSTARTDATE >= ?1
                      AND ZSTARTDATE < ?2
                    """,
                    bind: { statement in
                        sqlite3_bind_double(statement, 1, dayStart.timeIntervalSinceReferenceDate)
                        sqlite3_bind_double(statement, 2, dayEnd.timeIntervalSinceReferenceDate)
                    }
                )
                try syncPrimaryKey(db: db)
            }
        } catch {
            throw PersistenceError.saveFailed(underlying: String(describing: error))
        }
    }

    func fetchOpenInterval() -> ActiveInterval? {
        guard databaseURL != nil else {
            return fetchAllIntervals().first(where: { $0.endDate == nil })
        }

        let snapshots = fetchAllSnapshots()
        guard let open = snapshots.last(where: { $0.endDate == nil }) else { return nil }
        return ActiveInterval(startDate: open.startDate, endDate: nil)
    }

    func fetchAllIntervals() -> [ActiveInterval] {
        guard databaseURL != nil else {
            let descriptor = FetchDescriptor<ActiveInterval>()
            let fetched = (try? modelContext.fetch(descriptor)) ?? []
            return fetched.sorted { $0.startDate > $1.startDate }
        }

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
        guard days > 0 else { return [] }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let firstDay = calendar.date(byAdding: .day, value: -(days - 1), to: today),
              let rangeEnd = calendar.date(byAdding: .day, value: 1, to: today) else {
            return []
        }
        let snapshots = fetchSnapshotsOverlapping(start: firstDay, end: rangeEnd)

        return (0..<days).compactMap { offset in
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: firstDay),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                return nil
            }
            let duration = durationForRange(start: dayStart, end: dayEnd, snapshots: snapshots)
            return DailyTotal(date: dayStart, duration: duration)
        }
    }

    func weeklyTotals(weeks: Int = 12) -> [WeeklyTotal] {
        guard weeks > 0 else { return [] }
        let calendar = Calendar.current
        let todayComponents = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: .now)
        guard let currentWeekStart = calendar.date(from: todayComponents) else { return [] }
        guard let firstWeekStart = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: currentWeekStart),
              let rangeEnd = calendar.date(byAdding: .day, value: 7, to: currentWeekStart) else {
            return []
        }
        let snapshots = fetchSnapshotsOverlapping(start: firstWeekStart, end: rangeEnd)

        return (0..<weeks).compactMap { offset in
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: offset, to: firstWeekStart),
                  let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) else {
                return nil
            }
            let duration = durationForRange(start: weekStart, end: weekEnd, snapshots: snapshots)
            return WeeklyTotal(weekStart: weekStart, duration: duration)
        }
    }

    func monthlyTotals(months: Int = 12) -> [MonthlyTotal] {
        guard months > 0 else { return [] }
        let calendar = Calendar.current
        let todayComponents = calendar.dateComponents([.year, .month], from: .now)
        guard let currentMonthStart = calendar.date(from: todayComponents) else { return [] }
        guard let firstMonthStart = calendar.date(byAdding: .month, value: -(months - 1), to: currentMonthStart),
              let rangeEnd = calendar.date(byAdding: .month, value: 1, to: currentMonthStart) else {
            return []
        }
        let snapshots = fetchSnapshotsOverlapping(start: firstMonthStart, end: rangeEnd)

        return (0..<months).compactMap { offset in
            guard let monthStart = calendar.date(byAdding: .month, value: offset, to: firstMonthStart),
                  let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
                return nil
            }
            let duration = durationForRange(start: monthStart, end: monthEnd, snapshots: snapshots)
            return MonthlyTotal(monthStart: monthStart, duration: duration)
        }
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
        if databaseURL != nil {
            return readSnapshots(rangeStart: nil, rangeEnd: nil)
        }

        return fetchAllIntervals()
            .map { IntervalSnapshot(startDate: $0.startDate, endDate: $0.endDate) }
            .sorted { $0.startDate < $1.startDate }
    }

    private func fetchSnapshotsOverlapping(start: Date, end: Date) -> [IntervalSnapshot] {
        if databaseURL != nil {
            return readSnapshots(rangeStart: start, rangeEnd: end)
        }

        return fetchAllSnapshots().filter { snapshot in
            snapshot.startDate < end && (snapshot.endDate == nil || snapshot.endDate! > start)
        }
    }

    private func readSnapshots(rangeStart: Date?, rangeEnd: Date?) -> [IntervalSnapshot] {
        guard let databaseURL else { return [] }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

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

    private func runStartupChecks() -> String? {
        guard databaseURL != nil else { return nil }

        var warning: String?
        do {
            try withWritableStore { db in
                let integrity = try querySingleText(db: db, sql: "PRAGMA integrity_check")
                if integrity.lowercased() != "ok" {
                    warning = "Store integrity check reported issues. Tracking continues with recovery safeguards."
                    return
                }

                let openCount = try querySingleInt(
                    db: db,
                    sql: "SELECT COUNT(*) FROM ZACTIVEINTERVAL WHERE ZENDDATE IS NULL"
                )
                if openCount > 1 {
                    _ = try executeUpdate(
                        db: db,
                        sql: """
                        UPDATE ZACTIVEINTERVAL
                        SET ZENDDATE = ZSTARTDATE, Z_OPT = Z_OPT + 1
                        WHERE Z_PK IN (
                            SELECT Z_PK FROM ZACTIVEINTERVAL
                            WHERE ZENDDATE IS NULL
                            ORDER BY ZSTARTDATE DESC
                            LIMIT -1 OFFSET 1
                        )
                        """
                    )
                    warning = "Recovered \(openCount - 1) stale open sessions from a previous crash."
                }
            }
        } catch {
            warning = "Store startup check failed. Tracking continues, but reliability may be reduced."
        }

        return warning
    }

    private func withWritableStore(_ work: (OpaquePointer?) throws -> Void) throws {
        guard let databaseURL else {
            throw SQLitePersistenceFailure.openFailed("No sqlite store configured")
        }

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

    private func querySingleInt(
        db: OpaquePointer?,
        sql: String
    ) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            throw SQLitePersistenceFailure.prepareFailed(sqliteMessage(db: db))
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLitePersistenceFailure.stepFailed(sqliteMessage(db: db))
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func querySingleText(
        db: OpaquePointer?,
        sql: String
    ) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            throw SQLitePersistenceFailure.prepareFailed(sqliteMessage(db: db))
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLitePersistenceFailure.stepFailed(sqliteMessage(db: db))
        }
        guard let cString = sqlite3_column_text(statement, 0) else { return "" }
        return String(cString: cString)
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

    private func durationForRange(
        start: Date,
        end: Date,
        snapshots: [IntervalSnapshot]? = nil
    ) -> TimeInterval {
        let relevantSnapshots = snapshots ?? fetchSnapshotsOverlapping(start: start, end: end)
        return relevantSnapshots.reduce(0) { total, snapshot in
            total + clampedDuration(of: snapshot, dayStart: start, dayEnd: end)
        }
    }
}
