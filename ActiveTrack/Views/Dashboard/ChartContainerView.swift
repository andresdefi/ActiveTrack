import SwiftUI

enum ChartPeriod: String, CaseIterable {
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"
}

enum AggregateChartMetric: String, CaseIterable {
    case total = "Total"
    case averagePerDay = "Avg / Day"
}

struct ChartContainerView: View {
    let timerService: TimerService
    let persistenceService: PersistenceService
    @State private var selectedPeriod: ChartPeriod = .daily
    @State private var aggregateMetric: AggregateChartMetric = .total
    @State private var persistedDailyData: [DailyTotal] = []
    @State private var persistedWeeklyData: [WeeklyTotal] = []
    @State private var persistedMonthlyData: [MonthlyTotal] = []

    private var displayedDailyData: [DailyTotal] {
        overlayDailyTotals(persistedDailyData)
    }

    private var displayedWeeklyData: [WeeklyTotal] {
        overlayWeeklyTotals(persistedWeeklyData)
    }

    private var displayedMonthlyData: [MonthlyTotal] {
        overlayMonthlyTotals(persistedMonthlyData)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Period", selection: $selectedPeriod) {
                    ForEach(ChartPeriod.allCases, id: \.self) { period in
                        Text(period.rawValue).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)

                if selectedPeriod != .daily {
                    Picker("Metric", selection: $aggregateMetric) {
                        ForEach(AggregateChartMetric.allCases, id: \.self) { metric in
                            Text(metric.rawValue).tag(metric)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    LiveTodayDashboardMetricCard(timerService: timerService)
                    DashboardMetricCard(
                        title: "Average / Day",
                        value: averageDuration(for: displayedDailyData).formattedHoursMinutes,
                        caption: "Across the last 14 days"
                    )
                    DashboardMetricCard(
                        title: "Average / Week",
                        value: averageDuration(for: displayedWeeklyData).formattedHoursMinutes,
                        caption: "Across the last 12 weeks"
                    )
                    DashboardMetricCard(
                        title: "Average / Month",
                        value: averageDuration(for: displayedMonthlyData).formattedHoursMinutes,
                        caption: "Across the last 12 months"
                    )
                }

                switch selectedPeriod {
                case .daily:
                    DailyChartView(data: displayedDailyData)
                case .weekly:
                    WeeklyChartView(data: displayedWeeklyData, metric: aggregateMetric)
                case .monthly:
                    MonthlyChartView(data: displayedMonthlyData, metric: aggregateMetric)
                }
            }
        }
        .padding()
        .task { await reloadPersistedData() }
        .onReceive(NotificationCenter.default.publisher(for: .activeTrackPersistenceDidChange)) { _ in
            Task { await reloadPersistedData() }
        }
    }

    private func reloadPersistedData() async {
        let chartData = await persistenceService.chartDataAsync(days: 14, weeks: 12, months: 12)
        persistedDailyData = chartData.daily
        persistedWeeklyData = chartData.weekly
        persistedMonthlyData = chartData.monthly
    }

    private func overlayDailyTotals(_ items: [DailyTotal]) -> [DailyTotal] {
        let runningElapsed = liveOverlayDuration
        guard runningElapsed > 0 else { return items }
        let today = Calendar.current.startOfDay(for: .now)
        if let dailyIndex = items.firstIndex(where: { $0.date == today }) {
            var updated = items
            updated[dailyIndex] = DailyTotal(date: today, duration: updated[dailyIndex].duration + runningElapsed)
            return updated
        }
        return items
    }

    private func overlayWeeklyTotals(_ items: [WeeklyTotal]) -> [WeeklyTotal] {
        let runningElapsed = liveOverlayDuration
        guard runningElapsed > 0 else { return items }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today))
        if let weekStart, let weeklyIndex = items.firstIndex(where: { $0.weekStart == weekStart }) {
            var updated = items
            updated[weeklyIndex] = WeeklyTotal(
                weekStart: weekStart,
                duration: updated[weeklyIndex].duration + runningElapsed
            )
            return updated
        }
        return items
    }

    private func overlayMonthlyTotals(_ items: [MonthlyTotal]) -> [MonthlyTotal] {
        let runningElapsed = liveOverlayDuration
        guard runningElapsed > 0 else { return items }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today))
        if let monthStart, let monthlyIndex = items.firstIndex(where: { $0.monthStart == monthStart }) {
            var updated = items
            updated[monthlyIndex] = MonthlyTotal(
                monthStart: monthStart,
                duration: updated[monthlyIndex].duration + runningElapsed
            )
            return updated
        }
        return items
    }

    private var liveOverlayDuration: TimeInterval {
        guard timerService.isRunning else { return 0 }
        return timerService.currentIntervalElapsed
    }

    private func averageDuration<T>(for items: [T]) -> TimeInterval where T: DurationReadable {
        guard !items.isEmpty else { return 0 }
        let total = items.reduce(0) { $0 + $1.duration }
        return total / Double(items.count)
    }
}

private protocol DurationReadable {
    var duration: TimeInterval { get }
}

extension DailyTotal: DurationReadable {}
extension WeeklyTotal: DurationReadable {}
extension MonthlyTotal: DurationReadable {}

private struct LiveTodayDashboardMetricCard: View {
    let timerService: TimerService

    var body: some View {
        DashboardMetricCard(
            title: "Today",
            value: timerService.displayTime.formattedHoursMinutes,
            caption: timerService.isRunning ? "Live total including current session" : "Tracked so far today"
        )
    }
}

private struct DashboardMetricCard: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(.title2, design: .rounded, weight: .semibold))

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}
