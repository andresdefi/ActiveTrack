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
    let historyStore: DashboardHistoryStore

    @State private var selectedPeriod: ChartPeriod = .daily
    @State private var aggregateMetric: AggregateChartMetric = .total

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

                DashboardMetricsGrid(timerService: timerService, chartData: historyStore.chartData)
                SelectedHistoryChart(
                    timerService: timerService,
                    chartData: historyStore.chartData,
                    selectedPeriod: selectedPeriod,
                    aggregateMetric: aggregateMetric
                )
            }
        }
        .padding()
    }
}

private struct DashboardMetricsGrid: View {
    let timerService: TimerService
    let chartData: HistoryChartData

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            LiveTodayDashboardMetricCard(timerService: timerService)
            DashboardMetricCard(
                title: "Average / Day",
                value: HistoryChartOverlay.averageDuration(for: displayedDailyData).formattedHoursMinutes,
                caption: "Across the last 14 days"
            )
            DashboardMetricCard(
                title: "Average / Week",
                value: HistoryChartOverlay.averageDuration(for: displayedWeeklyData).formattedHoursMinutes,
                caption: "Across the last 12 weeks"
            )
            DashboardMetricCard(
                title: "Average / Month",
                value: HistoryChartOverlay.averageDuration(for: displayedMonthlyData).formattedHoursMinutes,
                caption: "Across the last 12 months"
            )
        }
    }

    private var displayedDailyData: [DailyTotal] {
        HistoryChartOverlay.overlayDailyTotals(chartData.daily, timerService: timerService)
    }

    private var displayedWeeklyData: [WeeklyTotal] {
        HistoryChartOverlay.overlayWeeklyTotals(chartData.weekly, timerService: timerService)
    }

    private var displayedMonthlyData: [MonthlyTotal] {
        HistoryChartOverlay.overlayMonthlyTotals(chartData.monthly, timerService: timerService)
    }
}

private struct SelectedHistoryChart: View {
    let timerService: TimerService
    let chartData: HistoryChartData
    let selectedPeriod: ChartPeriod
    let aggregateMetric: AggregateChartMetric

    var body: some View {
        switch selectedPeriod {
        case .daily:
            DailyChartView(data: HistoryChartOverlay.overlayDailyTotals(chartData.daily, timerService: timerService))
        case .weekly:
            WeeklyChartView(
                data: HistoryChartOverlay.overlayWeeklyTotals(chartData.weekly, timerService: timerService),
                metric: aggregateMetric
            )
        case .monthly:
            MonthlyChartView(
                data: HistoryChartOverlay.overlayMonthlyTotals(chartData.monthly, timerService: timerService),
                metric: aggregateMetric
            )
        }
    }
}

@MainActor
private enum HistoryChartOverlay {
    static func overlayDailyTotals(_ items: [DailyTotal], timerService: TimerService) -> [DailyTotal] {
        let runningElapsed = liveOverlayDuration(timerService: timerService)
        guard runningElapsed > 0 else { return items }
        let today = Calendar.current.startOfDay(for: .now)
        if let dailyIndex = items.firstIndex(where: { $0.date == today }) {
            var updated = items
            updated[dailyIndex] = DailyTotal(date: today, duration: updated[dailyIndex].duration + runningElapsed)
            return updated
        }
        return items
    }

    static func overlayWeeklyTotals(_ items: [WeeklyTotal], timerService: TimerService) -> [WeeklyTotal] {
        let runningElapsed = liveOverlayDuration(timerService: timerService)
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

    static func overlayMonthlyTotals(_ items: [MonthlyTotal], timerService: TimerService) -> [MonthlyTotal] {
        let runningElapsed = liveOverlayDuration(timerService: timerService)
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

    static func averageDuration<T>(for items: [T]) -> TimeInterval where T: DurationReadable {
        guard !items.isEmpty else { return 0 }
        let total = items.reduce(0) { $0 + $1.duration }
        return total / Double(items.count)
    }

    private static func liveOverlayDuration(timerService: TimerService) -> TimeInterval {
        guard timerService.isRunning else { return 0 }
        return timerService.currentIntervalElapsed
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
