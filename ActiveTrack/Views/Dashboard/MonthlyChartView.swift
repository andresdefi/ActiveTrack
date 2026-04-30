import SwiftUI
import Charts

struct MonthlyChartView: View {
    let presentation: AggregateChartPresentation<MonthlyChartPoint>
    let metric: AggregateChartMetric

    var body: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 4) {
                Text(metric == .total ? "Last 12 Months" : "Monthly Daily Average")
                    .font(.headline)
                Text(summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)

            if !presentation.hasData {
                ContentUnavailableView {
                    Label("No Data", systemImage: "chart.bar")
                } description: {
                    Text("Start tracking time to see monthly charts.")
                }
                .frame(maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(presentation.points) { item in
                        BarMark(
                            x: .value("Month", item.monthStart, unit: .month),
                            y: .value("Hours", chartValue(for: item))
                        )
                        .foregroundStyle(.teal.gradient)
                        .cornerRadius(4)
                    }

                    if averageChartValue > 0 {
                        RuleMark(y: .value("Average", averageChartValue))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month, count: 2)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true)
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let hours = value.as(Double.self) {
                                Text("\(hours, specifier: "%.1f")h")
                            }
                        }
                    }
                }
                .frame(height: 320)
            }
        }
    }

    private var summaryText: String {
        switch metric {
        case .total:
            return presentation.totalSummaryText
        case .averagePerDay:
            return presentation.averagePerDaySummaryText
        }
    }

    private var averageChartValue: Double {
        switch metric {
        case .total:
            return presentation.totalAverageHours
        case .averagePerDay:
            return presentation.averagePerDayAverageHours
        }
    }

    private func chartValue(for item: MonthlyChartPoint) -> Double {
        switch metric {
        case .total:
            return item.totalHours
        case .averagePerDay:
            return item.averagePerDayHours
        }
    }
}
