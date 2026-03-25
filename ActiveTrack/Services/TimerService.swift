import Foundation
import SwiftData
import AppKit
import os.log

enum TimerTargetMode: String, CaseIterable, Identifiable {
    case fromNow = "from_now"
    case todayTotal = "today_total"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fromNow:
            return "From Now"
        case .todayTotal:
            return "Today Total"
        }
    }

    var summaryText: String {
        switch self {
        case .fromNow:
            return "from now"
        case .todayTotal:
            return "for today"
        }
    }
}

enum HealthLog {
    private static let queue = DispatchQueue(label: "com.activetrack.healthlog")

    static func event(_ name: String, metadata: [String: String] = [:]) {
        queue.async {
            let timestamp = Date.now.ISO8601Format()
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
    private enum DefaultsKey {
        static let targetDuration = "timerTarget.duration"
        static let targetMode = "timerTarget.mode"
        static let targetBaseline = "timerTarget.baseline"
        static let targetReferenceDay = "timerTarget.referenceDay"
        static let reachedTargetDuration = "timerTarget.reachedDuration"
        static let reachedTargetMode = "timerTarget.reachedMode"
        static let reachedTargetReferenceDay = "timerTarget.reachedReferenceDay"
    }

    private let persistenceEnabled = true
    private let dashboardSafeMode = false
    private let userDefaults: UserDefaults
    private(set) var isRunning = false
    private(set) var todayTotal: TimeInterval = 0
    private(set) var currentIntervalElapsed: TimeInterval = 0
    private(set) var lastError: PersistenceError?
    private(set) var targetDuration: TimeInterval?
    private(set) var targetMode: TimerTargetMode = .fromNow
    private(set) var targetBaseline: TimeInterval = 0
    private(set) var reachedTargetDuration: TimeInterval?
    private(set) var reachedTargetMode: TimerTargetMode?

    private var timer: Timer?
    private var midnightTimer: Timer?
    private var targetTimer: Timer?
    /// Cached start date of the current interval. Keep timer math on value
    /// types to avoid touching SwiftData model getters on tick callbacks.
    private var currentIntervalStartDate: Date?
    private var persistenceService: PersistenceService?
    private var sleepObserver: Any?
    private var wakeObserver: Any?
    private var targetReferenceDay: Date?
    private var reachedTargetReferenceDay: Date?

    var displayTime: TimeInterval {
        todayTotal + currentIntervalElapsed
    }

    var isTargetActive: Bool {
        targetDuration != nil
    }

    var hasReachedTarget: Bool {
        reachedTargetDuration != nil
    }

    var targetProgress: TimeInterval {
        switch targetMode {
        case .fromNow:
            return max(displayTime - targetBaseline, 0)
        case .todayTotal:
            return displayTime
        }
    }

    var remainingTargetTime: TimeInterval? {
        guard let targetDuration else { return nil }
        return max(targetDuration - targetProgress, 0)
    }

    var isPersistenceEnabled: Bool {
        persistenceEnabled
    }

    var isDashboardSafeMode: Bool {
        dashboardSafeMode
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        loadPersistedTargetState()
    }

    convenience init(persistenceService: PersistenceService, userDefaults: UserDefaults = .standard) {
        self.init(userDefaults: userDefaults)
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
        normalizeTargetStateForCurrentDay()
        evaluateTargetIfNeeded()
        refreshTargetDeadline()
    }

    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
            midnightTimer?.invalidate()
            targetTimer?.invalidate()
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
        dismissReachedTarget()

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
                refreshTargetDeadline()
                notifyStatusDidChange()
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
        refreshTargetDeadline()
        notifyStatusDidChange()
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
                notifyStatusDidChange()
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
        refreshTargetDeadline()
        notifyStatusDidChange()
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
        refreshTargetDeadline()
    }

    func setTarget(duration: TimeInterval, mode: TimerTargetMode) {
        let normalizedDuration = max(duration, 0)
        guard normalizedDuration > 0 else {
            clearTarget()
            return
        }

        targetDuration = normalizedDuration
        targetMode = mode
        targetBaseline = mode == .fromNow ? displayTime : 0
        targetReferenceDay = Calendar.current.startOfDay(for: .now)
        reachedTargetDuration = nil
        reachedTargetMode = nil
        reachedTargetReferenceDay = nil
        persistTargetState()
        persistReachedTargetState()
        HealthLog.event(
            "target_set",
            metadata: [
                "duration_seconds": String(Int(normalizedDuration)),
                "mode": mode.rawValue
            ]
        )
        evaluateTargetIfNeeded()
        refreshTargetDeadline()
    }

    func clearTarget() {
        targetDuration = nil
        targetBaseline = 0
        targetReferenceDay = nil
        reachedTargetDuration = nil
        reachedTargetMode = nil
        reachedTargetReferenceDay = nil
        persistTargetState()
        persistReachedTargetState()
        refreshTargetDeadline()
        HealthLog.event("target_cleared")
    }

    func dismissReachedTarget() {
        guard hasReachedTarget else { return }
        reachedTargetDuration = nil
        reachedTargetMode = nil
        reachedTargetReferenceDay = nil
        persistReachedTargetState()
    }

    // MARK: - Private

    private func observeSleep() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.handleSleep()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
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
        normalizeTargetStateForCurrentDay()
        notifyStatusDidChange()
    }

    func resetToday() {
        if isRunning {
            pause()
        }

        guard persistenceEnabled, let persistenceService else {
            todayTotal = 0
            currentIntervalElapsed = 0
            currentIntervalStartDate = nil
            clearTarget()
            notifyStatusDidChange()
            HealthLog.event("reset_today_in_memory")
            return
        }

        do {
            try persistenceService.resetToday()
            todayTotal = 0
            currentIntervalElapsed = 0
            currentIntervalStartDate = nil
            lastError = nil
            clearTarget()
            notifyStatusDidChange()
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
            MainActor.assumeIsolated { [weak self] in
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

    // Internal for @testable access in tests
    func tick() {
        refreshCurrentIntervalElapsed()
    }

    private func scheduleMidnightRollover() {
        midnightTimer?.invalidate()
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) else { return }
        let delay = tomorrow.timeIntervalSince(.now)
        let scheduled = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.handleMidnightRollover()
            }
        }
        RunLoop.current.add(scheduled, forMode: .common)
        midnightTimer = scheduled
    }

    // Internal for @testable access in tests
    func handleMidnightRollover() {
        clearTargetForNewDay()

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
        notifyStatusDidChange()
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

    private func evaluateTargetIfNeeded() {
        guard let targetDuration, isTargetActive else { return }
        guard targetProgress >= targetDuration else { return }
        handleTargetReached()
    }

    private func handleTargetReached() {
        guard let duration = targetDuration else { return }
        let mode = targetMode

        targetDuration = nil
        targetBaseline = 0
        targetReferenceDay = nil
        reachedTargetDuration = duration
        reachedTargetMode = mode
        reachedTargetReferenceDay = Calendar.current.startOfDay(for: .now)
        persistTargetState()
        persistReachedTargetState()
        HealthLog.event(
            "target_reached",
            metadata: [
                "duration_seconds": String(Int(duration)),
                "mode": mode.rawValue
            ]
        )

        if isRunning {
            pause()
        }

        NotificationCenter.default.post(name: .activeTrackTargetReached, object: nil)
    }

    private func refreshCurrentIntervalElapsed() {
        guard let startDate = currentIntervalStartDate else { return }
        currentIntervalElapsed = Date.now.timeIntervalSince(startDate)
    }

    private func refreshTargetDeadline() {
        targetTimer?.invalidate()
        targetTimer = nil

        guard isTargetActive else { return }
        evaluateTargetIfNeeded()
        guard isTargetActive, isRunning, let remainingTargetTime else { return }

        let scheduled = Timer.scheduledTimer(withTimeInterval: max(remainingTargetTime, 0.05), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.handleTargetDeadlineReached()
            }
        }
        RunLoop.current.add(scheduled, forMode: .common)
        targetTimer = scheduled
    }

    private func handleTargetDeadlineReached() {
        targetTimer?.invalidate()
        targetTimer = nil
        refreshCurrentIntervalElapsed()
        evaluateTargetIfNeeded()

        if isTargetActive {
            refreshTargetDeadline()
        }
    }

    private func clearTargetForNewDay() {
        guard isTargetActive || hasReachedTarget else { return }
        clearTarget()
        HealthLog.event("target_cleared_new_day")
    }

    private func normalizeTargetStateForCurrentDay() {
        let todayStart = Calendar.current.startOfDay(for: .now)

        if let targetReferenceDay, !Calendar.current.isDate(targetReferenceDay, inSameDayAs: todayStart) {
            targetDuration = nil
            targetBaseline = 0
            self.targetReferenceDay = nil
        }

        if let reachedTargetReferenceDay, !Calendar.current.isDate(reachedTargetReferenceDay, inSameDayAs: todayStart) {
            reachedTargetDuration = nil
            reachedTargetMode = nil
            self.reachedTargetReferenceDay = nil
        }

        persistTargetState()
        persistReachedTargetState()
    }

    private func loadPersistedTargetState() {
        if let rawMode = userDefaults.string(forKey: DefaultsKey.targetMode),
           let persistedMode = TimerTargetMode(rawValue: rawMode) {
            targetMode = persistedMode
        }

        let persistedTargetDuration = userDefaults.double(forKey: DefaultsKey.targetDuration)
        if persistedTargetDuration > 0 {
            targetDuration = persistedTargetDuration
            targetBaseline = userDefaults.double(forKey: DefaultsKey.targetBaseline)
            if userDefaults.object(forKey: DefaultsKey.targetReferenceDay) != nil {
                targetReferenceDay = Date(timeIntervalSince1970: userDefaults.double(forKey: DefaultsKey.targetReferenceDay))
            }
        }

        let persistedReachedDuration = userDefaults.double(forKey: DefaultsKey.reachedTargetDuration)
        if persistedReachedDuration > 0 {
            reachedTargetDuration = persistedReachedDuration

            if let rawReachedMode = userDefaults.string(forKey: DefaultsKey.reachedTargetMode),
               let persistedReachedMode = TimerTargetMode(rawValue: rawReachedMode) {
                reachedTargetMode = persistedReachedMode
            }

            if userDefaults.object(forKey: DefaultsKey.reachedTargetReferenceDay) != nil {
                reachedTargetReferenceDay = Date(timeIntervalSince1970: userDefaults.double(forKey: DefaultsKey.reachedTargetReferenceDay))
            }
        }
    }

    private func persistTargetState() {
        if let targetDuration {
            userDefaults.set(targetDuration, forKey: DefaultsKey.targetDuration)
            userDefaults.set(targetMode.rawValue, forKey: DefaultsKey.targetMode)
            userDefaults.set(targetBaseline, forKey: DefaultsKey.targetBaseline)
            userDefaults.set(targetReferenceDay?.timeIntervalSince1970, forKey: DefaultsKey.targetReferenceDay)
        } else {
            userDefaults.removeObject(forKey: DefaultsKey.targetDuration)
            userDefaults.removeObject(forKey: DefaultsKey.targetBaseline)
            userDefaults.removeObject(forKey: DefaultsKey.targetReferenceDay)
        }
    }

    private func persistReachedTargetState() {
        if let reachedTargetDuration, let reachedTargetMode {
            userDefaults.set(reachedTargetDuration, forKey: DefaultsKey.reachedTargetDuration)
            userDefaults.set(reachedTargetMode.rawValue, forKey: DefaultsKey.reachedTargetMode)
            userDefaults.set(reachedTargetReferenceDay?.timeIntervalSince1970, forKey: DefaultsKey.reachedTargetReferenceDay)
        } else {
            userDefaults.removeObject(forKey: DefaultsKey.reachedTargetDuration)
            userDefaults.removeObject(forKey: DefaultsKey.reachedTargetMode)
            userDefaults.removeObject(forKey: DefaultsKey.reachedTargetReferenceDay)
        }
    }

    private func notifyStatusDidChange() {
        NotificationCenter.default.post(name: .activeTrackTimerStatusChanged, object: nil)
    }
}
