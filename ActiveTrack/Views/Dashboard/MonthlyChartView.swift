import SwiftUI
import Charts

struct MonthlyChartView: View {
    let data: [MonthlyTotal]
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

            if data.allSatisfy({ $0.duration == 0 }) {
                ContentUnavailableView {
                    Label("No Data", systemImage: "chart.bar")
                } description: {
                    Text("Start tracking time to see monthly charts.")
                }
                .frame(maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(data) { item in
                        BarMark(
                            x: .value("Month", item.monthStart, unit: .month),
                            y: .value("Hours", chartValue(for: item) / 3600)
                        )
                        .foregroundStyle(.teal.gradient)
                        .cornerRadius(4)
                    }

                    if averageChartValue > 0 {
                        RuleMark(y: .value("Average", averageChartValue / 3600))
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

    private var averageDuration: TimeInterval {
        guard !data.isEmpty else { return 0 }
        return data.reduce(0) { $0 + $1.duration } / Double(data.count)
    }

    private var averageChartValue: TimeInterval {
        guard !data.isEmpty else { return 0 }
        return data.reduce(0) { $0 + chartValue(for: $1) } / Double(data.count)
    }

    private var summaryText: String {
        switch metric {
        case .total:
            return "Average: \(averageDuration.formattedHoursMinutes) per month"
        case .averagePerDay:
            return "Average: \(averageChartValue.formattedHoursMinutes) per day within each month"
        }
    }

    private func chartValue(for item: MonthlyTotal) -> TimeInterval {
        switch metric {
        case .total:
            return item.duration
        case .averagePerDay:
            let divisor = Double(daysInDisplayedMonth(startingAt: item.monthStart))
            return divisor > 0 ? item.duration / divisor : 0
        }
    }

    private func daysInDisplayedMonth(startingAt monthStart: Date) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let currentMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!

        if monthStart == currentMonthStart {
            return max(1, calendar.component(.day, from: today))
        }

        return calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
    }
}
