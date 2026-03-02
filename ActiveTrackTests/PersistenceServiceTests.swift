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
}
