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
    @State private var dailyData: [DailyTotal] = []
    @State private var weeklyData: [WeeklyTotal] = []
    @State private var monthlyData: [MonthlyTotal] = []

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
                    DashboardMetricCard(
                        title: "Today",
                        value: timerService.displayTime.formattedHoursMinutes,
                        caption: timerService.isRunning ? "Live total including current session" : "Tracked so far today"
                    )
                    DashboardMetricCard(
                        title: "Average / Day",
                        value: averageDuration(for: dailyData).formattedHoursMinutes,
                        caption: "Across the last 14 days"
                    )
                    DashboardMetricCard(
                        title: "Average / Week",
                        value: averageDuration(for: weeklyData).formattedHoursMinutes,
                        caption: "Across the last 12 weeks"
                    )
                    DashboardMetricCard(
                        title: "Average / Month",
                        value: averageDuration(for: monthlyData).formattedHoursMinutes,
                        caption: "Across the last 12 months"
                    )
                }

                switch selectedPeriod {
                case .daily:
                    DailyChartView(data: dailyData)
                case .weekly:
                    WeeklyChartView(data: weeklyData, metric: aggregateMetric)
                case .monthly:
                    MonthlyChartView(data: monthlyData, metric: aggregateMetric)
                }
            }
        }
        .padding()
        .onAppear { refreshData() }
        .onChange(of: timerService.isRunning) { refreshData() }
    }

    private func refreshData() {
        dailyData = persistenceService.dailyTotals(days: 14)
        weeklyData = persistenceService.weeklyTotals(weeks: 12)
        monthlyData = persistenceService.monthlyTotals(months: 12)
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
