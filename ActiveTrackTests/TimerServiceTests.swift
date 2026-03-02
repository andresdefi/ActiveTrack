import XCTest
import SwiftData
@testable import ActiveTrack

final class TimerServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var persistence: PersistenceService!
    private var timer: TimerService!

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: ActiveInterval.self, configurations: config)
        context = ModelContext(container)
        persistence = PersistenceService(modelContext: context)
        timer = TimerService()
        timer.configure(persistenceService: persistence)
    }

    override func tearDown() {
        timer = nil
        persistence = nil
        context = nil
        container = nil
        super.tearDown()
    }

    func testInitialState() {
        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(timer.displayTime, 0, accuracy: 1)
    }

    func testStartSetsRunning() {
        timer.start()
        XCTAssertTrue(timer.isRunning)
    }

    func testPauseStopsRunning() {
        timer.start()
        timer.pause()
        XCTAssertFalse(timer.isRunning)
    }

    func testStartCreatesOpenInterval() {
        timer.start()
        let open = persistence.fetchOpenInterval()
        XCTAssertNotNil(open)
        XCTAssertNil(open?.endDate)
    }

    func testPauseClosesInterval() {
        timer.start()
        timer.pause()
        let open = persistence.fetchOpenInterval()
        XCTAssertNil(open)
    }

    func testToggle() {
        timer.toggle()
        XCTAssertTrue(timer.isRunning)
        timer.toggle()
        XCTAssertFalse(timer.isRunning)
    }

    func testRecoverOpenInterval() {
        let interval = ActiveInterval(startDate: Date.now.addingTimeInterval(-60))
        context.insert(interval)
        try! context.save()

        let newTimer = TimerService()
        newTimer.configure(persistenceService: persistence)
        XCTAssertTrue(newTimer.isRunning)
        XCTAssertGreaterThan(newTimer.currentIntervalElapsed, 50)
    }

    func testDoubleStartIgnored() {
        timer.start()
        timer.start()
        let intervals = persistence.fetchAllIntervals()
        let openCount = intervals.filter { $0.endDate == nil }.count
        XCTAssertEqual(openCount, 1)
    }

    func testPauseWhenNotRunningIgnored() {
        timer.pause()
        XCTAssertFalse(timer.isRunning)
    }

    // MARK: - Midnight Rollover

    func testRolloverSplitsYesterdayInterval() {
        let calendar = Calendar.current
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))!
        let yesterdayEvening = calendar.date(byAdding: .hour, value: 20, to: yesterdayStart)!

        let interval = ActiveInterval(startDate: yesterdayEvening)
        context.insert(interval)
        try! context.save()

        // Recovery triggers immediate rollover for previous-day intervals
        let newTimer = TimerService()
        newTimer.configure(persistenceService: persistence)

        // Should still be running with a new interval for today
        XCTAssertTrue(newTimer.isRunning)

        let open = persistence.fetchOpenInterval()
        XCTAssertNotNil(open)
        XCTAssertTrue(calendar.isDateInToday(open!.startDate))

        // Elapsed should reflect time since midnight (new interval started at 00:00)
        let todayStart = calendar.startOfDay(for: .now)
        let expectedElapsed = Date.now.timeIntervalSince(todayStart)
        XCTAssertEqual(newTimer.currentIntervalElapsed, expectedElapsed, accuracy: 5)
    }

    func testRolloverClosesOldIntervalAtMidnight() {
        let calendar = Calendar.current
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))!
        let yesterdayEvening = calendar.date(byAdding: .hour, value: 22, to: yesterdayStart)!

        let interval = ActiveInterval(startDate: yesterdayEvening)
        context.insert(interval)
        try! context.save()

        let newTimer = TimerService()
        newTimer.configure(persistenceService: persistence)

        // The old interval should be closed with endDate at start of today (midnight)
        let todayStart = calendar.startOfDay(for: .now)
        let all = persistence.fetchAllIntervals()
        let closed = all.first { $0.endDate != nil && !calendar.isDateInToday($0.startDate) }
        XCTAssertNotNil(closed)
        XCTAssertEqual(closed!.endDate!.timeIntervalSince1970, todayStart.timeIntervalSince1970, accuracy: 1)
    }

    func testRolloverPreservesYesterdayDuration() {
        let calendar = Calendar.current
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))!
        let yesterdayEvening = calendar.date(byAdding: .hour, value: 22, to: yesterdayStart)!

        let interval = ActiveInterval(startDate: yesterdayEvening)
        context.insert(interval)
        try! context.save()

        let newTimer = TimerService()
        newTimer.configure(persistenceService: persistence)

        // Yesterday should have 2 hours (22:00 -> 00:00)
        let yesterdayDuration = persistence.durationForDay(yesterdayStart)
        XCTAssertEqual(yesterdayDuration, 7200, accuracy: 5)
    }

    func testTodayTotalResetsAfterRollover() {
        let calendar = Calendar.current
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))!
        let yesterdayEvening = calendar.date(byAdding: .hour, value: 20, to: yesterdayStart)!

        let interval = ActiveInterval(startDate: yesterdayEvening)
        context.insert(interval)
        try! context.save()

        let newTimer = TimerService()
        newTimer.configure(persistenceService: persistence)

        // todayTotal should be 0 (no completed intervals for today yet)
        XCTAssertEqual(newTimer.todayTotal, 0, accuracy: 1)
    }

    func testPausedTodayTotalClearsOnNewDay() {
        // Start and pause to accumulate todayTotal
        timer.start()
        let exp = expectation(description: "accumulate")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        timer.pause()

        XCTAssertGreaterThan(timer.todayTotal, 0)

        // Querying a future day should return 0 (proves refreshTodayTotal would reset)
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now)!
        let tomorrowDuration = persistence.durationForDay(tomorrow, completedOnly: true)
        XCTAssertEqual(tomorrowDuration, 0)
    }

    func testMultiDayGapRecovery() {
        let calendar = Calendar.current
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: .now))!
        let start = calendar.date(byAdding: .hour, value: 15, to: threeDaysAgo)!

        let interval = ActiveInterval(startDate: start)
        context.insert(interval)
        try! context.save()

        let newTimer = TimerService()
        newTimer.configure(persistenceService: persistence)

        // Should recover and roll over even with a multi-day gap
        XCTAssertTrue(newTimer.isRunning)
        let open = persistence.fetchOpenInterval()
        XCTAssertNotNil(open)
        XCTAssertTrue(calendar.isDateInToday(open!.startDate))

        // The old interval should be closed
        let all = persistence.fetchAllIntervals()
        let closed = all.first { $0.endDate != nil }
        XCTAssertNotNil(closed)
        XCTAssertEqual(closed!.startDate, start)
    }
}
