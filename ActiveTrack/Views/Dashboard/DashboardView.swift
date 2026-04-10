import SwiftUI

private enum DashboardSelection: Hashable {
    case overview
    case day(Date)
}

struct DashboardMonthSection: Identifiable, Sendable {
    let monthStart: Date
    let title: String
    let average: TimeInterval
    let days: [Date]

    var id: Date { monthStart }
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
    private var hasLoaded = false

    init(persistenceService: PersistenceService) {
        self.persistenceService = persistenceService
    }

    func reloadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        let snapshot = await persistenceService.dashboardHistorySnapshotAsync(
            days: Self.chartDays,
            weeks: Self.chartWeeks,
            months: Self.chartMonths
        )
        apply(snapshot)
        hasLoaded = true
    }

    func apply(_ change: PersistenceChange) async {
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
    }

    private func apply(_ snapshot: DashboardHistorySnapshot) {
        dayDurations = snapshot.dayDurations
        chartData = snapshot.chartData
        monthSections = Self.buildMonthSections(from: snapshot.dayDurations)
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
                    days: monthDays
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
                days: monthDays
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
                Text("Current session: \(timerService.displayTime.formattedHoursMinutes)")
                    .font(.system(.title3, design: .monospaced, weight: .medium))
                    .padding(.top, 6)
                Spacer()
            }
            .padding(24)
            .navigationTitle("ActiveTrack")
        } else {
            NavigationSplitView(columnVisibility: $splitVisibility) {
                DashboardSidebarView(
                    timerService: timerService,
                    monthSections: historyStore.monthSections,
                    dayDurations: historyStore.dayDurations,
                    selectedItem: $selectedItem,
                    expandedMonths: $expandedMonths,
                    splitVisibility: $splitVisibility
                )
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
            } detail: {
                switch selectedItem {
                case .overview:
                    ChartContainerView(timerService: timerService, historyStore: historyStore)
                case .day(let day):
                    DayDetailView(day: day, timerService: timerService, persistenceService: persistenceService)
                }
            }
            .navigationTitle("ActiveTrack")
            .task {
                await historyStore.reloadIfNeeded()
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
    let timerService: TimerService
    let monthSections: [DashboardMonthSection]
    let dayDurations: [Date: TimeInterval]

    @Binding var selectedItem: DashboardSelection
    @Binding var expandedMonths: Set<Date>
    @Binding var splitVisibility: NavigationSplitViewVisibility

    private var displayedMonthSections: [DashboardMonthSection] {
        applyLiveTodayOverlay(to: monthSections)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sidebarButton(
                    title: "Overview",
                    subtitle: "Charts and averages",
                    trailing: nil,
                    isSelected: selectedItem == .overview
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
                                ForEach(section.days, id: \.self) { day in
                                    sidebarButton(
                                        title: day.shortDateString,
                                        subtitle: Calendar.current.isDateInToday(day) ? "Today" : nil,
                                        trailing: durationForDay(day).formattedHoursMinutes,
                                        isSelected: selectedItem == .day(day)
                                    ) {
                                        selectedItem = .day(day)
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
                                Text(section.average.formattedHoursMinutes)
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

    private func applyLiveTodayOverlay(to sections: [DashboardMonthSection]) -> [DashboardMonthSection] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let currentMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) else {
            return sections
        }

        var overlaidSections = sections
        let liveDuration = timerService.isRunning ? timerService.currentIntervalElapsed : 0
        let todayTotal = (dayDurations[today] ?? 0) + liveDuration

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
            partial + (day == today ? todayTotal : (dayDurations[day] ?? 0))
        }
        let updatedSection = DashboardMonthSection(
            monthStart: currentMonth,
            title: currentMonth.monthYearString,
            average: total / Double(monthDays.count),
            days: monthDays
        )

        if let sectionIndex = overlaidSections.firstIndex(where: { $0.id == currentMonth }) {
            overlaidSections[sectionIndex] = updatedSection
        } else {
            overlaidSections.append(updatedSection)
            overlaidSections.sort { $0.monthStart > $1.monthStart }
        }

        return overlaidSections
    }

    private func durationForDay(_ day: Date) -> TimeInterval {
        let persistedDuration = dayDurations[day] ?? 0
        guard Calendar.current.isDateInToday(day) else { return persistedDuration }
        let liveDuration = timerService.isRunning ? timerService.currentIntervalElapsed : 0
        return persistedDuration + liveDuration
    }

    @ViewBuilder
    private func sidebarButton(
        title: String,
        subtitle: String?,
        trailing: String?,
        isSelected: Bool,
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
    }
}

extension Notification.Name {
    static let activeTrackShowDashboardOverview = Notification.Name("ActiveTrackShowDashboardOverview")
    static let activeTrackTargetReached = Notification.Name("ActiveTrackTargetReached")
    static let activeTrackDisplayTimeChanged = Notification.Name("ActiveTrackDisplayTimeChanged")
    static let activeTrackTimerStatusChanged = Notification.Name("ActiveTrackTimerStatusChanged")
    static let activeTrackPersistenceDidChange = Notification.Name("ActiveTrackPersistenceDidChange")
}
