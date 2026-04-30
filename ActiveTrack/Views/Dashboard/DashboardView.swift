import SwiftUI
import OSLog

private let dashboardLogger = Logger(subsystem: "com.activetrack.app", category: "Dashboard")

private enum DashboardSelection: Hashable {
    case overview
    case day(Date)
}

struct DashboardMonthSection: Identifiable, Sendable {
    let monthStart: Date
    let title: String
    let average: TimeInterval
    let averageText: String
    let days: [Date]
    let dayRows: [DashboardSidebarDay]

    var id: Date { monthStart }

    init(monthStart: Date, title: String, average: TimeInterval, days: [Date], dayDurations: [Date: TimeInterval]) {
        self.monthStart = monthStart
        self.title = title
        self.average = average
        self.averageText = average.formattedHoursMinutes
        self.days = days
        self.dayRows = days.map { day in
            DashboardSidebarDay(
                day: day,
                title: day.shortDateString,
                subtitle: Calendar.current.isDateInToday(day) ? "Today" : nil,
                durationText: (dayDurations[day] ?? 0).formattedHoursMinutes
            )
        }
    }
}

struct DashboardSidebarDay: Identifiable, Sendable {
    let day: Date
    let title: String
    let subtitle: String?
    let durationText: String

    var id: Date { day }
}

struct DailyChartPoint: Identifiable, Sendable {
    let date: Date
    let hours: Double

    var id: Date { date }
}

struct WeeklyChartPoint: Identifiable, Sendable {
    let weekStart: Date
    let totalHours: Double
    let averagePerDayHours: Double

    var id: Date { weekStart }
}

struct MonthlyChartPoint: Identifiable, Sendable {
    let monthStart: Date
    let totalHours: Double
    let averagePerDayHours: Double

    var id: Date { monthStart }
}

struct DailyChartPresentation: Sendable {
    static let empty = DailyChartPresentation(data: [])

    let points: [DailyChartPoint]
    let averageHours: Double
    let summaryText: String
    let hasData: Bool

    init(data: [DailyTotal]) {
        points = data.map { DailyChartPoint(date: $0.date, hours: $0.duration / 3600) }
        let averageDuration = Self.averageDuration(data.map(\.duration))
        averageHours = averageDuration / 3600
        summaryText = "Average: \(averageDuration.formattedHoursMinutes) per day"
        hasData = data.contains { $0.duration > 0 }
    }

    private static func averageDuration(_ durations: [TimeInterval]) -> TimeInterval {
        guard !durations.isEmpty else { return 0 }
        return durations.reduce(0, +) / Double(durations.count)
    }
}

struct AggregateChartPresentation<Point: Identifiable & Sendable>: Sendable {
    let points: [Point]
    let totalAverageHours: Double
    let averagePerDayAverageHours: Double
    let totalSummaryText: String
    let averagePerDaySummaryText: String
    let hasData: Bool
}

struct DashboardChartPresentation: Sendable {
    static let empty = DashboardChartPresentation(chartData: HistoryChartData(daily: [], weekly: [], monthly: []))

    let daily: DailyChartPresentation
    let weekly: AggregateChartPresentation<WeeklyChartPoint>
    let monthly: AggregateChartPresentation<MonthlyChartPoint>

    init(chartData: HistoryChartData, calendar: Calendar = .current, now: Date = .now) {
        daily = DailyChartPresentation(data: chartData.daily)
        weekly = Self.weeklyPresentation(data: chartData.weekly, calendar: calendar, now: now)
        monthly = Self.monthlyPresentation(data: chartData.monthly, calendar: calendar, now: now)
    }

    private static func weeklyPresentation(
        data: [WeeklyTotal],
        calendar: Calendar,
        now: Date
    ) -> AggregateChartPresentation<WeeklyChartPoint> {
        let points = data.map { item in
            let days = Double(daysInDisplayedWeek(startingAt: item.weekStart, calendar: calendar, now: now))
            let averagePerDay = days > 0 ? item.duration / days : 0
            return WeeklyChartPoint(
                weekStart: item.weekStart,
                totalHours: item.duration / 3600,
                averagePerDayHours: averagePerDay / 3600
            )
        }
        let totalAverage = averageDuration(data.map(\.duration))
        let averagePerDayAverage = averageDuration(points.map { $0.averagePerDayHours * 3600 })
        return AggregateChartPresentation(
            points: points,
            totalAverageHours: totalAverage / 3600,
            averagePerDayAverageHours: averagePerDayAverage / 3600,
            totalSummaryText: "Average: \(totalAverage.formattedHoursMinutes) per week",
            averagePerDaySummaryText: "Average: \(averagePerDayAverage.formattedHoursMinutes) per day within each week",
            hasData: data.contains { $0.duration > 0 }
        )
    }

    private static func monthlyPresentation(
        data: [MonthlyTotal],
        calendar: Calendar,
        now: Date
    ) -> AggregateChartPresentation<MonthlyChartPoint> {
        let points = data.map { item in
            let days = Double(daysInDisplayedMonth(startingAt: item.monthStart, calendar: calendar, now: now))
            let averagePerDay = days > 0 ? item.duration / days : 0
            return MonthlyChartPoint(
                monthStart: item.monthStart,
                totalHours: item.duration / 3600,
                averagePerDayHours: averagePerDay / 3600
            )
        }
        let totalAverage = averageDuration(data.map(\.duration))
        let averagePerDayAverage = averageDuration(points.map { $0.averagePerDayHours * 3600 })
        return AggregateChartPresentation(
            points: points,
            totalAverageHours: totalAverage / 3600,
            averagePerDayAverageHours: averagePerDayAverage / 3600,
            totalSummaryText: "Average: \(totalAverage.formattedHoursMinutes) per month",
            averagePerDaySummaryText: "Average: \(averagePerDayAverage.formattedHoursMinutes) per day within each month",
            hasData: data.contains { $0.duration > 0 }
        )
    }

    private static func averageDuration(_ durations: [TimeInterval]) -> TimeInterval {
        guard !durations.isEmpty else { return 0 }
        return durations.reduce(0, +) / Double(durations.count)
    }

    private static func daysInDisplayedWeek(startingAt weekStart: Date, calendar: Calendar, now: Date) -> Int {
        let today = calendar.startOfDay(for: now)
        let currentWeekStart = calendar.date(
            from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
        )!

        guard weekStart == currentWeekStart else { return 7 }
        return max(1, calendar.dateComponents([.day], from: weekStart, to: today).day! + 1)
    }

    private static func daysInDisplayedMonth(startingAt monthStart: Date, calendar: Calendar, now: Date) -> Int {
        let today = calendar.startOfDay(for: now)
        let currentMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!

        if monthStart == currentMonthStart {
            return max(1, calendar.component(.day, from: today))
        }

        return calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
    }
}

struct DashboardDisplaySnapshot: Sendable {
    static let empty = DashboardDisplaySnapshot(
        chartData: HistoryChartData(daily: [], weekly: [], monthly: []),
        monthSections: [],
        dayDurations: [:],
        timerDisplay: TimerDisplaySnapshot(isRunning: false, displayTime: 0, currentIntervalElapsed: 0)
    )

    let chartData: HistoryChartData
    let chartPresentation: DashboardChartPresentation
    let monthSections: [DashboardMonthSection]
    let dayDurations: [Date: TimeInterval]
    let todayText: String
    let todayCaption: String
    let averageDailyText: String
    let averageWeeklyText: String
    let averageMonthlyText: String

    init(
        chartData: HistoryChartData,
        monthSections: [DashboardMonthSection],
        dayDurations: [Date: TimeInterval],
        timerDisplay: TimerDisplaySnapshot
    ) {
        let liveDuration = timerDisplay.isRunning ? timerDisplay.currentIntervalElapsed : 0
        let overlaidChartData = Self.overlayChartData(chartData, liveDuration: liveDuration)
        let overlaidDayDurations = Self.overlayDayDurations(dayDurations, liveDuration: liveDuration)

        self.chartData = overlaidChartData
        self.chartPresentation = DashboardChartPresentation(chartData: overlaidChartData)
        self.monthSections = Self.overlayMonthSections(
            monthSections,
            dayDurations: overlaidDayDurations
        )
        self.dayDurations = overlaidDayDurations
        self.todayText = timerDisplay.fullText
        self.todayCaption = timerDisplay.isRunning ? "Live total including current session" : "Tracked so far today"
        self.averageDailyText = Self.averageDuration(for: overlaidChartData.daily).formattedHoursMinutes
        self.averageWeeklyText = Self.averageDuration(for: overlaidChartData.weekly).formattedHoursMinutes
        self.averageMonthlyText = Self.averageDuration(for: overlaidChartData.monthly).formattedHoursMinutes
    }

    private static func overlayChartData(_ chartData: HistoryChartData, liveDuration: TimeInterval) -> HistoryChartData {
        guard liveDuration > 0 else { return chartData }
        return HistoryChartData(
            daily: overlayDailyTotals(chartData.daily, liveDuration: liveDuration),
            weekly: overlayWeeklyTotals(chartData.weekly, liveDuration: liveDuration),
            monthly: overlayMonthlyTotals(chartData.monthly, liveDuration: liveDuration)
        )
    }

    private static func overlayDailyTotals(_ items: [DailyTotal], liveDuration: TimeInterval) -> [DailyTotal] {
        let today = Calendar.current.startOfDay(for: .now)
        guard let dailyIndex = items.firstIndex(where: { $0.date == today }) else { return items }
        var updated = items
        updated[dailyIndex] = DailyTotal(date: today, duration: updated[dailyIndex].duration + liveDuration)
        return updated
    }

    private static func overlayWeeklyTotals(_ items: [WeeklyTotal], liveDuration: TimeInterval) -> [WeeklyTotal] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)),
              let weeklyIndex = items.firstIndex(where: { $0.weekStart == weekStart }) else {
            return items
        }
        var updated = items
        updated[weeklyIndex] = WeeklyTotal(
            weekStart: weekStart,
            duration: updated[weeklyIndex].duration + liveDuration
        )
        return updated
    }

    private static func overlayMonthlyTotals(_ items: [MonthlyTotal], liveDuration: TimeInterval) -> [MonthlyTotal] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today)),
              let monthlyIndex = items.firstIndex(where: { $0.monthStart == monthStart }) else {
            return items
        }
        var updated = items
        updated[monthlyIndex] = MonthlyTotal(
            monthStart: monthStart,
            duration: updated[monthlyIndex].duration + liveDuration
        )
        return updated
    }

    private static func overlayDayDurations(
        _ dayDurations: [Date: TimeInterval],
        liveDuration: TimeInterval
    ) -> [Date: TimeInterval] {
        let today = Calendar.current.startOfDay(for: .now)
        let todayTotal = (dayDurations[today] ?? 0) + liveDuration

        var overlaidDurations = dayDurations
        if todayTotal > 0.000_001 {
            overlaidDurations[today] = todayTotal
        } else {
            overlaidDurations.removeValue(forKey: today)
        }
        return overlaidDurations
    }

    private static func overlayMonthSections(
        _ sections: [DashboardMonthSection],
        dayDurations: [Date: TimeInterval]
    ) -> [DashboardMonthSection] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let currentMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) else {
            return sections
        }

        var overlaidSections = sections
        let todayTotal = dayDurations[today] ?? 0
        let persistedSection = sections.first(where: { $0.id == currentMonth })
        var monthDays = persistedSection?.days ?? []

        if todayTotal > 0.000_001 {
            if !monthDays.contains(today) {
                monthDays.append(today)
                monthDays.sort(by: >)
            }
        } else {
            monthDays.removeAll { $0 == today }
        }

        if monthDays.isEmpty {
            overlaidSections.removeAll { $0.id == currentMonth }
            return overlaidSections
        }

        let total = monthDays.reduce(0) { partial, day in
            partial + (dayDurations[day] ?? 0)
        }
        let updatedSection = DashboardMonthSection(
            monthStart: currentMonth,
            title: currentMonth.monthYearString,
            average: total / Double(monthDays.count),
            days: monthDays,
            dayDurations: dayDurations
        )

        if let sectionIndex = overlaidSections.firstIndex(where: { $0.id == currentMonth }) {
            overlaidSections[sectionIndex] = updatedSection
        } else {
            overlaidSections.append(updatedSection)
            overlaidSections.sort { $0.monthStart > $1.monthStart }
        }
        return overlaidSections
    }

    private static func averageDuration<T>(for items: [T]) -> TimeInterval where T: DashboardDurationReadable {
        guard !items.isEmpty else { return 0 }
        let total = items.reduce(0) { $0 + $1.duration }
        return total / Double(items.count)
    }
}

private protocol DashboardDurationReadable {
    var duration: TimeInterval { get }
}

extension DailyTotal: DashboardDurationReadable {}
extension WeeklyTotal: DashboardDurationReadable {}
extension MonthlyTotal: DashboardDurationReadable {}

private struct DashboardTimerDisplayKey: Equatable {
    let isRunning: Bool
    let displayMinute: Int
    let liveMinute: Int

    init(_ snapshot: TimerDisplaySnapshot) {
        isRunning = snapshot.isRunning
        displayMinute = Int(max(snapshot.displayTime, 0) / 60)
        liveMinute = Int(max(snapshot.currentIntervalElapsed, 0) / 60)
    }
}

@MainActor
@Observable
final class DashboardHistoryStore {
    private static let chartDays = 14
    private static let chartWeeks = 12
    private static let chartMonths = 12

    private let persistenceService: PersistenceService
    private(set) var dayDurations: [Date: TimeInterval] = [:]
    private(set) var chartData = HistoryChartData(daily: [], weekly: [], monthly: [])
    private(set) var monthSections: [DashboardMonthSection] = []
    private(set) var displaySnapshot = DashboardDisplaySnapshot.empty
    private var hasLoaded = false
    private var latestTimerDisplaySnapshot = TimerDisplaySnapshot(
        isRunning: false,
        displayTime: 0,
        currentIntervalElapsed: 0
    )
    private var latestTimerDisplayKey: DashboardTimerDisplayKey?

    init(persistenceService: PersistenceService) {
        self.persistenceService = persistenceService
    }

    func reloadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        let startedAt = Date.now
        dashboardLogger.info("Dashboard history reload started")
        let snapshot = await persistenceService.dashboardHistorySnapshotAsync(
            days: Self.chartDays,
            weeks: Self.chartWeeks,
            months: Self.chartMonths
        )
        apply(snapshot)
        hasLoaded = true
        dashboardLogger.info(
            "Dashboard history reload finished days=\(snapshot.dayDurations.count, privacy: .public) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt), privacy: .public)"
        )
    }

    func apply(_ change: PersistenceChange) async {
        let startedAt = Date.now
        dashboardLogger.info(
            "Dashboard persistence change received full_reload=\(change.requiresFullReload, privacy: .public) affected_days=\(change.affectedDays.count, privacy: .public)"
        )

        if change.requiresFullReload || !hasLoaded {
            await reload()
            return
        }

        guard !change.affectedDays.isEmpty else { return }
        let updatedDurations = await persistenceService.dayDurationsAsync(for: change.affectedDays)
        var nextDurations = dayDurations

        for day in change.affectedDays {
            if let duration = updatedDurations[day], duration > 0.000_001 {
                nextDurations[day] = duration
            } else {
                nextDurations.removeValue(forKey: day)
            }
        }

        apply(dayDurations: nextDurations, affectedDays: change.affectedDays)
        dashboardLogger.info(
            "Dashboard persistence change applied affected_days=\(change.affectedDays.count, privacy: .public) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt), privacy: .public)"
        )
    }

    func updateDisplaySnapshot(timerDisplaySnapshot: TimerDisplaySnapshot, force: Bool = false) {
        latestTimerDisplaySnapshot = timerDisplaySnapshot
        let timerDisplayKey = DashboardTimerDisplayKey(timerDisplaySnapshot)
        guard force || timerDisplayKey != latestTimerDisplayKey else { return }
        latestTimerDisplayKey = timerDisplayKey
        rebuildDisplaySnapshot(reason: "timer")
    }

    private func apply(_ snapshot: DashboardHistorySnapshot) {
        dayDurations = snapshot.dayDurations
        chartData = snapshot.chartData
        monthSections = Self.buildMonthSections(from: snapshot.dayDurations)
        rebuildDisplaySnapshot(reason: "reload")
    }

    private func apply(dayDurations: [Date: TimeInterval], affectedDays: Set<Date>) {
        self.dayDurations = dayDurations
        if Self.affectsVisibleChartRange(affectedDays) {
            chartData = persistenceService.chartData(
                from: dayDurations,
                days: Self.chartDays,
                weeks: Self.chartWeeks,
                months: Self.chartMonths
            )
        }
        monthSections = Self.updateMonthSections(
            monthSections,
            from: dayDurations,
            affectedDays: affectedDays
        )
        rebuildDisplaySnapshot(reason: "persistence")
    }

    private func rebuildDisplaySnapshot(reason: String) {
        let startedAt = Date.now
        displaySnapshot = DashboardDisplaySnapshot(
            chartData: chartData,
            monthSections: monthSections,
            dayDurations: dayDurations,
            timerDisplay: latestTimerDisplaySnapshot
        )
        dashboardLogger.debug(
            "Dashboard display snapshot rebuilt reason=\(reason, privacy: .public) days=\(self.displaySnapshot.dayDurations.count, privacy: .public) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt), privacy: .public)"
        )
    }

    private static func buildMonthSections(from dayDurations: [Date: TimeInterval]) -> [DashboardMonthSection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: dayDurations.keys) { day in
            calendar.date(from: calendar.dateComponents([.year, .month], from: day))!
        }

        return grouped.keys
            .sorted(by: >)
            .map { monthStart in
                let monthDays = grouped[monthStart, default: []].sorted(by: >)
                let total = monthDays.reduce(0) { $0 + (dayDurations[$1] ?? 0) }
                let average = monthDays.isEmpty ? 0 : total / Double(monthDays.count)
                return DashboardMonthSection(
                    monthStart: monthStart,
                    title: monthStart.monthYearString,
                    average: average,
                    days: monthDays,
                    dayDurations: dayDurations
                )
            }
    }

    private static func updateMonthSections(
        _ existingSections: [DashboardMonthSection],
        from dayDurations: [Date: TimeInterval],
        affectedDays: Set<Date>
    ) -> [DashboardMonthSection] {
        let calendar = Calendar.current
        let changedMonths = Set(affectedDays.compactMap { monthStart(for: $0, calendar: calendar) })
        guard !changedMonths.isEmpty else { return existingSections }

        var sectionsByMonth = Dictionary(uniqueKeysWithValues: existingSections.map { ($0.monthStart, $0) })
        var daysByChangedMonth: [Date: [Date]] = [:]

        for day in dayDurations.keys {
            guard let monthStart = monthStart(for: day, calendar: calendar), changedMonths.contains(monthStart) else {
                continue
            }
            daysByChangedMonth[monthStart, default: []].append(day)
        }

        for monthStart in changedMonths {
            let monthDays = daysByChangedMonth[monthStart, default: []].sorted(by: >)
            guard !monthDays.isEmpty else {
                sectionsByMonth.removeValue(forKey: monthStart)
                continue
            }

            let total = monthDays.reduce(0) { $0 + (dayDurations[$1] ?? 0) }
            sectionsByMonth[monthStart] = DashboardMonthSection(
                monthStart: monthStart,
                title: monthStart.monthYearString,
                average: total / Double(monthDays.count),
                days: monthDays,
                dayDurations: dayDurations
            )
        }

        return sectionsByMonth.keys.sorted(by: >).compactMap { sectionsByMonth[$0] }
    }

    private static func affectsVisibleChartRange(_ affectedDays: Set<Date>) -> Bool {
        guard let range = visibleChartRange() else { return true }
        return affectedDays.contains { day in
            day >= range.start && day < range.end
        }
    }

    private static func visibleChartRange(now: Date = .now, calendar: Calendar = .current) -> (start: Date, end: Date)? {
        var rangeStarts: [Date] = []
        var rangeEnds: [Date] = []

        if chartDays > 0 {
            let today = calendar.startOfDay(for: now)
            if let firstDay = calendar.date(byAdding: .day, value: -(chartDays - 1), to: today),
               let end = calendar.date(byAdding: .day, value: 1, to: today) {
                rangeStarts.append(firstDay)
                rangeEnds.append(end)
            }
        }

        if chartWeeks > 0 {
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            if let currentWeekStart = calendar.date(from: components),
               let firstWeekStart = calendar.date(byAdding: .weekOfYear, value: -(chartWeeks - 1), to: currentWeekStart),
               let end = calendar.date(byAdding: .day, value: 7, to: currentWeekStart) {
                rangeStarts.append(firstWeekStart)
                rangeEnds.append(end)
            }
        }

        if chartMonths > 0 {
            let components = calendar.dateComponents([.year, .month], from: now)
            if let currentMonthStart = calendar.date(from: components),
               let firstMonthStart = calendar.date(byAdding: .month, value: -(chartMonths - 1), to: currentMonthStart),
               let end = calendar.date(byAdding: .month, value: 1, to: currentMonthStart) {
                rangeStarts.append(firstMonthStart)
                rangeEnds.append(end)
            }
        }

        guard let start = rangeStarts.min(), let end = rangeEnds.max() else { return nil }
        return (start, end)
    }

    private static func monthStart(for day: Date, calendar: Calendar) -> Date? {
        calendar.date(from: calendar.dateComponents([.year, .month], from: day))
    }

    private static func elapsedMilliseconds(since startedAt: Date) -> Int {
        Int(Date.now.timeIntervalSince(startedAt) * 1000)
    }
}

struct DashboardView: View {
    let timerService: TimerService
    let persistenceService: PersistenceService

    @State private var historyStore: DashboardHistoryStore
    @State private var selectedItem: DashboardSelection = .overview
    @State private var expandedMonths: Set<Date> = []
    @State private var splitVisibility: NavigationSplitViewVisibility = .all

    init(timerService: TimerService, persistenceService: PersistenceService) {
        self.timerService = timerService
        self.persistenceService = persistenceService
        _historyStore = State(initialValue: DashboardHistoryStore(persistenceService: persistenceService))
    }

    var body: some View {
        if timerService.isDashboardSafeMode {
            VStack(alignment: .leading, spacing: 12) {
                Text("Dashboard (Safe Mode)")
                    .font(.title2.bold())
                Text("History charts are temporarily disabled to keep ActiveTrack stable.")
                    .foregroundStyle(.secondary)
                Text("Timer persistence is active, and tracking continues from the menu bar.")
                    .foregroundStyle(.secondary)
                Text("Current session: \(timerService.displaySnapshot.fullText)")
                    .font(.system(.title3, design: .monospaced, weight: .medium))
                    .padding(.top, 6)
                Spacer()
            }
            .padding(24)
            .navigationTitle("ActiveTrack")
            .accessibilityIdentifier("activeTrack.dashboardRoot")
        } else {
            NavigationSplitView(columnVisibility: $splitVisibility) {
                DashboardSidebarView(
                    displaySnapshot: historyStore.displaySnapshot,
                    selectedItem: $selectedItem,
                    expandedMonths: $expandedMonths,
                    splitVisibility: $splitVisibility
                )
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
            } detail: {
                switch selectedItem {
                case .overview:
                    ChartContainerView(displaySnapshot: historyStore.displaySnapshot)
                case .day(let day):
                    DayDetailView(day: day, timerService: timerService, persistenceService: persistenceService)
                }
            }
            .navigationTitle("ActiveTrack")
            .accessibilityIdentifier("activeTrack.dashboardRoot")
            .task {
                historyStore.updateDisplaySnapshot(timerDisplaySnapshot: timerService.displaySnapshot)
                await historyStore.reloadIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .activeTrackDisplayTimeChanged)) { _ in
                historyStore.updateDisplaySnapshot(timerDisplaySnapshot: timerService.displaySnapshot)
            }
            .onReceive(NotificationCenter.default.publisher(for: .activeTrackTimerStatusChanged)) { _ in
                historyStore.updateDisplaySnapshot(timerDisplaySnapshot: timerService.displaySnapshot)
            }
            .onReceive(NotificationCenter.default.publisher(for: .activeTrackPersistenceDidChange)) { notification in
                Task {
                    if let change = notification.object as? PersistenceChange {
                        await historyStore.apply(change)
                    } else {
                        await historyStore.reload()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .activeTrackShowDashboardOverview)) { _ in
                showOverview()
            }
        }
    }

    private func showOverview() {
        selectedItem = .overview
        splitVisibility = .all
        expandedMonths.removeAll()
    }
}

private struct DashboardSidebarView: View {
    let displaySnapshot: DashboardDisplaySnapshot

    @Binding var selectedItem: DashboardSelection
    @Binding var expandedMonths: Set<Date>
    @Binding var splitVisibility: NavigationSplitViewVisibility

    private var displayedMonthSections: [DashboardMonthSection] {
        displaySnapshot.monthSections
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sidebarButton(
                    title: "Overview",
                    subtitle: "Charts and averages",
                    trailing: nil,
                    isSelected: selectedItem == .overview,
                    accessibilityIdentifier: "activeTrack.overviewButton"
                ) {
                    selectedItem = .overview
                    splitVisibility = .all
                    expandedMonths.removeAll()
                }

                if displayedMonthSections.isEmpty {
                    ContentUnavailableView {
                        Label("No Data Yet", systemImage: "clock")
                    } description: {
                        Text("Start the timer from the menu bar to begin tracking.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    ForEach(displayedMonthSections) { section in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedMonths.contains(section.id) },
                                set: { isExpanded in
                                    if isExpanded {
                                        expandedMonths.insert(section.id)
                                    } else {
                                        expandedMonths.remove(section.id)
                                    }
                                }
                            )
                        ) {
                            VStack(spacing: 6) {
                                ForEach(section.dayRows) { row in
                                    sidebarButton(
                                        title: row.title,
                                        subtitle: row.subtitle,
                                        trailing: row.durationText,
                                        isSelected: selectedItem == .day(row.day)
                                    ) {
                                        selectedItem = .day(row.day)
                                        splitVisibility = .all
                                    }
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(section.title)
                                        .font(.headline)
                                    Text("\(section.days.count) logged day\(section.days.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("Avg per logged day")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(section.averageText)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func sidebarButton(
        title: String,
        subtitle: String?,
        trailing: String?,
        isSelected: Bool,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }
}

extension Notification.Name {
    static let activeTrackShowDashboardOverview = Notification.Name("ActiveTrackShowDashboardOverview")
    static let activeTrackTargetReached = Notification.Name("ActiveTrackTargetReached")
    static let activeTrackDisplayTimeChanged = Notification.Name("ActiveTrackDisplayTimeChanged")
    static let activeTrackTimerStatusChanged = Notification.Name("ActiveTrackTimerStatusChanged")
    static let activeTrackPersistenceDidChange = Notification.Name("ActiveTrackPersistenceDidChange")
}
