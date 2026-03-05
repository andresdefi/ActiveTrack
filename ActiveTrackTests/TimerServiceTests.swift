import XCTest
import SwiftData
@testable import ActiveTrack

@MainActor
final class TimerServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var persistence: PersistenceService!
    private var timer: TimerService!

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: ActiveInterval.self, configurations: config)
        context = container.mainContext
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

    // MARK: - Basic State

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

        let newTimer = TimerService(); newTimer.configure(persistenceService: persistence)
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

    // MARK: - Error State

    func testLastErrorNilAfterSuccessfulStart() {
        timer.start()
        XCTAssertNil(timer.lastError)
    }

    func testLastErrorNilAfterSuccessfulPause() {
        timer.start()
        timer.pause()
        XCTAssertNil(timer.lastError)
    }

    func testErrorStateDoesNotCorruptTimerState() {
        // After a successful start/pause cycle, timer state should be clean
        timer.start()
        XCTAssertTrue(timer.isRunning)
        XCTAssertNil(timer.lastError)

        timer.pause()
        XCTAssertFalse(timer.isRunning)
        XCTAssertNil(timer.lastError)
        XCTAssertEqual(timer.currentIntervalElapsed, 0)
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
        let newTimer = TimerService(); newTimer.configure(persistenceService: persistence)

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

        let newTimer = TimerService(); newTimer.configure(persistenceService: persistence)

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

        let t = TimerService(); t.configure(persistenceService: persistence)

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

        let newTimer = TimerService(); newTimer.configure(persistenceService: persistence)

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

        let newTimer = TimerService(); newTimer.configure(persistenceService: persistence)

        // Should recover and roll over even with a multi-day gap
        XCTAssertTrue(newTimer.isRunning)
        let open = persistence.fetchOpenInterval()
        XCTAssertNotNil(open)
        XCTAssertTrue(calendar.isDateInToday(open!.startDate))

        // The old interval should be closed
        let all = persistence.fetchAllIntervals()
        let closed = all.filter { $0.endDate != nil }
        XCTAssertGreaterThan(closed.count, 0)

        // The original interval should be closed at its next midnight
        let originalClosed = closed.first { $0.startDate == start }
        XCTAssertNotNil(originalClosed)
    }

    func testMultiDayGapCreatesIntermediateDayIntervals() {
        let calendar = Calendar.current
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: .now))!
        let start = calendar.date(byAdding: .hour, value: 15, to: threeDaysAgo)!

        let interval = ActiveInterval(startDate: start)
        context.insert(interval)
        try! context.save()

        let t = TimerService(); t.configure(persistenceService: persistence)

        // Each intermediate day should have data
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: .now))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))!

        let twoDaysAgoDuration = persistence.durationForDay(twoDaysAgo)
        let yesterdayDuration = persistence.durationForDay(yesterday)

        // Each intermediate day should have a full 24h interval
        XCTAssertEqual(twoDaysAgoDuration, 86400, accuracy: 5,
                       "Two days ago should have a full day of tracked time from the gap")
        XCTAssertEqual(yesterdayDuration, 86400, accuracy: 5,
                       "Yesterday should have a full day of tracked time from the gap")

        // Three days ago should have 9h (15:00 -> midnight)
        let threeDaysAgoDuration = persistence.durationForDay(threeDaysAgo)
        XCTAssertEqual(threeDaysAgoDuration, 32400, accuracy: 5,
                       "Three days ago should have 9h (15:00 -> midnight)")
    }

    // MARK: - Midnight Rollover Guard (the bug fix)

    func testMidnightRolloverIgnoredForTodayInterval() {
        // This is the exact bug scenario: timer running with a today-interval,
        // handleMidnightRollover fires erroneously (e.g. stale timer after wake).
        timer.start()

        let open = persistence.fetchOpenInterval()
        XCTAssertNotNil(open)
        let originalStartDate = open!.startDate

        // Capture state before the erroneous rollover
        let displayBefore = timer.displayTime

        // Simulate the stale midnight timer firing
        timer.handleMidnightRollover()

        // The interval should NOT have been split
        XCTAssertTrue(timer.isRunning)
        let openAfter = persistence.fetchOpenInterval()
        XCTAssertNotNil(openAfter)
        XCTAssertEqual(openAfter!.startDate, originalStartDate,
                       "Interval startDate should not change when rollover fires for a today-interval")

        // displayTime should remain reasonable (not jump to wall-clock time)
        let displayAfter = timer.displayTime
        XCTAssertEqual(displayAfter, displayBefore, accuracy: 2,
                       "displayTime should not jump after an erroneous rollover")
    }

    func testMidnightRolloverDoesNotCreateBackwardsInterval() {
        // Start and run for a moment, then fire rollover
        timer.start()

        let exp = expectation(description: "tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { exp.fulfill() }
        wait(for: [exp], timeout: 2)

        timer.handleMidnightRollover()

        // No interval should ever have endDate before startDate
        let all = persistence.fetchAllIntervals()
        for interval in all {
            if let endDate = interval.endDate {
                XCTAssertGreaterThanOrEqual(endDate, interval.startDate,
                    "Interval endDate (\(endDate)) must not be before startDate (\(interval.startDate))")
            }
        }
    }

    func testRepeatedMidnightRolloverDoesNotCorruptState() {
        // Simulate the rollover firing multiple times (e.g. scheduled timer + tick both trigger)
        timer.start()

        let open = persistence.fetchOpenInterval()!
        let originalStart = open.startDate

        timer.handleMidnightRollover()
        timer.handleMidnightRollover()
        timer.handleMidnightRollover()

        // Should still be running with the same interval
        XCTAssertTrue(timer.isRunning)
        let openAfter = persistence.fetchOpenInterval()
        XCTAssertNotNil(openAfter)
        XCTAssertEqual(openAfter!.startDate, originalStart)

        // Only 1 open interval should exist
        let all = persistence.fetchAllIntervals()
        let openCount = all.filter { $0.endDate == nil }.count
        XCTAssertEqual(openCount, 1, "Repeated rollover should not create extra open intervals")
    }

    func testRolloverStillWorksForYesterdayInterval() {
        // Ensure the guard doesn't break legitimate cross-day rollover
        let calendar = Calendar.current
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))!
        let yesterdayEvening = calendar.date(byAdding: .hour, value: 23, to: yesterdayStart)!

        let interval = ActiveInterval(startDate: yesterdayEvening)
        context.insert(interval)
        try! context.save()

        let newTimer = TimerService(); newTimer.configure(persistenceService: persistence)

        // The old interval should be closed at midnight
        let all = persistence.fetchAllIntervals()
        let closed = all.first { $0.endDate != nil }
        XCTAssertNotNil(closed, "Yesterday's interval should be closed by rollover")

        // And a new one should exist for today
        let open = persistence.fetchOpenInterval()
        XCTAssertNotNil(open)
        XCTAssertTrue(calendar.isDateInToday(open!.startDate))
    }

    // MARK: - Sleep / Wake

    func testSleepPausesRunningTimer() {
        timer.start()
        XCTAssertTrue(timer.isRunning)

        timer.handleSleep()

        XCTAssertFalse(timer.isRunning, "Timer should be paused after sleep")
        XCTAssertNil(persistence.fetchOpenInterval(), "Open interval should be closed on sleep")
    }

    func testSleepWhenAlreadyPausedIsHarmless() {
        // Timer not running, sleep fires — should not crash or corrupt
        timer.handleSleep()
        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(timer.displayTime, 0, accuracy: 1)
    }

    func testWakeRefreshesTodayTotal() {
        // Start, pause to create a completed interval
        timer.start()
        let exp = expectation(description: "tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        timer.pause()

        let totalBefore = timer.todayTotal
        XCTAssertGreaterThan(totalBefore, 0)

        // Simulate wake — todayTotal should still reflect completed intervals
        timer.handleWake()
        XCTAssertEqual(timer.todayTotal, totalBefore, accuracy: 1,
                       "Wake should preserve todayTotal for completed intervals")
    }

    func testSleepWakeCyclePreservesCompletedIntervals() {
        // Simulate: work, sleep, wake
        timer.start()
        let exp = expectation(description: "tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { exp.fulfill() }
        wait(for: [exp], timeout: 2)

        timer.handleSleep()  // pauses
        timer.handleWake()   // refreshes

        // The completed interval should be counted in todayTotal
        XCTAssertGreaterThan(timer.todayTotal, 0,
                             "Completed intervals should persist through sleep/wake")
        XCTAssertFalse(timer.isRunning, "Timer should still be paused after wake")
    }

    // MARK: - Display Time Accuracy

    func testDisplayTimeNeverNegative() {
        // Fresh start
        XCTAssertGreaterThanOrEqual(timer.displayTime, 0)

        // While running
        timer.start()
        XCTAssertGreaterThanOrEqual(timer.displayTime, 0)

        // After pause
        timer.pause()
        XCTAssertGreaterThanOrEqual(timer.displayTime, 0)

        // After rollover attempt
        timer.start()
        timer.handleMidnightRollover()
        XCTAssertGreaterThanOrEqual(timer.displayTime, 0)
    }

    func testDisplayTimeAccumulatesAcrossPauseResumeCycles() {
        timer.start()
        let exp1 = expectation(description: "first session")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { exp1.fulfill() }
        wait(for: [exp1], timeout: 2)
        timer.pause()

        let afterFirst = timer.displayTime
        XCTAssertGreaterThan(afterFirst, 0)

        timer.start()
        let exp2 = expectation(description: "second session")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { exp2.fulfill() }
        wait(for: [exp2], timeout: 2)
        timer.pause()

        let afterSecond = timer.displayTime
        XCTAssertGreaterThan(afterSecond, afterFirst,
                             "displayTime should grow across pause/resume cycles")
    }

    func testTodayTotalExcludesRunningInterval() {
        timer.start()
        let exp = expectation(description: "tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { exp.fulfill() }
        wait(for: [exp], timeout: 2)

        // While the timer is running, todayTotal should only include completed intervals
        timer.refreshTodayTotal()
        XCTAssertEqual(timer.todayTotal, 0, accuracy: 0.1,
                       "todayTotal should exclude the currently running interval")

        // But displayTime should still show elapsed time
        XCTAssertGreaterThan(timer.displayTime, 0)
    }

    func testPauseResumeUpdatesTodayTotal() {
        // First session
        timer.start()
        let exp = expectation(description: "tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        timer.pause()

        let todayAfterPause = timer.todayTotal
        XCTAssertGreaterThan(todayAfterPause, 0,
                             "todayTotal should include the just-completed interval")

        // Second session — todayTotal should carry forward
        timer.start()
        XCTAssertEqual(timer.todayTotal, todayAfterPause, accuracy: 0.5,
                       "todayTotal should include previous sessions when starting a new one")
    }

    func testDisplayTimeBoundedByReasonableElapsed() {
        // displayTime should never exceed the time since the timer was first started
        let startTime = Date.now
        timer.start()

        let exp = expectation(description: "tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { exp.fulfill() }
        wait(for: [exp], timeout: 2)

        let maxReasonable = Date.now.timeIntervalSince(startTime) + 2 // small tolerance
        XCTAssertLessThan(timer.displayTime, maxReasonable,
                          "displayTime should not exceed actual wall-clock elapsed time since start")
    }

    // MARK: - Data Integrity

    func testOnlyOneOpenIntervalAtATime() {
        timer.start()
        timer.pause()
        timer.start()

        let all = persistence.fetchAllIntervals()
        let openCount = all.filter { $0.endDate == nil }.count
        XCTAssertEqual(openCount, 1, "There should be exactly 1 open interval when running")
    }

    func testNoOpenIntervalsWhenPaused() {
        timer.start()
        timer.pause()

        let all = persistence.fetchAllIntervals()
        let openCount = all.filter { $0.endDate == nil }.count
        XCTAssertEqual(openCount, 0, "There should be 0 open intervals when paused")
    }

    func testAllClosedIntervalsHaveValidDateRange() {
        // Run several cycles
        for _ in 0..<3 {
            timer.start()
            let exp = expectation(description: "tick")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
            wait(for: [exp], timeout: 1)
            timer.pause()
        }

        let all = persistence.fetchAllIntervals()
        for interval in all {
            if let endDate = interval.endDate {
                XCTAssertGreaterThanOrEqual(endDate, interval.startDate,
                    "Closed interval must have endDate >= startDate")
                XCTAssertGreaterThan(endDate.timeIntervalSince(interval.startDate), 0,
                    "Closed interval must have positive duration")
            }
        }
    }

    func testRapidToggleDoesNotCorruptState() {
        for _ in 0..<10 {
            timer.toggle()
        }

        // After an even number of toggles, timer should be paused (started paused)
        XCTAssertFalse(timer.isRunning)

        let all = persistence.fetchAllIntervals()
        let openCount = all.filter { $0.endDate == nil }.count
        XCTAssertEqual(openCount, 0, "All intervals should be closed after even number of toggles")

        // Every closed interval must have valid date range
        for interval in all {
            if let endDate = interval.endDate {
                XCTAssertGreaterThanOrEqual(endDate, interval.startDate)
            }
        }
    }

    // MARK: - Recovery Edge Cases

    func testRecoveryOfTodayIntervalDoesNotRollover() {
        // Simulate: app quit without pausing, relaunched same day
        // Use a time guaranteed to be within today (not crossing midnight)
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: .now)
        let elapsed: TimeInterval = min(Date.now.timeIntervalSince(todayStart) / 2, 1800)
        // If we're very early in the day, use a small offset; otherwise ~30min
        let startTime = Date.now.addingTimeInterval(-max(elapsed, 60))

        guard calendar.isDateInToday(startTime) else {
            // If even a small offset crosses midnight, skip — test isn't meaningful
            return
        }

        let interval = ActiveInterval(startDate: startTime)
        context.insert(interval)
        try! context.save()

        let newTimer = TimerService(); newTimer.configure(persistenceService: persistence)

        // Should recover without rollover
        XCTAssertTrue(newTimer.isRunning)

        let open = persistence.fetchOpenInterval()
        XCTAssertNotNil(open)
        XCTAssertEqual(open!.startDate, startTime,
                       "Today's interval should not be modified by recovery")

        // Elapsed should be approximately the time since startTime
        let expectedElapsed = Date.now.timeIntervalSince(startTime)
        XCTAssertEqual(newTimer.currentIntervalElapsed, expectedElapsed, accuracy: 10)

        // displayTime should be less than wall-clock time since midnight
        let timeSinceMidnight = Date.now.timeIntervalSince(todayStart)
        XCTAssertLessThan(newTimer.displayTime, timeSinceMidnight,
                          "displayTime should be less than wall-clock time (not showing time since midnight)")
    }

    func testRecoveryWithNoOpenInterval() {
        // All intervals are closed — nothing to recover
        let interval = ActiveInterval(startDate: Date.now.addingTimeInterval(-3600),
                                      endDate: Date.now.addingTimeInterval(-1800))
        context.insert(interval)
        try! context.save()

        let newTimer = TimerService(); newTimer.configure(persistenceService: persistence)

        XCTAssertFalse(newTimer.isRunning, "Should not be running when all intervals are closed")
        XCTAssertEqual(newTimer.currentIntervalElapsed, 0)
    }

    // MARK: - Orphaned Interval Handling

    func testStartCleansOrphanedOpenIntervals() {
        // Simulate crash scenario: an old open interval exists in the DB
        let staleInterval = ActiveInterval(startDate: Date.now.addingTimeInterval(-86400))
        context.insert(staleInterval)
        try! context.save()

        // User starts a fresh timer — the stale interval should be cleaned up
        timer.start()

        let all = persistence.fetchAllIntervals()
        let openCount = all.filter { $0.endDate == nil }.count
        XCTAssertEqual(openCount, 1,
                       "Starting a timer should leave exactly 1 open interval, not 2")

        // The open interval should be the new one, not the stale one
        let open = persistence.fetchOpenInterval()
        XCTAssertNotNil(open)
        XCTAssertGreaterThan(open!.startDate, Date.now.addingTimeInterval(-5),
                             "The open interval should be the newly created one")
    }

    func testStartClosesOrphanedIntervalWithCorrectEndDate() {
        // An orphaned interval from 2 hours ago
        let staleStart = Date.now.addingTimeInterval(-7200)
        let staleInterval = ActiveInterval(startDate: staleStart)
        context.insert(staleInterval)
        try! context.save()

        timer.start()

        // The stale interval should now be closed
        let all = persistence.fetchAllIntervals()
        let closed = all.first { $0.startDate == staleStart }
        XCTAssertNotNil(closed)
        XCTAssertNotNil(closed!.endDate,
                        "Orphaned open interval should be closed when a new timer starts")
    }

    func testOrphanCloseIterationCap() {
        // This tests that the orphan-close loop won't run forever.
        // With a working persistence layer, the loop should always terminate normally.
        // The cap is a safety net — we just verify start() works with multiple orphans.
        for _ in 0..<5 {
            let orphan = ActiveInterval(startDate: Date.now.addingTimeInterval(-Double.random(in: 3600...86400)))
            context.insert(orphan)
        }
        try! context.save()

        timer.start()

        let all = persistence.fetchAllIntervals()
        let openCount = all.filter { $0.endDate == nil }.count
        XCTAssertEqual(openCount, 1, "Should have exactly 1 open interval after cleaning orphans")
    }

    func testRecoveryWithMultipleOpenIntervalsPicksMostRecent() {
        // Multiple orphaned open intervals — recovery should use the most recent
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))!

        let oldInterval = ActiveInterval(startDate: yesterday)
        let recentInterval = ActiveInterval(startDate: Date.now.addingTimeInterval(-600))

        context.insert(oldInterval)
        context.insert(recentInterval)
        try! context.save()

        let newTimer = TimerService(); newTimer.configure(persistenceService: persistence)

        // Should be running with the most recent interval's elapsed time (~10 min, not ~24h)
        XCTAssertTrue(newTimer.isRunning)
        XCTAssertLessThan(newTimer.currentIntervalElapsed, 3600,
                          "Should recover the most recent interval, not a day-old orphan")
    }

    func testRecoveryPreservesCompletedIntervalsInTodayTotal() {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: .now)

        // Two completed intervals from earlier today (1h each)
        let i1Start = todayStart.addingTimeInterval(3600)  // 01:00
        let i1End = todayStart.addingTimeInterval(7200)     // 02:00
        let i2Start = todayStart.addingTimeInterval(10800)  // 03:00
        let i2End = todayStart.addingTimeInterval(14400)     // 04:00

        let i1 = ActiveInterval(startDate: i1Start, endDate: i1End)
        let i2 = ActiveInterval(startDate: i2Start, endDate: i2End)

        // One open interval (still running)
        let i3 = ActiveInterval(startDate: Date.now.addingTimeInterval(-1800))

        context.insert(i1)
        context.insert(i2)
        context.insert(i3)
        try! context.save()

        let newTimer = TimerService(); newTimer.configure(persistenceService: persistence)

        // todayTotal should include the 2 completed intervals (2h = 7200s)
        XCTAssertEqual(newTimer.todayTotal, 7200, accuracy: 5)

        // displayTime should be todayTotal + current elapsed (~30 min)
        XCTAssertEqual(newTimer.displayTime, 7200 + 1800, accuracy: 10)
    }
}
