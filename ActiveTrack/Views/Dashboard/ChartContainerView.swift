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
    let displaySnapshot: DashboardDisplaySnapshot

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

                DashboardMetricsGrid(displaySnapshot: displaySnapshot)
                SelectedHistoryChart(
                    chartPresentation: displaySnapshot.chartPresentation,
                    selectedPeriod: selectedPeriod,
                    aggregateMetric: aggregateMetric
                )
            }
        }
        .padding()
    }
}

private struct DashboardMetricsGrid: View {
    let displaySnapshot: DashboardDisplaySnapshot

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            DashboardMetricCard(
                title: "Today",
                value: displaySnapshot.todayText,
                caption: displaySnapshot.todayCaption
            )
            DashboardMetricCard(
                title: "Average / Day",
                value: displaySnapshot.averageDailyText,
                caption: "Across the last 14 days"
            )
            DashboardMetricCard(
                title: "Average / Week",
                value: displaySnapshot.averageWeeklyText,
                caption: "Across the last 12 weeks"
            )
            DashboardMetricCard(
                title: "Average / Month",
                value: displaySnapshot.averageMonthlyText,
                caption: "Across the last 12 months"
            )
        }
    }
}

private struct SelectedHistoryChart: View {
    let chartPresentation: DashboardChartPresentation
    let selectedPeriod: ChartPeriod
    let aggregateMetric: AggregateChartMetric

    var body: some View {
        switch selectedPeriod {
        case .daily:
            DailyChartView(presentation: chartPresentation.daily)
        case .weekly:
            WeeklyChartView(
                presentation: chartPresentation.weekly,
                metric: aggregateMetric
            )
        case .monthly:
            MonthlyChartView(
                presentation: chartPresentation.monthly,
                metric: aggregateMetric
            )
        }
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
