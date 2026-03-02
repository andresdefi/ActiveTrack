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
}
