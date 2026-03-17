import Foundation
import SwiftData
import AppKit
import os.log

enum HealthLog {
    private static let queue = DispatchQueue(label: "com.activetrack.healthlog")

    static func event(_ name: String, metadata: [String: String] = [:]) {
        queue.async {
            let timestamp = ISO8601DateFormatter().string(from: .now)
            let details = metadata
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            let line = details.isEmpty ? "\(timestamp) \(name)\n" : "\(timestamp) \(name) \(details)\n"

            let url = logFileURL()
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let data = line.data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Best-effort diagnostics only.
            }
        }
    }

    private static func logFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("ActiveTrack", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("health.log")
    }
}

private let logger = Logger(subsystem: "com.activetrack.app", category: "TimerService")

@MainActor
@Observable
final class TimerService {
    private let persistenceEnabled = true
    private let dashboardSafeMode = false
    private(set) var isRunning = false
    private(set) var todayTotal: TimeInterval = 0
    private(set) var currentIntervalElapsed: TimeInterval = 0
    private(set) var lastError: PersistenceError?

    private var timer: Timer?
    private var midnightTimer: Timer?
    /// Cached start date of the current interval. Keep timer math on value
    /// types to avoid touching SwiftData model getters on tick callbacks.
    private var currentIntervalStartDate: Date?
    private var persistenceService: PersistenceService?
    private var sleepObserver: Any?
    private var wakeObserver: Any?

    var displayTime: TimeInterval {
        todayTotal + currentIntervalElapsed
    }

    var isPersistenceEnabled: Bool {
        persistenceEnabled
    }

    var isDashboardSafeMode: Bool {
        dashboardSafeMode
    }

    init() {}

    convenience init(persistenceService: PersistenceService) {
        self.init()
        configure(persistenceService: persistenceService)
    }

    func configure(persistenceService: PersistenceService) {
        self.persistenceService = persistenceService
        observeSleep()
        if persistenceEnabled {
            recoverOpenInterval()
            refreshTodayTotal()
        }
        scheduleMidnightRollover()
    }

    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
            midnightTimer?.invalidate()
            if let sleepObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            }
            if let wakeObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            }
        }
    }

    func start() {
        guard !isRunning else { return }

        if persistenceEnabled, let persistenceService {
            do {
                try closeStaleOpenIntervals(keepingMostRecent: false)
                let startDate = Date.now
                _ = try persistenceService.createInterval(startDate: startDate)
                currentIntervalStartDate = startDate
                isRunning = true
                currentIntervalElapsed = 0
                lastError = nil
                startTicking()
                HealthLog.event("timer_start")
            } catch {
                logger.error("Failed to create interval: \(error.localizedDescription)")
                lastError = error as? PersistenceError
                HealthLog.event("timer_start_failed", metadata: ["error": error.localizedDescription])
            }
            return
        }

        currentIntervalStartDate = .now
        isRunning = true
        currentIntervalElapsed = 0
        lastError = nil
        startTicking()
        HealthLog.event("timer_start_in_memory")
    }

    func pause() {
        guard isRunning else { return }

        if persistenceEnabled, let persistenceService {
            do {
                if let interval = persistenceService.fetchOpenInterval() {
                    try persistenceService.closeInterval(interval)
                }
                lastError = nil
                stopTicking()
                isRunning = false
                currentIntervalStartDate = nil
                currentIntervalElapsed = 0
                refreshTodayTotal()
                HealthLog.event("timer_pause")
            } catch {
                logger.error("Failed to close interval: \(error.localizedDescription)")
                lastError = error as? PersistenceError
                // Keep timer running so user knows data isn't saved yet
                HealthLog.event("timer_pause_failed", metadata: ["error": error.localizedDescription])
            }
            return
        }

        stopTicking()
        isRunning = false
        todayTotal += currentIntervalElapsed
        currentIntervalStartDate = nil
        currentIntervalElapsed = 0
        lastError = nil
        HealthLog.event("timer_pause_in_memory")
    }

    func toggle() {
        if isRunning {
            pause()
        } else {
            start()
        }
    }

    func refreshTodayTotal() {
        guard persistenceEnabled, let persistenceService else { return }
        todayTotal = persistenceService.durationForDay(.now, completedOnly: true)
    }

    // MARK: - Private

    private func observeSleep() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSleep()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWake()
            }
        }
    }

    // Internal for @testable access in tests
    func handleSleep() {
        HealthLog.event("system_sleep")
        pause()
    }

    // Internal for @testable access in tests
    func handleWake() {
        HealthLog.event("system_wake")
        scheduleMidnightRollover()
        refreshTodayTotal()
    }

    func resetToday() {
        if isRunning {
            pause()
        }

        guard persistenceEnabled, let persistenceService else {
            todayTotal = 0
            currentIntervalElapsed = 0
            currentIntervalStartDate = nil
            HealthLog.event("reset_today_in_memory")
            return
        }

        do {
            try persistenceService.resetToday()
            todayTotal = 0
            currentIntervalElapsed = 0
            currentIntervalStartDate = nil
            lastError = nil
            HealthLog.event("reset_today")
        } catch {
            logger.error("Failed to reset today: \(error.localizedDescription)")
            lastError = error as? PersistenceError
            HealthLog.event("reset_today_failed", metadata: ["error": error.localizedDescription])
        }
    }

    private func recoverOpenInterval() {
        guard persistenceService != nil else { return }
        do {
            let recoveredInterval = try closeStaleOpenIntervals(keepingMostRecent: true)
            guard let recoveredInterval else { return }

            isRunning = true
            currentIntervalStartDate = recoveredInterval.startDate
            currentIntervalElapsed = Date.now.timeIntervalSince(recoveredInterval.startDate)
            lastError = nil

            if Calendar.current.isDateInToday(recoveredInterval.startDate) {
                startTicking()
                HealthLog.event("recovered_open_interval")
            } else {
                handleMidnightRollover()
                HealthLog.event("recovered_open_interval_rollover")
            }
        } catch {
            logger.error("Failed to recover open interval: \(error.localizedDescription)")
            lastError = error as? PersistenceError
            HealthLog.event("recover_open_interval_failed", metadata: ["error": error.localizedDescription])
        }
    }

    private func startTicking() {
        stopTicking()
        let scheduled = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.current.add(scheduled, forMode: .common)
        timer = scheduled
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let startDate = currentIntervalStartDate else { return }
        currentIntervalElapsed = Date.now.timeIntervalSince(startDate)

        if !Calendar.current.isDateInToday(startDate) {
            handleMidnightRollover()
        }
    }

    private func scheduleMidnightRollover() {
        midnightTimer?.invalidate()
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) else { return }
        let delay = tomorrow.timeIntervalSince(.now)
        let scheduled = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMidnightRollover()
            }
        }
        RunLoop.current.add(scheduled, forMode: .common)
        midnightTimer = scheduled
    }

    // Internal for @testable access in tests
    func handleMidnightRollover() {
        if !persistenceEnabled {
            let calendar = Calendar.current
            if isRunning, let startDate = currentIntervalStartDate, !calendar.isDateInToday(startDate) {
                let todayStart = calendar.startOfDay(for: .now)
                todayTotal = 0
                currentIntervalStartDate = todayStart
                currentIntervalElapsed = Date.now.timeIntervalSince(todayStart)
            } else if !isRunning {
                todayTotal = 0
            }

            scheduleMidnightRollover()
            return
        }

        if isRunning, let persistenceService, let startDate = currentIntervalStartDate {
            // Only split the interval if it actually started before today.
            guard !Calendar.current.isDateInToday(startDate) else {
                refreshTodayTotal()
                scheduleMidnightRollover()
                return
            }

            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: .now)

            do {
                // Multi-day gap: create one closed interval per day boundary
                var currentStart = startDate
                var nextMidnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: currentStart)!)

                // Close the original interval at the first midnight boundary.
                if let openInterval = persistenceService.fetchOpenInterval() {
                    try persistenceService.closeInterval(openInterval, endDate: nextMidnight)
                }
                currentStart = nextMidnight

                // Create intermediate day intervals for any days between start and today
                while currentStart < todayStart {
                    nextMidnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: currentStart)!)
                    let endOfDay = min(nextMidnight, todayStart)
                    try persistenceService.createInterval(startDate: currentStart)
                    if let intermediateInterval = persistenceService.fetchOpenInterval() {
                        try persistenceService.closeInterval(intermediateInterval, endDate: endOfDay)
                    }
                    currentStart = endOfDay
                }

                // Create new open interval for today
                let newInterval = try persistenceService.createInterval(startDate: todayStart)
                _ = newInterval
                currentIntervalStartDate = todayStart
                currentIntervalElapsed = Date.now.timeIntervalSince(todayStart)
                lastError = nil
            } catch {
                logger.error("Failed during midnight rollover: \(error.localizedDescription)")
                lastError = error as? PersistenceError
            }
        }

        refreshTodayTotal()
        scheduleMidnightRollover()
    }

    @discardableResult
    private func closeStaleOpenIntervals(keepingMostRecent: Bool) throws -> ActiveInterval? {
        guard let persistenceService else { return nil }

        let openIntervals = persistenceService.fetchAllIntervals()
            .filter { $0.endDate == nil }
            .sorted { $0.startDate > $1.startDate }

        guard let mostRecent = openIntervals.first else { return nil }

        let intervalsToClose = keepingMostRecent ? Array(openIntervals.dropFirst()) : openIntervals
        for interval in intervalsToClose {
            try persistenceService.closeInterval(interval, endDate: interval.startDate)
        }

        return keepingMostRecent ? mostRecent : nil
    }
}
