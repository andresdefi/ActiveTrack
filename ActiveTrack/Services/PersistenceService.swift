import Foundation
import SwiftData
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum PersistenceError: Error, Equatable {
    case saveFailed(underlying: String)

    static func == (lhs: PersistenceError, rhs: PersistenceError) -> Bool {
        switch (lhs, rhs) {
        case let (.saveFailed(a), .saveFailed(b)):
            return a == b
        }
    }
}

struct DailyTotal: Identifiable, Sendable {
    let date: Date
    let duration: TimeInterval
    var id: Date { date }
}

struct WeeklyTotal: Identifiable, Sendable {
    let weekStart: Date
    let duration: TimeInterval
    var id: Date { weekStart }
}

struct MonthlyTotal: Identifiable, Sendable {
    let monthStart: Date
    let duration: TimeInterval
    var id: Date { monthStart }
}

struct HistoryChartData: Sendable {
    let daily: [DailyTotal]
    let weekly: [WeeklyTotal]
    let monthly: [MonthlyTotal]
}

struct DashboardHistorySnapshot: Sendable {
    let dayDurations: [Date: TimeInterval]
    let chartData: HistoryChartData
}

struct PersistenceChange: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case dayDurationsChanged
        case fullReload
    }

    let kind: Kind
    let affectedDays: Set<Date>

    init(kind: Kind, affectedDays: Set<Date> = []) {
        let calendar = Calendar.current
        self.kind = kind
        self.affectedDays = Set(affectedDays.map { calendar.startOfDay(for: $0) })
    }

    static let fullReload = PersistenceChange(kind: .fullReload)

    var requiresFullReload: Bool {
        kind == .fullReload
    }

    func affects(day: Date, calendar: Calendar = .current) -> Bool {
        requiresFullReload || affectedDays.contains(calendar.startOfDay(for: day))
    }
}

struct DayIntervalSummary: Identifiable, Sendable, Hashable {
    let start: Date
    let end: Date
    let duration: TimeInterval
    let isOpen: Bool

    var id: String {
        "\(isOpen ? "open" : "closed")-\(start.timeIntervalSinceReferenceDate)"
    }
}

private struct IntervalSnapshot: Sendable {
    let startDate: Date
    let endDate: Date?
}

private struct IntervalRecord: Sendable {
    let primaryKey: Int64
    let startDate: Date
    let endDate: Date?
}

private struct StartupCheckResult {
    let warning: String?
    let isDaySummaryReady: Bool
}

private func clampedDuration(of snapshot: IntervalSnapshot, dayStart: Date, dayEnd: Date) -> TimeInterval {
    let effectiveStart = max(snapshot.startDate, dayStart)
    let effectiveEnd = min(snapshot.endDate ?? .now, dayEnd)
    return max(0, effectiveEnd.timeIntervalSince(effectiveStart))
}

private func aggregatedClosedDayDurations(from snapshots: [IntervalSnapshot]) -> [Date: TimeInterval] {
    let calendar = Calendar.current
    var dayDurations: [Date: TimeInterval] = [:]

    for snapshot in snapshots where snapshot.endDate != nil {
        let start = snapshot.startDate
        let end = snapshot.endDate ?? .now
        guard end > start else { continue }

        var dayStart = calendar.startOfDay(for: start)
        while dayStart < end {
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let duration = clampedDuration(of: snapshot, dayStart: dayStart, dayEnd: dayEnd)
            if duration > 0 {
                dayDurations[dayStart, default: 0] += duration
            }
            dayStart = dayEnd
        }
    }

    return dayDurations
}

private func dayIntervalSummaries(
    from snapshots: [IntervalSnapshot],
    dayStart: Date,
    dayEnd: Date
) -> [DayIntervalSummary] {
    snapshots.compactMap { snapshot in
        let effectiveStart = max(snapshot.startDate, dayStart)
        let effectiveEnd = min(snapshot.endDate ?? .now, dayEnd)
        let duration = max(0, effectiveEnd.timeIntervalSince(effectiveStart))
        guard duration > 0 else { return nil }
        return DayIntervalSummary(
            start: effectiveStart,
            end: effectiveEnd,
            duration: duration,
            isOpen: snapshot.endDate == nil
        )
    }
}

private final class SQLiteReadConnection {
    private let databaseURL: URL
    private var db: OpaquePointer?

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func readSnapshots(rangeStart: Date?, rangeEnd: Date?) -> [IntervalSnapshot] {
        guard let db = ensureOpen() else { return [] }

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
        }

        sql = """
        SELECT ZSTARTDATE, ZENDDATE
        FROM ZACTIVEINTERVAL
        ORDER BY ZSTARTDATE
        """
        return runSnapshotQuery(db: db, sql: sql, bind: { _ in })
    }

    func readOpenSnapshots() -> [IntervalSnapshot] {
        guard let db = ensureOpen() else { return [] }
        return runSnapshotQuery(
            db: db,
            sql: """
            SELECT ZSTARTDATE, ZENDDATE
            FROM ZACTIVEINTERVAL
            WHERE ZENDDATE IS NULL
            ORDER BY ZSTARTDATE DESC
            """,
            bind: { _ in }
        )
    }

    func readMostRecentOpenSnapshot() -> IntervalSnapshot? {
        guard let db = ensureOpen() else { return nil }
        return runSnapshotQuery(
            db: db,
            sql: """
            SELECT ZSTARTDATE, ZENDDATE
            FROM ZACTIVEINTERVAL
            WHERE ZENDDATE IS NULL
            ORDER BY ZSTARTDATE DESC
            LIMIT 1
            """,
            bind: { _ in }
        ).first
    }

    func readDaySummaryDurations(rangeStart: Date?, rangeEnd: Date?) -> [Date: TimeInterval] {
        guard let db = ensureOpen() else { return [:] }

        var statement: OpaquePointer?
        let sql: String
        if rangeStart != nil, rangeEnd != nil {
            sql = """
            SELECT ZDAYSTART, ZCOMPLETEDDURATION
            FROM AT_DAY_SUMMARY
            WHERE ZDAYSTART >= ?1
              AND ZDAYSTART < ?2
            ORDER BY ZDAYSTART
            """
        } else {
            sql = """
            SELECT ZDAYSTART, ZCOMPLETEDDURATION
            FROM AT_DAY_SUMMARY
            ORDER BY ZDAYSTART
            """
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        if let rangeStart, let rangeEnd {
            sqlite3_bind_double(statement, 1, rangeStart.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(statement, 2, rangeEnd.timeIntervalSinceReferenceDate)
        }

        var summaries: [Date: TimeInterval] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let dayStart = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 0))
            let duration = sqlite3_column_double(statement, 1)
            summaries[dayStart] = duration
        }
        return summaries
    }

    private func ensureOpen() -> OpaquePointer? {
        if let db {
            return db
        }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }

        var opened: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &opened, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let opened { sqlite3_close(opened) }
            return nil
        }
        sqlite3_busy_timeout(opened, 1000)
        db = opened
        return opened
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
}

private actor SQLiteAsyncReader {
    private let connection: SQLiteReadConnection

    init(databaseURL: URL) {
        self.connection = SQLiteReadConnection(databaseURL: databaseURL)
    }

    func dayDurations(rangeStart: Date?, rangeEnd: Date?, summaryReady: Bool) -> [Date: TimeInterval] {
        if summaryReady {
            return connection.readDaySummaryDurations(rangeStart: rangeStart, rangeEnd: rangeEnd)
        }

        let snapshots = connection.readSnapshots(rangeStart: rangeStart, rangeEnd: rangeEnd)
        return aggregatedClosedDayDurations(from: snapshots)
    }

    func intervalsForDay(_ date: Date) -> [DayIntervalSummary] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        let snapshots = connection.readSnapshots(rangeStart: dayStart, rangeEnd: dayEnd)
        return dayIntervalSummaries(from: snapshots, dayStart: dayStart, dayEnd: dayEnd)
    }
}

@MainActor
@Observable
final class PersistenceService {
    private enum MetadataKey {
        static let daySummaryVersion = "day_summary_version"
        static let currentDaySummaryVersion = "1"
    }

    private let modelContext: ModelContext
    private let databaseURL: URL?
    private let readConnection: SQLiteReadConnection?
    private let asyncReader: SQLiteAsyncReader?
    private var writeConnection: OpaquePointer?
    private(set) var startupWarning: String?
    private var cachedDaySummaryDurations: [Date: TimeInterval]?
    private var isDaySummaryReady = true
    private var isPreparingDaySummary = false
    private var isRunningIntegrityCheck = false
    private var hasEnsuredWritableSchema = false

    init(modelContext: ModelContext, storeURL: URL? = nil) {
        self.modelContext = modelContext
        self.databaseURL = storeURL
        self.readConnection = storeURL.map(SQLiteReadConnection.init(databaseURL:))
        self.asyncReader = storeURL.map(SQLiteAsyncReader.init(databaseURL:))
        let startupCheck = runStartupChecks()
        self.startupWarning = startupCheck.warning
        self.isDaySummaryReady = startupCheck.isDaySummaryReady
        if storeURL != nil, !startupCheck.isDaySummaryReady {
            scheduleDaySummaryPreparation()
        }
        if storeURL != nil {
            scheduleBackgroundIntegrityCheck()
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let writeConnection {
                sqlite3_close(writeConnection)
            }
        }
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
            invalidateDaySummaryCache()
            return ActiveInterval(startDate: startDate)
        } catch {
            throw PersistenceError.saveFailed(underlying: String(describing: error))
        }
    }

    func closeInterval(_ interval: ActiveInterval, endDate: Date = .now) throws {
        guard databaseURL != nil else {
            let changedDays = affectedDays(from: interval.startDate, to: endDate)
            interval.endDate = endDate
            do {
                try modelContext.save()
                notifyPersistenceDidChange(PersistenceChange(kind: .dayDurationsChanged, affectedDays: changedDays))
                return
            } catch {
                throw PersistenceError.saveFailed(underlying: error.localizedDescription)
            }
        }

        do {
            var changedDays: Set<Date> = []
            try withWritableStore { db in
                guard let openRecord = try readMostRecentOpenIntervalRecord(db: db) else { return }
                changedDays = affectedDays(from: openRecord.startDate, to: endDate)
                _ = try executeUpdate(
                    db: db,
                    sql: """
                    UPDATE ZACTIVEINTERVAL
                    SET ZENDDATE = ?1, Z_OPT = Z_OPT + 1
                    WHERE Z_PK = ?2
                    """,
                    bind: { statement in
                        sqlite3_bind_double(statement, 1, endDate.timeIntervalSinceReferenceDate)
                        sqlite3_bind_int64(statement, 2, openRecord.primaryKey)
                    }
                )
                try applyDaySummaryDelta(startDate: openRecord.startDate, endDate: endDate, multiplier: 1, db: db)
            }
            invalidateDaySummaryCache()
            notifyPersistenceDidChange(PersistenceChange(kind: .dayDurationsChanged, affectedDays: changedDays))
        } catch {
            throw PersistenceError.saveFailed(underlying: String(describing: error))
        }
    }

    func deleteInterval(_ interval: ActiveInterval) throws {
        guard databaseURL != nil else {
            let changedDays = affectedDays(from: interval.startDate, to: interval.endDate)
            modelContext.delete(interval)
            do {
                try modelContext.save()
                if !changedDays.isEmpty {
                    notifyPersistenceDidChange(PersistenceChange(kind: .dayDurationsChanged, affectedDays: changedDays))
                }
                return
            } catch {
                throw PersistenceError.saveFailed(underlying: error.localizedDescription)
            }
        }

        do {
            var changedDays: Set<Date> = []
            try withWritableStore { db in
                guard let intervalRecord = try readIntervalRecord(db: db, matchingStartDate: interval.startDate) else { return }
                changedDays = affectedDays(from: intervalRecord.startDate, to: intervalRecord.endDate)
                _ = try executeUpdate(
                    db: db,
                    sql: """
                    DELETE FROM ZACTIVEINTERVAL
                    WHERE Z_PK = ?1
                    """,
                    bind: { statement in
                        sqlite3_bind_int64(statement, 1, intervalRecord.primaryKey)
                    }
                )
                if let endDate = intervalRecord.endDate {
                    try applyDaySummaryDelta(startDate: intervalRecord.startDate, endDate: endDate, multiplier: -1, db: db)
                }
                try syncPrimaryKey(db: db)
            }
            invalidateDaySummaryCache()
            if !changedDays.isEmpty {
                notifyPersistenceDidChange(PersistenceChange(kind: .dayDurationsChanged, affectedDays: changedDays))
            }
        } catch {
            throw PersistenceError.saveFailed(underlying: String(describing: error))
        }
    }

    func resetToday() throws {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: .now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let changedDays: Set<Date> = [dayStart]

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
                notifyPersistenceDidChange(PersistenceChange(kind: .dayDurationsChanged, affectedDays: changedDays))
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
                _ = try executeUpdate(
                    db: db,
                    sql: """
                    DELETE FROM AT_DAY_SUMMARY
                    WHERE ZDAYSTART = ?1
                    """,
                    bind: { statement in
                        sqlite3_bind_double(statement, 1, dayStart.timeIntervalSinceReferenceDate)
                    }
                )
                try syncPrimaryKey(db: db)
            }
            invalidateDaySummaryCache()
            notifyPersistenceDidChange(PersistenceChange(kind: .dayDurationsChanged, affectedDays: changedDays))
        } catch {
            throw PersistenceError.saveFailed(underlying: String(describing: error))
        }
    }

    func fetchOpenInterval() -> ActiveInterval? {
        fetchOpenIntervals().first
    }

    func fetchOpenIntervals() -> [ActiveInterval] {
        guard databaseURL != nil else {
            return fetchAllIntervals()
                .filter { $0.endDate == nil }
                .sorted { $0.startDate > $1.startDate }
        }

        let snapshots = readConnection?.readOpenSnapshots() ?? []
        return snapshots.map { ActiveInterval(startDate: $0.startDate, endDate: nil) }
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

        if databaseURL != nil {
            let completed = completedDayDurations(rangeStart: dayStart, rangeEnd: dayEnd)[dayStart] ?? 0
            guard !completedOnly else { return completed }
            guard let openSnapshot = readMostRecentOpenSnapshot() else { return completed }
            return completed + clampedDuration(of: openSnapshot, dayStart: dayStart, dayEnd: dayEnd)
        }

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
        let dayDurations = completedDayDurations(rangeStart: firstDay, rangeEnd: rangeEnd)
        return buildDailyTotals(days: days, dayDurations: dayDurations, calendar: calendar)
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
        let dayDurations = completedDayDurations(rangeStart: firstWeekStart, rangeEnd: rangeEnd)
        return buildWeeklyTotals(weeks: weeks, dayDurations: dayDurations, calendar: calendar)
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
        let dayDurations = completedDayDurations(rangeStart: firstMonthStart, rangeEnd: rangeEnd)
        return buildMonthlyTotals(months: months, dayDurations: dayDurations, calendar: calendar)
    }

    func intervalsForDay(_ date: Date) -> [(start: Date, end: Date, duration: TimeInterval)] {
        intervalSummariesForDay(date)
            .map { (start: $0.start, end: $0.end, duration: $0.duration) }
    }

    func daysWithData() -> [Date] {
        allDayDurations().keys.sorted(by: >)
    }

    func allDayDurations() -> [Date: TimeInterval] {
        completedDayDurations()
    }

    func allDayDurationsAsync() async -> [Date: TimeInterval] {
        await completedDayDurationsAsync()
    }

    func dashboardHistorySnapshotAsync(days: Int = 14, weeks: Int = 12, months: Int = 12) async -> DashboardHistorySnapshot {
        let dayDurations = await completedDayDurationsAsync()
        let chartData = chartData(from: dayDurations, days: days, weeks: weeks, months: months)
        return DashboardHistorySnapshot(dayDurations: dayDurations, chartData: chartData)
    }

    func dayDurationsAsync(for days: Set<Date>) async -> [Date: TimeInterval] {
        let calendar = Calendar.current
        let normalizedDays = Set(days.map { calendar.startOfDay(for: $0) })
        guard let firstDay = normalizedDays.min(),
              let lastDay = normalizedDays.max(),
              let rangeEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) else {
            return [:]
        }

        let dayDurations = await completedDayDurationsAsync(rangeStart: firstDay, rangeEnd: rangeEnd)
        var filtered: [Date: TimeInterval] = [:]
        for day in normalizedDays {
            if let duration = dayDurations[day], duration > 0.000_001 {
                filtered[day] = duration
            }
        }
        return filtered
    }

    func chartData(days: Int = 14, weeks: Int = 12, months: Int = 12) -> HistoryChartData {
        buildChartData(days: days, weeks: weeks, months: months) { rangeStart, rangeEnd in
            completedDayDurations(rangeStart: rangeStart, rangeEnd: rangeEnd)
        }
    }

    func chartData(
        from dayDurations: [Date: TimeInterval],
        days: Int = 14,
        weeks: Int = 12,
        months: Int = 12
    ) -> HistoryChartData {
        buildChartData(days: days, weeks: weeks, months: months) { rangeStart, rangeEnd in
            filteredDayDurations(dayDurations, rangeStart: rangeStart, rangeEnd: rangeEnd)
        }
    }

    func chartDataAsync(days: Int = 14, weeks: Int = 12, months: Int = 12) async -> HistoryChartData {
        let ranges = chartRanges(days: days, weeks: weeks, months: months)
        guard let rangeStart = ranges.rangeStart, let rangeEnd = ranges.rangeEnd else {
            return HistoryChartData(daily: [], weekly: [], monthly: [])
        }

        let calendar = Calendar.current
        let dayDurations = await completedDayDurationsAsync(rangeStart: rangeStart, rangeEnd: rangeEnd)
        return HistoryChartData(
            daily: buildDailyTotals(days: days, dayDurations: dayDurations, calendar: calendar),
            weekly: buildWeeklyTotals(weeks: weeks, dayDurations: dayDurations, calendar: calendar),
            monthly: buildMonthlyTotals(months: months, dayDurations: dayDurations, calendar: calendar)
        )
    }

    func intervalsForDayAsync(_ date: Date) async -> [(start: Date, end: Date, duration: TimeInterval)] {
        guard databaseURL != nil else {
            return intervalsForDay(date)
        }

        let intervals = await intervalSummariesForDayAsync(date)
        return intervals.map { (start: $0.start, end: $0.end, duration: $0.duration) }
    }

    func intervalSummariesForDay(_ date: Date) -> [DayIntervalSummary] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        let snapshots = fetchSnapshotsOverlapping(start: dayStart, end: dayEnd)
        return dayIntervalSummaries(from: snapshots, dayStart: dayStart, dayEnd: dayEnd)
    }

    func intervalSummariesForDayAsync(_ date: Date) async -> [DayIntervalSummary] {
        guard databaseURL != nil else {
            return intervalSummariesForDay(date)
        }

        return await asyncReader?.intervalsForDay(date) ?? []
    }

    // MARK: - Private Helpers

    private func buildChartData(
        days: Int,
        weeks: Int,
        months: Int,
        loader: (Date, Date) -> [Date: TimeInterval]
    ) -> HistoryChartData {
        let ranges = chartRanges(days: days, weeks: weeks, months: months)
        guard let rangeStart = ranges.rangeStart, let rangeEnd = ranges.rangeEnd else {
            return HistoryChartData(daily: [], weekly: [], monthly: [])
        }

        let calendar = Calendar.current
        let dayDurations = loader(rangeStart, rangeEnd)
        return HistoryChartData(
            daily: buildDailyTotals(days: days, dayDurations: dayDurations, calendar: calendar),
            weekly: buildWeeklyTotals(weeks: weeks, dayDurations: dayDurations, calendar: calendar),
            monthly: buildMonthlyTotals(months: months, dayDurations: dayDurations, calendar: calendar)
        )
    }

    private func chartRanges(
        days: Int,
        weeks: Int,
        months: Int
    ) -> (rangeStart: Date?, rangeEnd: Date?) {
        let calendar = Calendar.current
        var rangeStarts: [Date] = []
        var rangeEnds: [Date] = []

        if days > 0 {
            let today = calendar.startOfDay(for: .now)
            if let firstDay = calendar.date(byAdding: .day, value: -(days - 1), to: today),
               let rangeEnd = calendar.date(byAdding: .day, value: 1, to: today) {
                rangeStarts.append(firstDay)
                rangeEnds.append(rangeEnd)
            }
        }

        if weeks > 0 {
            let todayComponents = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: .now)
            if let currentWeekStart = calendar.date(from: todayComponents),
               let firstWeekStart = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: currentWeekStart),
               let rangeEnd = calendar.date(byAdding: .day, value: 7, to: currentWeekStart) {
                rangeStarts.append(firstWeekStart)
                rangeEnds.append(rangeEnd)
            }
        }

        if months > 0 {
            let todayComponents = calendar.dateComponents([.year, .month], from: .now)
            if let currentMonthStart = calendar.date(from: todayComponents),
               let firstMonthStart = calendar.date(byAdding: .month, value: -(months - 1), to: currentMonthStart),
               let rangeEnd = calendar.date(byAdding: .month, value: 1, to: currentMonthStart) {
                rangeStarts.append(firstMonthStart)
                rangeEnds.append(rangeEnd)
            }
        }

        return (rangeStarts.min(), rangeEnds.max())
    }

    private func fetchAllSnapshots() -> [IntervalSnapshot] {
        if databaseURL != nil {
            return readConnection?.readSnapshots(rangeStart: nil, rangeEnd: nil) ?? []
        }

        return fetchAllIntervals()
            .map { IntervalSnapshot(startDate: $0.startDate, endDate: $0.endDate) }
            .sorted { $0.startDate < $1.startDate }
    }

    private func fetchSnapshotsOverlapping(start: Date, end: Date) -> [IntervalSnapshot] {
        if databaseURL != nil {
            return readConnection?.readSnapshots(rangeStart: start, rangeEnd: end) ?? []
        }

        return fetchAllSnapshots().filter { snapshot in
            snapshot.startDate < end && (snapshot.endDate == nil || snapshot.endDate! > start)
        }
    }

    private func completedDayDurations(rangeStart: Date? = nil, rangeEnd: Date? = nil) -> [Date: TimeInterval] {
        guard databaseURL != nil else {
            let snapshots: [IntervalSnapshot]
            if let rangeStart, let rangeEnd {
                snapshots = fetchSnapshotsOverlapping(start: rangeStart, end: rangeEnd)
            } else {
                snapshots = fetchAllSnapshots()
            }
            return aggregatedClosedDayDurations(from: snapshots)
        }

        if isDaySummaryReady {
            guard let rangeStart, let rangeEnd else {
                return loadCachedDaySummaryDurations()
            }
            return readConnection?.readDaySummaryDurations(rangeStart: rangeStart, rangeEnd: rangeEnd) ?? [:]
        }

        if let rangeStart, let rangeEnd {
            let snapshots = readConnection?.readSnapshots(rangeStart: rangeStart, rangeEnd: rangeEnd) ?? []
            return aggregatedClosedDayDurations(from: snapshots)
        }
        return aggregatedClosedDayDurations(from: readConnection?.readSnapshots(rangeStart: nil, rangeEnd: nil) ?? [])
    }

    private func completedDayDurationsAsync(rangeStart: Date? = nil, rangeEnd: Date? = nil) async -> [Date: TimeInterval] {
        guard databaseURL != nil else {
            return completedDayDurations(rangeStart: rangeStart, rangeEnd: rangeEnd)
        }

        guard let asyncReader else {
            return completedDayDurations(rangeStart: rangeStart, rangeEnd: rangeEnd)
        }
        return await asyncReader.dayDurations(
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            summaryReady: isDaySummaryReady
        )
    }

    private func loadCachedDaySummaryDurations() -> [Date: TimeInterval] {
        if let cachedDaySummaryDurations {
            return cachedDaySummaryDurations
        }

        let loaded = readConnection?.readDaySummaryDurations(rangeStart: nil, rangeEnd: nil) ?? [:]
        cachedDaySummaryDurations = loaded
        return loaded
    }

    private func invalidateDaySummaryCache() {
        cachedDaySummaryDurations = nil
    }

    private func filteredDayDurations(
        _ dayDurations: [Date: TimeInterval],
        rangeStart: Date,
        rangeEnd: Date
    ) -> [Date: TimeInterval] {
        dayDurations.filter { day, _ in
            day >= rangeStart && day < rangeEnd
        }
    }

    private func affectedDays(from startDate: Date, to endDate: Date?) -> Set<Date> {
        guard let endDate, endDate > startDate else { return [] }

        let calendar = Calendar.current
        var affectedDays: Set<Date> = []
        var dayStart = calendar.startOfDay(for: startDate)

        while dayStart < endDate {
            affectedDays.insert(dayStart)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            dayStart = nextDay
        }

        return affectedDays
    }

    private func notifyPersistenceDidChange(_ change: PersistenceChange = .fullReload) {
        NotificationCenter.default.post(name: .activeTrackPersistenceDidChange, object: change)
    }

    private func readMostRecentOpenIntervalRecord(db: OpaquePointer?) throws -> IntervalRecord? {
        try readIntervalRecord(
            db: db,
            sql: """
            SELECT Z_PK, ZSTARTDATE, ZENDDATE
            FROM ZACTIVEINTERVAL
            WHERE ZENDDATE IS NULL
            ORDER BY ZSTARTDATE DESC
            LIMIT 1
            """
        ) { _ in }
    }

    private func readIntervalRecord(
        db: OpaquePointer?,
        matchingStartDate: Date
    ) throws -> IntervalRecord? {
        try readIntervalRecord(
            db: db,
            sql: """
            SELECT Z_PK, ZSTARTDATE, ZENDDATE
            FROM ZACTIVEINTERVAL
            WHERE ABS(ZSTARTDATE - ?1) < 0.001
            ORDER BY Z_PK DESC
            LIMIT 1
            """
        ) { statement in
            sqlite3_bind_double(statement, 1, matchingStartDate.timeIntervalSinceReferenceDate)
        }
    }

    private func readIntervalRecord(
        db: OpaquePointer?,
        sql: String,
        bind: (OpaquePointer?) -> Void
    ) throws -> IntervalRecord? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            throw SQLitePersistenceFailure.prepareFailed(sqliteMessage(db: db))
        }
        defer { sqlite3_finalize(statement) }

        bind(statement)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard sqlite3_column_type(statement, 1) != SQLITE_NULL else { return nil }

        let primaryKey = sqlite3_column_int64(statement, 0)
        let startDate = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1))
        let endDate: Date?
        if sqlite3_column_type(statement, 2) == SQLITE_NULL {
            endDate = nil
        } else {
            endDate = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2))
        }
        return IntervalRecord(primaryKey: primaryKey, startDate: startDate, endDate: endDate)
    }

    private func applyDaySummaryDelta(
        startDate: Date,
        endDate: Date,
        multiplier: Double,
        db: OpaquePointer?
    ) throws {
        guard endDate > startDate else { return }

        let calendar = Calendar.current
        let snapshot = IntervalSnapshot(startDate: startDate, endDate: endDate)
        var dayStart = calendar.startOfDay(for: startDate)

        while dayStart < endDate {
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let delta = clampedDuration(of: snapshot, dayStart: dayStart, dayEnd: dayEnd) * multiplier
            if abs(delta) > 0.000_001 {
                _ = try executeUpdate(
                    db: db,
                    sql: """
                    INSERT INTO AT_DAY_SUMMARY (ZDAYSTART, ZCOMPLETEDDURATION)
                    VALUES (?1, ?2)
                    ON CONFLICT(ZDAYSTART) DO UPDATE
                    SET ZCOMPLETEDDURATION = ZCOMPLETEDDURATION + excluded.ZCOMPLETEDDURATION
                    """,
                    bind: { statement in
                        sqlite3_bind_double(statement, 1, dayStart.timeIntervalSinceReferenceDate)
                        sqlite3_bind_double(statement, 2, delta)
                    }
                )
                _ = try executeUpdate(
                    db: db,
                    sql: """
                    DELETE FROM AT_DAY_SUMMARY
                    WHERE ZDAYSTART = ?1
                      AND ZCOMPLETEDDURATION <= 0.000001
                    """,
                    bind: { statement in
                        sqlite3_bind_double(statement, 1, dayStart.timeIntervalSinceReferenceDate)
                    }
                )
            }
            dayStart = dayEnd
        }
    }

    private func readMostRecentOpenSnapshot() -> IntervalSnapshot? {
        readConnection?.readMostRecentOpenSnapshot()
    }

    private func readClosedSnapshots(db: OpaquePointer?) -> [IntervalSnapshot] {
        var statement: OpaquePointer?
        let sql = """
        SELECT ZSTARTDATE, ZENDDATE
        FROM ZACTIVEINTERVAL
        WHERE ZENDDATE IS NOT NULL
        ORDER BY ZSTARTDATE
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            return []
        }
        defer { sqlite3_finalize(statement) }

        var snapshots: [IntervalSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { continue }
            let startDate = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 0))
            let endDate = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1))
            snapshots.append(IntervalSnapshot(startDate: startDate, endDate: endDate))
        }
        return snapshots
    }

    private enum SQLitePersistenceFailure: Error {
        case openFailed(String)
        case prepareFailed(String)
        case stepFailed(String)
    }

    private func runStartupChecks() -> StartupCheckResult {
        guard databaseURL != nil else {
            return StartupCheckResult(warning: nil, isDaySummaryReady: true)
        }

        var warning: String?
        var summaryReady = true

        do {
            try withWritableStore { db in
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

                summaryReady = try daySummaryIsReady(db: db)
            }
        } catch {
            warning = "Store startup check failed. Tracking continues, but reliability may be reduced."
            summaryReady = false
        }

        return StartupCheckResult(warning: warning, isDaySummaryReady: summaryReady)
    }

    private func scheduleBackgroundIntegrityCheck() {
        guard let databaseURL, !isRunningIntegrityCheck else { return }
        isRunningIntegrityCheck = true

        Task {
            let warning = await Task.detached(priority: .utility) {
                PersistenceService.runIntegrityCheckInBackground(at: databaseURL)
            }.value

            isRunningIntegrityCheck = false
            guard let warning else { return }
            startupWarning = startupWarning ?? warning
        }
    }

    private func daySummaryIsReady(db: OpaquePointer?) throws -> Bool {
        let storedVersion = try queryOptionalText(
            db: db,
            sql: """
            SELECT ZVALUE
            FROM AT_METADATA
            WHERE ZKEY = ?1
            LIMIT 1
            """,
            bind: { statement in
                sqlite3_bind_text(statement, 1, MetadataKey.daySummaryVersion, -1, sqliteTransient)
            }
        )
        let summaryRowCount = try querySingleInt(db: db, sql: "SELECT COUNT(*) FROM AT_DAY_SUMMARY")
        let closedIntervalCount = try querySingleInt(
            db: db,
            sql: "SELECT COUNT(*) FROM ZACTIVEINTERVAL WHERE ZENDDATE IS NOT NULL"
        )
        return storedVersion == MetadataKey.currentDaySummaryVersion &&
            !(summaryRowCount == 0 && closedIntervalCount > 0)
    }

    private func withWritableStore(_ work: (OpaquePointer?) throws -> Void) throws {
        guard let databaseURL else {
            throw SQLitePersistenceFailure.openFailed("No sqlite store configured")
        }

        let db = try ensureWritableStoreOpen(databaseURL: databaseURL)

        if !hasEnsuredWritableSchema {
            try ensureSchema(db: db)
            hasEnsuredWritableSchema = true
        }
        do {
            _ = try executeUpdate(db: db, sql: "BEGIN IMMEDIATE")
            try work(db)
            _ = try executeUpdate(db: db, sql: "COMMIT")
        } catch {
            _ = try? executeUpdate(db: db, sql: "ROLLBACK")
            throw error
        }
    }

    private func ensureWritableStoreOpen(databaseURL: URL) throws -> OpaquePointer? {
        if let writeConnection {
            return writeConnection
        }

        var opened: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = opened.flatMap { sqliteMessage(db: $0) } ?? "Failed to open sqlite store"
            if let opened {
                sqlite3_close(opened)
            }
            throw SQLitePersistenceFailure.openFailed(message)
        }

        sqlite3_busy_timeout(opened, 1000)
        writeConnection = opened
        return opened
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

    private func queryOptionalText(
        db: OpaquePointer?,
        sql: String,
        bind: (OpaquePointer?) -> Void = { _ in }
    ) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            throw SQLitePersistenceFailure.prepareFailed(sqliteMessage(db: db))
        }
        defer { sqlite3_finalize(statement) }

        bind(statement)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: cString)
    }

    private func sqliteMessage(db: OpaquePointer?) -> String {
        guard let db, let cMessage = sqlite3_errmsg(db) else {
            return "Unknown sqlite error"
        }
        return String(cString: cMessage)
    }

    private func rebuildDaySummary(db: OpaquePointer?) throws {
        _ = try executeUpdate(db: db, sql: "DELETE FROM AT_DAY_SUMMARY")

        let closedSnapshots = readClosedSnapshots(db: db)
        let dayDurations = aggregatedClosedDayDurations(from: closedSnapshots)
        for (dayStart, duration) in dayDurations {
            _ = try executeUpdate(
                db: db,
                sql: """
                INSERT INTO AT_DAY_SUMMARY (ZDAYSTART, ZCOMPLETEDDURATION)
                VALUES (?1, ?2)
                """,
                bind: { statement in
                    sqlite3_bind_double(statement, 1, dayStart.timeIntervalSinceReferenceDate)
                    sqlite3_bind_double(statement, 2, duration)
                }
            )
        }
    }

    private func scheduleDaySummaryPreparation() {
        guard let databaseURL, !isDaySummaryReady, !isPreparingDaySummary else { return }
        isPreparingDaySummary = true

        Task {
            let warning = await Task.detached(priority: .utility) {
                PersistenceService.prepareDaySummaryInBackground(at: databaseURL)
            }.value

            isPreparingDaySummary = false
            if let warning {
                startupWarning = startupWarning ?? warning
            } else {
                isDaySummaryReady = true
                invalidateDaySummaryCache()
            }
            notifyPersistenceDidChange(.fullReload)
        }
    }

    nonisolated private static func runIntegrityCheckInBackground(at databaseURL: URL) -> String? {
        do {
            var db: OpaquePointer?
            guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                let message = db.flatMap(backgroundSQLiteMessage(db:)) ?? "Failed to open sqlite store"
                if let db { sqlite3_close(db) }
                throw SQLitePersistenceFailure.openFailed(message)
            }
            defer { sqlite3_close(db) }

            sqlite3_busy_timeout(db, 1000)
            let integrity = try backgroundQuerySingleText(db: db, sql: "PRAGMA integrity_check")
            guard integrity.lowercased() != "ok" else { return nil }
            return "Store integrity check reported issues. Tracking continues with recovery safeguards."
        } catch {
            return "Store integrity check failed in the background. Tracking continues with recovery safeguards."
        }
    }

    nonisolated private static func prepareDaySummaryInBackground(at databaseURL: URL) -> String? {
        do {
            try withBackgroundWritableStore(at: databaseURL) { db in
                let storedVersion = try backgroundQueryOptionalText(
                    db: db,
                    sql: """
                    SELECT ZVALUE
                    FROM AT_METADATA
                    WHERE ZKEY = ?1
                    LIMIT 1
                    """,
                    bind: { statement in
                        sqlite3_bind_text(statement, 1, MetadataKey.daySummaryVersion, -1, sqliteTransient)
                    }
                )
                let summaryRowCount = try backgroundQuerySingleInt(db: db, sql: "SELECT COUNT(*) FROM AT_DAY_SUMMARY")
                let closedIntervalCount = try backgroundQuerySingleInt(
                    db: db,
                    sql: "SELECT COUNT(*) FROM ZACTIVEINTERVAL WHERE ZENDDATE IS NOT NULL"
                )

                let needsRebuild = storedVersion != MetadataKey.currentDaySummaryVersion ||
                    (summaryRowCount == 0 && closedIntervalCount > 0)
                guard needsRebuild else { return }

                try backgroundExecuteUpdate(db: db, sql: "DELETE FROM AT_DAY_SUMMARY")
                let snapshots = SQLiteReadConnection(databaseURL: databaseURL).readSnapshots(rangeStart: nil, rangeEnd: nil)
                let dayDurations = aggregatedClosedDayDurations(from: snapshots)
                for (dayStart, duration) in dayDurations {
                    try backgroundExecuteUpdate(
                        db: db,
                        sql: """
                        INSERT INTO AT_DAY_SUMMARY (ZDAYSTART, ZCOMPLETEDDURATION)
                        VALUES (?1, ?2)
                        """,
                        bind: { statement in
                            sqlite3_bind_double(statement, 1, dayStart.timeIntervalSinceReferenceDate)
                            sqlite3_bind_double(statement, 2, duration)
                        }
                    )
                }
                try backgroundExecuteUpdate(
                    db: db,
                    sql: """
                    INSERT INTO AT_METADATA (ZKEY, ZVALUE)
                    VALUES (?1, ?2)
                    ON CONFLICT(ZKEY) DO UPDATE
                    SET ZVALUE = excluded.ZVALUE
                    """,
                    bind: { statement in
                        sqlite3_bind_text(statement, 1, MetadataKey.daySummaryVersion, -1, sqliteTransient)
                        sqlite3_bind_text(statement, 2, MetadataKey.currentDaySummaryVersion, -1, sqliteTransient)
                    }
                )
            }
            return nil
        } catch {
            return "History summary refresh failed in the background. The app will continue using direct interval reads."
        }
    }

    nonisolated private static func withBackgroundWritableStore(
        at databaseURL: URL,
        work: (OpaquePointer?) throws -> Void
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = db.flatMap(backgroundSQLiteMessage(db:)) ?? "Failed to open sqlite store"
            if let db { sqlite3_close(db) }
            throw SQLitePersistenceFailure.openFailed(message)
        }
        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, 1000)
        try ensureBackgroundSchema(db: db)
        do {
            try backgroundExecuteUpdate(db: db, sql: "BEGIN IMMEDIATE")
            try work(db)
            try backgroundExecuteUpdate(db: db, sql: "COMMIT")
        } catch {
            try? backgroundExecuteUpdate(db: db, sql: "ROLLBACK")
            throw error
        }
    }

    nonisolated private static func ensureBackgroundSchema(db: OpaquePointer?) throws {
        try backgroundExecuteUpdate(
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
        try backgroundExecuteUpdate(
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
        try backgroundExecuteUpdate(
            db: db,
            sql: """
            CREATE TABLE IF NOT EXISTS AT_DAY_SUMMARY (
                ZDAYSTART REAL PRIMARY KEY,
                ZCOMPLETEDDURATION REAL NOT NULL
            )
            """
        )
        try backgroundExecuteUpdate(
            db: db,
            sql: """
            CREATE TABLE IF NOT EXISTS AT_METADATA (
                ZKEY TEXT PRIMARY KEY,
                ZVALUE TEXT NOT NULL
            )
            """
        )
    }

    nonisolated private static func backgroundExecuteUpdate(
        db: OpaquePointer?,
        sql: String,
        bind: (OpaquePointer?) -> Void = { _ in }
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            throw SQLitePersistenceFailure.prepareFailed(backgroundSQLiteMessage(db: db))
        }
        defer { sqlite3_finalize(statement) }

        bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLitePersistenceFailure.stepFailed(backgroundSQLiteMessage(db: db))
        }
    }

    nonisolated private static func backgroundQuerySingleInt(
        db: OpaquePointer?,
        sql: String
    ) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            throw SQLitePersistenceFailure.prepareFailed(backgroundSQLiteMessage(db: db))
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLitePersistenceFailure.stepFailed(backgroundSQLiteMessage(db: db))
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    nonisolated private static func backgroundQuerySingleText(
        db: OpaquePointer?,
        sql: String
    ) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            throw SQLitePersistenceFailure.prepareFailed(backgroundSQLiteMessage(db: db))
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLitePersistenceFailure.stepFailed(backgroundSQLiteMessage(db: db))
        }
        guard let cString = sqlite3_column_text(statement, 0) else { return "" }
        return String(cString: cString)
    }

    nonisolated private static func backgroundQueryOptionalText(
        db: OpaquePointer?,
        sql: String,
        bind: (OpaquePointer?) -> Void
    ) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            throw SQLitePersistenceFailure.prepareFailed(backgroundSQLiteMessage(db: db))
        }
        defer { sqlite3_finalize(statement) }

        bind(statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: cString)
    }

    nonisolated private static func backgroundSQLiteMessage(db: OpaquePointer?) -> String {
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

    private func buildDailyTotals(
        days: Int,
        dayDurations: [Date: TimeInterval],
        calendar: Calendar
    ) -> [DailyTotal] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: .now)
        guard let firstDay = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }

        return (0..<days).compactMap { offset in
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: firstDay) else {
                return nil
            }
            return DailyTotal(date: dayStart, duration: dayDurations[dayStart] ?? 0)
        }
    }

    private func buildWeeklyTotals(
        weeks: Int,
        dayDurations: [Date: TimeInterval],
        calendar: Calendar
    ) -> [WeeklyTotal] {
        guard weeks > 0 else { return [] }
        let todayComponents = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: .now)
        guard let currentWeekStart = calendar.date(from: todayComponents),
              let firstWeekStart = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: currentWeekStart) else {
            return []
        }

        return (0..<weeks).compactMap { offset in
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: offset, to: firstWeekStart),
                  let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) else {
                return nil
            }
            let duration = totalDuration(from: dayDurations, start: weekStart, end: weekEnd, calendar: calendar)
            return WeeklyTotal(weekStart: weekStart, duration: duration)
        }
    }

    private func buildMonthlyTotals(
        months: Int,
        dayDurations: [Date: TimeInterval],
        calendar: Calendar
    ) -> [MonthlyTotal] {
        guard months > 0 else { return [] }
        let todayComponents = calendar.dateComponents([.year, .month], from: .now)
        guard let currentMonthStart = calendar.date(from: todayComponents),
              let firstMonthStart = calendar.date(byAdding: .month, value: -(months - 1), to: currentMonthStart) else {
            return []
        }

        return (0..<months).compactMap { offset in
            guard let monthStart = calendar.date(byAdding: .month, value: offset, to: firstMonthStart),
                  let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
                return nil
            }
            let duration = totalDuration(from: dayDurations, start: monthStart, end: monthEnd, calendar: calendar)
            return MonthlyTotal(monthStart: monthStart, duration: duration)
        }
    }

    private func totalDuration(
        from dayDurations: [Date: TimeInterval],
        start: Date,
        end: Date,
        calendar: Calendar
    ) -> TimeInterval {
        var total: TimeInterval = 0
        var day = start

        while day < end {
            total += dayDurations[day] ?? 0
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
        }

        return total
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
        _ = try executeUpdate(
            db: db,
            sql: """
            CREATE TABLE IF NOT EXISTS AT_DAY_SUMMARY (
                ZDAYSTART REAL PRIMARY KEY,
                ZCOMPLETEDDURATION REAL NOT NULL
            )
            """
        )
        _ = try executeUpdate(
            db: db,
            sql: """
            CREATE TABLE IF NOT EXISTS AT_METADATA (
                ZKEY TEXT PRIMARY KEY,
                ZVALUE TEXT NOT NULL
            )
            """
        )
        _ = try executeUpdate(
            db: db,
            sql: """
            CREATE INDEX IF NOT EXISTS IDX_ACTIVEINTERVAL_STARTDATE
            ON ZACTIVEINTERVAL (ZSTARTDATE)
            """
        )
        _ = try executeUpdate(
            db: db,
            sql: """
            CREATE INDEX IF NOT EXISTS IDX_ACTIVEINTERVAL_ENDDATE
            ON ZACTIVEINTERVAL (ZENDDATE)
            """
        )
        _ = try executeUpdate(
            db: db,
            sql: """
            CREATE INDEX IF NOT EXISTS IDX_ACTIVEINTERVAL_OPEN_STARTDATE
            ON ZACTIVEINTERVAL (ZSTARTDATE DESC)
            WHERE ZENDDATE IS NULL
            """
        )
    }

}
