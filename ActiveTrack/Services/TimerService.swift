import Foundation
import SwiftData
import AppKit

@Observable
final class TimerService {
    private(set) var isRunning = false
    private(set) var todayTotal: TimeInterval = 0
    private(set) var currentIntervalElapsed: TimeInterval = 0

    private var timer: Timer?
    private var midnightTimer: Timer?
    private var currentInterval: ActiveInterval?
    private var persistenceService: PersistenceService?
    private var sleepObserver: Any?
    private var wakeObserver: Any?

    var displayTime: TimeInterval {
        todayTotal + currentIntervalElapsed
    }

    func configure(persistenceService: PersistenceService) {
        self.persistenceService = persistenceService
        observeSleep()
        recoverOpenInterval()
        refreshTodayTotal()
        scheduleMidnightRollover()
    }

    func start() {
        guard let persistence = persistenceService, !isRunning else { return }

        refreshTodayTotal()
        let interval = persistence.createInterval()
        currentInterval = interval
        isRunning = true
        currentIntervalElapsed = 0
        startTicking()
    }

    func pause() {
        guard let persistence = persistenceService, let interval = currentInterval, isRunning else { return }

        persistence.closeInterval(interval)
        stopTicking()
        isRunning = false
        currentInterval = nil
        currentIntervalElapsed = 0
        refreshTodayTotal()
    }

    func toggle() {
        if isRunning {
            pause()
        } else {
            start()
        }
    }

    func refreshTodayTotal() {
        guard let persistence = persistenceService else { return }
        todayTotal = persistence.durationForDay(.now, completedOnly: true)
    }

    // MARK: - Private

    private func observeSleep() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSleep()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    // Internal for @testable access in tests
    func handleSleep() {
        pause()
    }

    // Internal for @testable access in tests
    func handleWake() {
        // Reschedule the midnight timer in case its fire date passed during sleep.
        // The guard in handleMidnightRollover protects against stale fires,
        // but rescheduling here avoids the stale fire altogether.
        scheduleMidnightRollover()
        refreshTodayTotal()
    }

    private func recoverOpenInterval() {
        guard let persistence = persistenceService else { return }

        if let openInterval = persistence.fetchOpenInterval() {
            currentInterval = openInterval
            isRunning = true
            currentIntervalElapsed = Date.now.timeIntervalSince(openInterval.startDate)

            if !Calendar.current.isDateInToday(openInterval.startDate) {
                handleMidnightRollover()
            }

            startTicking()
        }
    }

    private func startTicking() {
        stopTicking()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let interval = currentInterval else { return }
        currentIntervalElapsed = Date.now.timeIntervalSince(interval.startDate)

        if !Calendar.current.isDateInToday(interval.startDate) {
            handleMidnightRollover()
        }
    }

    private func scheduleMidnightRollover() {
        midnightTimer?.invalidate()
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) else { return }
        let delay = tomorrow.timeIntervalSince(.now)
        midnightTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.handleMidnightRollover()
        }
        RunLoop.current.add(midnightTimer!, forMode: .common)
    }

    // Internal for @testable access in tests
    func handleMidnightRollover() {
        if isRunning, let persistence = persistenceService, let interval = currentInterval {
            // Only split the interval if it actually started before today.
            // This guards against the timer firing late (e.g. after system wake)
            // when the current interval is entirely within today.
            guard !Calendar.current.isDateInToday(interval.startDate) else {
                refreshTodayTotal()
                scheduleMidnightRollover()
                return
            }

            let todayStart = Calendar.current.startOfDay(for: .now)

            persistence.closeInterval(interval, endDate: todayStart)

            let newInterval = persistence.createInterval(startDate: todayStart)
            currentInterval = newInterval
            currentIntervalElapsed = Date.now.timeIntervalSince(todayStart)
        }

        refreshTodayTotal()
        scheduleMidnightRollover()
    }
}
