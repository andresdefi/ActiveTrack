import SwiftUI
import SwiftData

private enum DashboardSelection: Hashable {
    case overview
    case day(Date)
}

private struct DashboardMonthSection: Identifiable {
    let monthStart: Date
    let title: String
    let average: TimeInterval
    let days: [Date]

    var id: Date { monthStart }
}

struct DashboardView: View {
    let timerService: TimerService
    let persistenceService: PersistenceService
    @State private var selectedItem: DashboardSelection = .overview
    @State private var monthSections: [DashboardMonthSection] = []
    @State private var expandedMonths: Set<Date> = []
    @State private var dayDurations: [Date: TimeInterval] = [:]
    @State private var splitVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        if timerService.isDashboardSafeMode {
            VStack(alignment: .leading, spacing: 12) {
                Text("Dashboard (Safe Mode)")
                    .font(.title2.bold())
                Text("History charts are temporarily disabled to keep ActiveTrack stable.")
                    .foregroundStyle(.secondary)
                Text("Timer persistence is active, and tracking continues from the menu bar.")
                    .foregroundStyle(.secondary)
                Text("Current session: \(timerService.displayTime.formattedHoursMinutesSeconds)")
                    .font(.system(.title3, design: .monospaced, weight: .medium))
                    .padding(.top, 6)
                Spacer()
            }
            .padding(24)
            .navigationTitle("ActiveTrack")
        } else {
        NavigationSplitView(columnVisibility: $splitVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
        } detail: {
            switch selectedItem {
            case .overview:
                ChartContainerView(timerService: timerService, persistenceService: persistenceService)
            case .day(let day):
                DayDetailView(day: day, timerService: timerService, persistenceService: persistenceService)
            }
        }
        .navigationTitle("ActiveTrack")
        .onAppear {
            refreshDays()
        }
        .onChange(of: timerService.isRunning) {
            refreshDays()
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeTrackShowDashboardOverview)) { _ in
            showOverview()
        }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sidebarButton(
                    title: "Overview",
                    subtitle: "Charts and averages",
                    trailing: nil,
                    isSelected: selectedItem == .overview
                ) {
                    showOverview()
                }

                if monthSections.isEmpty {
                    ContentUnavailableView {
                        Label("No Data Yet", systemImage: "clock")
                    } description: {
                        Text("Start the timer from the menu bar to begin tracking.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    ForEach(monthSections) { section in
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

    private func refreshDays() {
        var durations = persistenceService.allDayDurations()
        if timerService.isRunning {
            let today = Calendar.current.startOfDay(for: .now)
            durations[today, default: 0] += timerService.currentIntervalElapsed
        }
        let days = durations.keys.sorted(by: >)
        dayDurations = durations
        monthSections = buildMonthSections(from: days, durations: durations)

        var expanded = expandedMonths.intersection(Set(monthSections.map(\.id)))
        if case .day(let selectedDay) = selectedItem,
           let selectedMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: selectedDay)) {
            expanded.insert(selectedMonth)
        }
        expandedMonths = expanded
    }

    private func durationForDay(_ day: Date) -> TimeInterval {
        dayDurations[day] ?? 0
    }

    private func buildMonthSections(from days: [Date], durations: [Date: TimeInterval]) -> [DashboardMonthSection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: days) { day in
            calendar.date(from: calendar.dateComponents([.year, .month], from: day))!
        }

        return grouped.keys
            .sorted(by: >)
            .map { monthStart in
                let monthDays = grouped[monthStart, default: []].sorted(by: >)
                let total = monthDays.reduce(0) { $0 + (durations[$1] ?? 0) }
                let average = monthDays.isEmpty ? 0 : total / Double(monthDays.count)
                return DashboardMonthSection(
                    monthStart: monthStart,
                    title: monthStart.monthYearString,
                    average: average,
                    days: monthDays
                )
            }
    }

    private func showOverview() {
        selectedItem = .overview
        splitVisibility = .all
        expandedMonths.removeAll()
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
    static let activeTrackTimerStatusChanged = Notification.Name("ActiveTrackTimerStatusChanged")
}
