import XCTest
import SwiftData
@testable import ActiveTrack

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

    func testCreateInterval() {
        let interval = service.createInterval()
        XCTAssertNil(interval.endDate)
        XCTAssertNotNil(interval.startDate)
    }

    func testCloseInterval() {
        let interval = service.createInterval()
        service.closeInterval(interval)
        XCTAssertNotNil(interval.endDate)
    }

    func testFetchOpenInterval() {
        XCTAssertNil(service.fetchOpenInterval())
        let interval = service.createInterval()
        XCTAssertNotNil(service.fetchOpenInterval())
        service.closeInterval(interval)
        XCTAssertNil(service.fetchOpenInterval())
    }

    func testDeleteInterval() {
        let interval = service.createInterval()
        service.closeInterval(interval)
        let countBefore = service.fetchAllIntervals().count
        service.deleteInterval(interval)
        let countAfter = service.fetchAllIntervals().count
        XCTAssertEqual(countAfter, countBefore - 1)
    }

    // MARK: - Daily Duration

    func testDurationForToday() {
        let now = Date.now
        let oneHourAgo = now.addingTimeInterval(-3600)
        let interval = ActiveInterval(startDate: oneHourAgo, endDate: now)
        context.insert(interval)
        try! context.save()

        let duration = service.durationForDay(now)
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
}
