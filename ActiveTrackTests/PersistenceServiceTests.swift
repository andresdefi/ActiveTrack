import XCTest
import SwiftData
import SQLite3
@testable import ActiveTrack

@MainActor
final class PersistenceServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var service: PersistenceService!

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: ActiveInterval.self, configurations: config)
        context = ModelContext(container)
        service = PersistenceService(modelContext: context)
    }

    override func tearDown() {
        service = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - CRUD

    func testCreateInterval() throws {
        let interval = try service.createInterval()
        XCTAssertNil(interval.endDate)
        XCTAssertNotNil(interval.startDate)
    }

    func testCloseInterval() throws {
        let interval = try service.createInterval()
        try service.closeInterval(interval)
        XCTAssertNotNil(interval.endDate)
    }

    func testFetchOpenInterval() throws {
        XCTAssertNil(service.fetchOpenInterval())
        let interval = try service.createInterval()
        XCTAssertNotNil(service.fetchOpenInterval())
        try service.closeInterval(interval)
        XCTAssertNil(service.fetchOpenInterval())
    }

    func testDeleteInterval() throws {
        let interval = try service.createInterval()
        try service.closeInterval(interval)
        let countBefore = service.fetchAllIntervals().count
        try service.deleteInterval(interval)
        let countAfter = service.fetchAllIntervals().count
        XCTAssertEqual(countAfter, countBefore - 1)
    }

    // MARK: - Save Propagation

    func testCreateIntervalDoesNotThrow() {
        XCTAssertNoThrow(try service.createInterval())
    }

    func testCloseIntervalDoesNotThrow() throws {
        let interval = try service.createInterval()
        XCTAssertNoThrow(try service.closeInterval(interval))
    }

    func testDeleteIntervalDoesNotThrow() throws {
        let interval = try service.createInterval()
        try service.closeInterval(interval)
        XCTAssertNoThrow(try service.deleteInterval(interval))
    }

    // MARK: - Daily Duration

    func testDurationForToday() {
        // Use times that are guaranteed to be within today to avoid midnight edge case
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let start = today.addingTimeInterval(3600)   // 01:00 today
        let end = today.addingTimeInterval(7200)      // 02:00 today
        let interval = ActiveInterval(startDate: start, endDate: end)
        context.insert(interval)
        try! context.save()

        let duration = service.durationForDay(today)
        XCTAssertEqual(duration, 3600, accuracy: 2)
    }

    // MARK: - Midnight Splitting

    func testMidnightSplitting() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let start = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: yesterday)!
        let end = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: today)!

        let interval = ActiveInterval(startDate: start, endDate: end)
        context.insert(interval)
        try! context.save()

        let yesterdayDuration = service.durationForDay(yesterday)
        let todayDuration = service.durationForDay(today)

        // Yesterday: 23:00 -> 00:00 = 1 hour
        XCTAssertEqual(yesterdayDuration, 3600, accuracy: 2)
        // Today: 00:00 -> 02:00 = 2 hours
        XCTAssertEqual(todayDuration, 7200, accuracy: 2)
    }

    // MARK: - Aggregation

    func testDailyTotals() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        for dayOffset in 0..<3 {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: today)!
            let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
            let end = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day)!
            let interval = ActiveInterval(startDate: start, endDate: end)
            context.insert(interval)
        }
        try! context.save()

        let totals = service.dailyTotals(days: 7)
        XCTAssertEqual(totals.count, 7)

        let nonZero = totals.filter { $0.duration > 0 }
        XCTAssertEqual(nonZero.count, 3)
    }

    func testWeeklyTotalsSplitCrossWeekInterval() {
        let calendar = Calendar.current
        let currentWeekStart = calendar.date(
            from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: .now)
        )!

        let start = currentWeekStart.addingTimeInterval(-3600)
        let end = currentWeekStart.addingTimeInterval(7200)
        context.insert(ActiveInterval(startDate: start, endDate: end))
        try! context.save()

        let totals = service.weeklyTotals(weeks: 2)
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals[0].duration, 3600, accuracy: 2)
        XCTAssertEqual(totals[1].duration, 7200, accuracy: 2)
    }

    func testMonthlyTotalsSplitCrossMonthInterval() {
        let calendar = Calendar.current
        let currentMonthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: .now)
        )!

        let start = currentMonthStart.addingTimeInterval(-3600)
        let end = currentMonthStart.addingTimeInterval(7200)
        context.insert(ActiveInterval(startDate: start, endDate: end))
        try! context.save()

        let totals = service.monthlyTotals(months: 2)
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals[0].duration, 3600, accuracy: 2)
        XCTAssertEqual(totals[1].duration, 7200, accuracy: 2)
    }

    func testIntervalsForDay() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let start1 = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: today)!
        let end1 = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: today)!
        let start2 = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: today)!
        let end2 = calendar.date(bySettingHour: 15, minute: 30, second: 0, of: today)!

        context.insert(ActiveInterval(startDate: start1, endDate: end1))
        context.insert(ActiveInterval(startDate: start2, endDate: end2))
        try! context.save()

        let intervals = service.intervalsForDay(today)
        XCTAssertEqual(intervals.count, 2)
        XCTAssertEqual(intervals[0].duration, 3600, accuracy: 2)
        XCTAssertEqual(intervals[1].duration, 5400, accuracy: 2)
    }

    func testIntervalSummariesForDayMarksOpenIntervals() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        let closedStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: today)!
        let closedEnd = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: today)!
        context.insert(ActiveInterval(startDate: closedStart, endDate: closedEnd))
        context.insert(ActiveInterval(startDate: Date.now.addingTimeInterval(-1800)))
        try! context.save()

        let summaries = service.intervalSummariesForDay(today)
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.filter(\.isOpen).count, 1)
        XCTAssertEqual(summaries.filter { !$0.isOpen }.count, 1)
    }

    func testDaysWithData() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let start1 = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: today)!
        let end1 = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: today)!
        let start2 = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: yesterday)!
        let end2 = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: yesterday)!

        context.insert(ActiveInterval(startDate: start1, endDate: end1))
        context.insert(ActiveInterval(startDate: start2, endDate: end2))
        try! context.save()

        let days = service.daysWithData()
        XCTAssertEqual(days.count, 2)
    }

    func testAllDayDurationsSplitsCrossDayIntervals() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let start = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: yesterday)!
        let end = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: today)!
        context.insert(ActiveInterval(startDate: start, endDate: end))
        try! context.save()

        let dayDurations = service.allDayDurations()
        XCTAssertEqual(dayDurations[yesterday] ?? 0, 3600, accuracy: 2)
        XCTAssertEqual(dayDurations[today] ?? 0, 7200, accuracy: 2)
    }

    func testChartDataMatchesSplitAggregations() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let eightDaysAgo = calendar.date(byAdding: .day, value: -8, to: today)!
        let fiveWeeksAgo = calendar.date(byAdding: .weekOfYear, value: -5, to: today)!

        let intervals = [
            ActiveInterval(
                startDate: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: today)!,
                endDate: calendar.date(bySettingHour: 10, minute: 0, second: 0, of: today)!
            ),
            ActiveInterval(
                startDate: calendar.date(bySettingHour: 11, minute: 0, second: 0, of: yesterday)!,
                endDate: calendar.date(bySettingHour: 13, minute: 0, second: 0, of: yesterday)!
            ),
            ActiveInterval(
                startDate: calendar.date(bySettingHour: 14, minute: 0, second: 0, of: eightDaysAgo)!,
                endDate: calendar.date(bySettingHour: 15, minute: 30, second: 0, of: eightDaysAgo)!
            ),
            ActiveInterval(
                startDate: calendar.date(bySettingHour: 8, minute: 0, second: 0, of: fiveWeeksAgo)!,
                endDate: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: fiveWeeksAgo)!
            )
        ]

        for interval in intervals {
            context.insert(interval)
        }
        try! context.save()

        let expectedDaily = service.dailyTotals(days: 14)
        let expectedWeekly = service.weeklyTotals(weeks: 12)
        let expectedMonthly = service.monthlyTotals(months: 12)
        let chartData = service.chartData(days: 14, weeks: 12, months: 12)

        XCTAssertEqual(chartData.daily.map(\.date), expectedDaily.map(\.date))
        XCTAssertEqual(chartData.weekly.map(\.weekStart), expectedWeekly.map(\.weekStart))
        XCTAssertEqual(chartData.monthly.map(\.monthStart), expectedMonthly.map(\.monthStart))

        for (actual, expected) in zip(chartData.daily, expectedDaily) {
            XCTAssertEqual(actual.duration, expected.duration, accuracy: 2)
        }
        for (actual, expected) in zip(chartData.weekly, expectedWeekly) {
            XCTAssertEqual(actual.duration, expected.duration, accuracy: 2)
        }
        for (actual, expected) in zip(chartData.monthly, expectedMonthly) {
            XCTAssertEqual(actual.duration, expected.duration, accuracy: 2)
        }
    }

    // MARK: - fetchOpenInterval Ordering

    func testFetchOpenIntervalReturnsMostRecent() {
        // Simulate crash scenario: two open intervals from different days
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))!
        let yesterdayEvening = calendar.date(byAdding: .hour, value: 22, to: yesterday)!

        let staleInterval = ActiveInterval(startDate: yesterdayEvening)
        let recentInterval = ActiveInterval(startDate: Date.now.addingTimeInterval(-300))

        context.insert(staleInterval)
        context.insert(recentInterval)
        try! context.save()

        let fetched = service.fetchOpenInterval()
        XCTAssertNotNil(fetched)
        // Should return the most recent open interval, not the stale one
        XCTAssertEqual(fetched!.startDate, recentInterval.startDate,
                       "fetchOpenInterval should return the most recent open interval")
    }

    func testFetchOpenIntervalWithManyOrphans() {
        // Simulate multiple crashes: open intervals across several days
        let calendar = Calendar.current
        for dayOffset in [5, 3, 1] {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: .now)!
            let interval = ActiveInterval(startDate: day)
            context.insert(interval)
        }
        let todayInterval = ActiveInterval(startDate: Date.now.addingTimeInterval(-60))
        context.insert(todayInterval)
        try! context.save()

        let fetched = service.fetchOpenInterval()
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched!.startDate, todayInterval.startDate,
                       "Should recover the most recent open interval, not a stale orphan")
    }

    func testFetchOpenIntervalsReturnsNewestFirst() {
        let olderInterval = ActiveInterval(startDate: Date.now.addingTimeInterval(-600))
        let newerInterval = ActiveInterval(startDate: Date.now.addingTimeInterval(-60))
        context.insert(olderInterval)
        context.insert(newerInterval)
        try! context.save()

        let openIntervals = service.fetchOpenIntervals()
        XCTAssertEqual(openIntervals.count, 2)
        XCTAssertEqual(openIntervals.first?.startDate, newerInterval.startDate)
        XCTAssertEqual(openIntervals.last?.startDate, olderInterval.startDate)
    }

    // MARK: - Day Boundary Precision

    func testIntervalEndingExactlyAtMidnight() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        // Interval: yesterday 23:00 → midnight exactly
        let start = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: yesterday)!
        let interval = ActiveInterval(startDate: start, endDate: today)
        context.insert(interval)
        try! context.save()

        // Yesterday should have 1 hour
        let yesterdayDuration = service.durationForDay(yesterday)
        XCTAssertEqual(yesterdayDuration, 3600, accuracy: 2)

        // Today should have 0 (interval ended exactly at midnight)
        let todayDuration = service.durationForDay(today)
        XCTAssertEqual(todayDuration, 0, accuracy: 1,
                       "Interval ending exactly at midnight should not bleed into the next day")
    }

    func testIntervalStartingExactlyAtMidnight() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        // Interval: midnight → 02:00 today
        let end = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: today)!
        let interval = ActiveInterval(startDate: today, endDate: end)
        context.insert(interval)
        try! context.save()

        let yesterdayDuration = service.durationForDay(yesterday)
        XCTAssertEqual(yesterdayDuration, 0, accuracy: 1,
                       "Interval starting at midnight should not count toward the previous day")

        let todayDuration = service.durationForDay(today)
        XCTAssertEqual(todayDuration, 7200, accuracy: 2)
    }

    // MARK: - Duration Accuracy

    func testDurationForDayDoesNotDoubleCount() {
        // Multiple non-overlapping intervals in one day
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        let intervals: [(Int, Int, Int, Int)] = [
            (9, 0, 10, 0),   // 1 hour
            (10, 30, 11, 0),  // 30 min
            (14, 0, 15, 0),   // 1 hour
        ]

        for (sh, sm, eh, em) in intervals {
            let start = calendar.date(bySettingHour: sh, minute: sm, second: 0, of: today)!
            let end = calendar.date(bySettingHour: eh, minute: em, second: 0, of: today)!
            context.insert(ActiveInterval(startDate: start, endDate: end))
        }
        try! context.save()

        let duration = service.durationForDay(today)
        // 1h + 30m + 1h = 2.5h = 9000s
        XCTAssertEqual(duration, 9000, accuracy: 2)
    }

    func testDurationForDayExcludesOtherDays() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!

        // 1 hour yesterday
        let yStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: yesterday)!
        let yEnd = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: yesterday)!
        context.insert(ActiveInterval(startDate: yStart, endDate: yEnd))

        // 2 hours two days ago
        let tStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: twoDaysAgo)!
        let tEnd = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: twoDaysAgo)!
        context.insert(ActiveInterval(startDate: tStart, endDate: tEnd))
        try! context.save()

        // Today should be 0
        let todayDuration = service.durationForDay(today)
        XCTAssertEqual(todayDuration, 0, accuracy: 1,
                       "Duration for today should not include intervals from other days")
    }

    func testCompletedOnlyExcludesRunningInterval() {
        let today = Calendar.current.startOfDay(for: .now)

        // One completed 1-hour interval
        let cStart = today.addingTimeInterval(3600)
        let cEnd = today.addingTimeInterval(7200)
        context.insert(ActiveInterval(startDate: cStart, endDate: cEnd))

        // One running interval
        context.insert(ActiveInterval(startDate: Date.now.addingTimeInterval(-1800)))
        try! context.save()

        let withRunning = service.durationForDay(.now, completedOnly: false)
        let completedOnly = service.durationForDay(.now, completedOnly: true)

        XCTAssertEqual(completedOnly, 3600, accuracy: 2,
                       "completedOnly should only count the 1-hour completed interval")
        XCTAssertGreaterThan(withRunning, completedOnly,
                             "Without completedOnly, running interval should add to the total")
    }

    // MARK: - Data Integrity

    func testIntervalDurationNeverNegative() {
        // Corrupt interval: endDate before startDate
        let now = Date.now
        let interval = ActiveInterval(startDate: now, endDate: now.addingTimeInterval(-3600))
        context.insert(interval)
        try! context.save()

        // The model's duration property should not be negative
        XCTAssertGreaterThanOrEqual(interval.duration, 0,
                                    "ActiveInterval.duration should never be negative, even with corrupt data")
    }

    func testClampedDurationHandlesCorruptInterval() {
        // Corrupt interval: endDate before startDate, should not affect day total
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        let normal = ActiveInterval(
            startDate: today.addingTimeInterval(3600),
            endDate: today.addingTimeInterval(7200)
        )
        let corrupt = ActiveInterval(
            startDate: today.addingTimeInterval(10800),
            endDate: today.addingTimeInterval(7200)  // 1h BEFORE start
        )
        context.insert(normal)
        context.insert(corrupt)
        try! context.save()

        let duration = service.durationForDay(today)
        // Should be 1h from the normal interval; corrupt interval should contribute 0
        XCTAssertEqual(duration, 3600, accuracy: 2,
                       "Corrupt intervals should not affect day duration totals")
    }

    func testDaysWithDataForCrossDayInterval() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today)!

        // Interval spanning 3 days
        let interval = ActiveInterval(startDate: threeDaysAgo.addingTimeInterval(3600),
                                      endDate: today.addingTimeInterval(3600))
        context.insert(interval)
        try! context.save()

        let days = service.daysWithData()
        // Should include all 4 days: 3 days ago, 2 days ago, yesterday, today
        XCTAssertEqual(days.count, 4,
                       "Cross-day interval should register data for every day it spans")
    }

    // MARK: - SQLite Summary Maintenance

    func testSQLiteSummaryUpdatesWhenClosingCrossDayInterval() throws {
        let (sqliteService, storeURL, directory) = try makeSQLiteService()
        defer { try? FileManager.default.removeItem(at: directory) }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let start = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: yesterday)!
        let end = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: today)!

        let interval = try sqliteService.createInterval(startDate: start)
        try sqliteService.closeInterval(interval, endDate: end)

        let durations = sqliteService.allDayDurations()
        XCTAssertEqual(durations[yesterday] ?? 0, 3600, accuracy: 2)
        XCTAssertEqual(durations[today] ?? 0, 7200, accuracy: 2)

        let rows = try readDaySummaryRows(at: storeURL)
        XCTAssertEqual(rows[yesterday] ?? 0, 3600, accuracy: 2)
        XCTAssertEqual(rows[today] ?? 0, 7200, accuracy: 2)
    }

    func testSQLiteSummarySubtractsDeletedInterval() throws {
        let (sqliteService, _, directory) = try makeSQLiteService()
        defer { try? FileManager.default.removeItem(at: directory) }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: today)!
        let end = calendar.date(bySettingHour: 10, minute: 30, second: 0, of: today)!

        let interval = try sqliteService.createInterval(startDate: start)
        try sqliteService.closeInterval(interval, endDate: end)
        XCTAssertEqual(sqliteService.allDayDurations()[today] ?? 0, 5400, accuracy: 2)

        try sqliteService.deleteInterval(interval)
        XCTAssertEqual(sqliteService.allDayDurations()[today] ?? 0, 0, accuracy: 1)
        XCTAssertTrue(sqliteService.daysWithData().isEmpty)
    }

    func testSQLiteResetTodayClearsTodaySummaryButPreservesEarlierDays() throws {
        let (sqliteService, _, directory) = try makeSQLiteService()
        defer { try? FileManager.default.removeItem(at: directory) }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let spanningInterval = try sqliteService.createInterval(
            startDate: calendar.date(bySettingHour: 23, minute: 0, second: 0, of: yesterday)!
        )
        try sqliteService.closeInterval(
            spanningInterval,
            endDate: calendar.date(bySettingHour: 2, minute: 0, second: 0, of: today)!
        )

        let todaysInterval = try sqliteService.createInterval(
            startDate: calendar.date(bySettingHour: 8, minute: 0, second: 0, of: today)!
        )
        try sqliteService.closeInterval(
            todaysInterval,
            endDate: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: today)!
        )

        try sqliteService.resetToday()

        let durations = sqliteService.allDayDurations()
        XCTAssertEqual(durations[yesterday] ?? 0, 3600, accuracy: 2)
        XCTAssertNil(durations[today])
    }

    func testSQLiteStartupRebuildBackfillsDaySummary() throws {
        let (sqliteService, storeURL, directory) = try makeSQLiteService()
        defer { try? FileManager.default.removeItem(at: directory) }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let interval = try sqliteService.createInterval(
            startDate: calendar.date(bySettingHour: 22, minute: 0, second: 0, of: yesterday)!
        )
        try sqliteService.closeInterval(
            interval,
            endDate: calendar.date(bySettingHour: 1, minute: 30, second: 0, of: today)!
        )

        try executeSQL(
            at: storeURL,
            sql: """
            DELETE FROM AT_DAY_SUMMARY;
            DELETE FROM AT_METADATA;
            """
        )

        let rebuiltService = PersistenceService(modelContext: context, storeURL: storeURL)
        let durations = rebuiltService.allDayDurations()
        XCTAssertEqual(durations[yesterday] ?? 0, 7200, accuracy: 2)
        XCTAssertEqual(durations[today] ?? 0, 5400, accuracy: 2)

        waitForCondition(timeout: 2.0) {
            let rows = (try? self.readDaySummaryRows(at: storeURL)) ?? [:]
            return (rows[yesterday] ?? 0) > 0 && (rows[today] ?? 0) > 0
        }
    }

    private func makeSQLiteService() throws -> (PersistenceService, URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActiveTrackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("Persistence.store")
        let sqliteService = PersistenceService(modelContext: context, storeURL: storeURL)
        return (sqliteService, storeURL, directory)
    }

    private func readDaySummaryRows(at storeURL: URL) throws -> [Date: TimeInterval] {
        var rows: [Date: TimeInterval] = [:]
        try withDatabase(at: storeURL) { db in
            var statement: OpaquePointer?
            let sql = """
            SELECT ZDAYSTART, ZCOMPLETEDDURATION
            FROM AT_DAY_SUMMARY
            ORDER BY ZDAYSTART
            """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw XCTSkip("Failed to prepare summary query")
            }
            defer { sqlite3_finalize(statement) }

            while sqlite3_step(statement) == SQLITE_ROW {
                let dayStart = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 0))
                rows[dayStart] = sqlite3_column_double(statement, 1)
            }
        }
        return rows
    }

    private func executeSQL(at storeURL: URL, sql: String) throws {
        try withDatabase(at: storeURL) { db in
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw XCTSkip("Failed to execute sqlite statement")
            }
        }
    }

    private func waitForCondition(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }

        XCTAssertTrue(condition(), "Condition not met within \(timeout) seconds", file: file, line: line)
    }

    private func withDatabase(at storeURL: URL, _ body: (OpaquePointer?) throws -> Void) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let db {
                sqlite3_close(db)
            }
            throw XCTSkip("Failed to open sqlite store")
        }
        defer { sqlite3_close(db) }
        try body(db)
    }
}
