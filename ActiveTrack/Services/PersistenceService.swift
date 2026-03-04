import Foundation
import SwiftData

enum PersistenceError: Error, Equatable {
    case saveFailed(underlying: String)

    static func == (lhs: PersistenceError, rhs: PersistenceError) -> Bool {
        switch (lhs, rhs) {
        case let (.saveFailed(a), .saveFailed(b)):
            return a == b
        }
    }
}

struct DailyTotal: Identifiable {
    let date: Date
    let duration: TimeInterval
    var id: Date { date }
}

struct WeeklyTotal: Identifiable {
    let weekStart: Date
    let duration: TimeInterval
    var id: Date { weekStart }
}

struct MonthlyTotal: Identifiable {
    let monthStart: Date
    let duration: TimeInterval
    var id: Date { monthStart }
}

@Observable
final class PersistenceService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - CRUD

    @discardableResult
    func createInterval(startDate: Date = .now) throws -> ActiveInterval {
        let interval = ActiveInterval(startDate: startDate)
        modelContext.insert(interval)
        do {
            try modelContext.save()
        } catch {
            throw PersistenceError.saveFailed(underlying: error.localizedDescription)
        }
        return interval
    }

    func closeInterval(_ interval: ActiveInterval, endDate: Date = .now) throws {
        interval.endDate = endDate
        do {
            try modelContext.save()
        } catch {
            throw PersistenceError.saveFailed(underlying: error.localizedDescription)
        }
    }

    func deleteInterval(_ interval: ActiveInterval) throws {
        modelContext.delete(interval)
        do {
            try modelContext.save()
        } catch {
            throw PersistenceError.saveFailed(underlying: error.localizedDescription)
        }
    }

    func fetchOpenInterval() -> ActiveInterval? {
        let descriptor = FetchDescriptor<ActiveInterval>(
            predicate: #Predicate { $0.endDate == nil },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        return try? modelContext.fetch(descriptor).first
    }

    func fetchAllIntervals() -> [ActiveInterval] {
        let descriptor = FetchDescriptor<ActiveInterval>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Midnight-Splitting Aggregation

    func durationForDay(_ date: Date, completedOnly: Bool = false) -> TimeInterval {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        var intervals = fetchIntervalsOverlapping(start: dayStart, end: dayEnd)
        if completedOnly {
            intervals = intervals.filter { $0.endDate != nil }
        }
        return intervals.reduce(0) { total, interval in
            total + clampedDuration(of: interval, dayStart: dayStart, dayEnd: dayEnd)
        }
    }

    func dailyTotals(days: Int = 14) -> [DailyTotal] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        return (0..<days).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let duration = durationForDay(date)
            return DailyTotal(date: date, duration: duration)
        }.reversed()
    }

    func weeklyTotals(weeks: Int = 12) -> [WeeklyTotal] {
        let calendar = Calendar.current
        let todayComponents = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: .now)
        guard let currentWeekStart = calendar.date(from: todayComponents) else { return [] }

        return (0..<weeks).compactMap { offset in
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: -offset, to: currentWeekStart) else { return nil }
            let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
            let duration = durationForRange(start: weekStart, end: weekEnd)
            return WeeklyTotal(weekStart: weekStart, duration: duration)
        }.reversed()
    }

    func monthlyTotals(months: Int = 12) -> [MonthlyTotal] {
        let calendar = Calendar.current
        let todayComponents = calendar.dateComponents([.year, .month], from: .now)
        guard let currentMonthStart = calendar.date(from: todayComponents) else { return [] }

        return (0..<months).compactMap { offset in
            guard let monthStart = calendar.date(byAdding: .month, value: -offset, to: currentMonthStart),
                  let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return nil }
            let duration = durationForRange(start: monthStart, end: monthEnd)
            return MonthlyTotal(monthStart: monthStart, duration: duration)
        }.reversed()
    }

    func intervalsForDay(_ date: Date) -> [(start: Date, end: Date, duration: TimeInterval)] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        let intervals = fetchIntervalsOverlapping(start: dayStart, end: dayEnd)
        return intervals.map { interval in
            let effectiveStart = max(interval.startDate, dayStart)
            let effectiveEnd = min(interval.endDate ?? .now, dayEnd)
            let duration = effectiveEnd.timeIntervalSince(effectiveStart)
            return (start: effectiveStart, end: effectiveEnd, duration: max(0, duration))
        }
    }

    func daysWithData() -> [Date] {
        let intervals = fetchAllIntervals()
        var daySet = Set<Date>()
        let calendar = Calendar.current

        for interval in intervals {
            let start = calendar.startOfDay(for: interval.startDate)
            let end = calendar.startOfDay(for: interval.endDate ?? .now)
            var current = start
            while current <= end {
                daySet.insert(current)
                current = calendar.date(byAdding: .day, value: 1, to: current)!
            }
        }

        return daySet.sorted(by: >)
    }

    // MARK: - Private Helpers

    private func fetchIntervalsOverlapping(start: Date, end: Date) -> [ActiveInterval] {
        // Fetch all intervals that started before the range end
        let descriptor = FetchDescriptor<ActiveInterval>(
            predicate: #Predicate<ActiveInterval> { interval in
                interval.startDate < end
            },
            sortBy: [SortDescriptor(\.startDate)]
        )
        let candidates = (try? modelContext.fetch(descriptor)) ?? []
        // Filter in-memory: keep intervals that are still open or end after range start
        return candidates.filter { interval in
            interval.endDate == nil || interval.endDate! > start
        }
    }

    private func clampedDuration(of interval: ActiveInterval, dayStart: Date, dayEnd: Date) -> TimeInterval {
        let effectiveStart = max(interval.startDate, dayStart)
        let effectiveEnd = min(interval.endDate ?? .now, dayEnd)
        return max(0, effectiveEnd.timeIntervalSince(effectiveStart))
    }

    private func durationForRange(start: Date, end: Date) -> TimeInterval {
        let calendar = Calendar.current
        var total: TimeInterval = 0
        var current = start
        while current < end {
            total += durationForDay(current)
            current = calendar.date(byAdding: .day, value: 1, to: current)!
        }
        return total
    }
}
