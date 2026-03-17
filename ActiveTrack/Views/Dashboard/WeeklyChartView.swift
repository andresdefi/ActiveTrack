import SwiftUI
import Charts

struct WeeklyChartView: View {
    let data: [WeeklyTotal]
    let metric: AggregateChartMetric

    var body: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 4) {
                Text(metric == .total ? "Last 12 Weeks" : "Weekly Daily Average")
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
                    Text("Start tracking time to see weekly charts.")
                }
                .frame(maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(data) { item in
                        BarMark(
                            x: .value("Week", item.weekStart, unit: .weekOfYear),
                            y: .value("Hours", chartValue(for: item) / 3600)
                        )
                        .foregroundStyle(.indigo.gradient)
                        .cornerRadius(4)
                    }

                    if averageChartValue > 0 {
                        RuleMark(y: .value("Average", averageChartValue / 3600))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
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
            return "Average: \(averageDuration.formattedHoursMinutes) per week"
        case .averagePerDay:
            return "Average: \(averageChartValue.formattedHoursMinutes) per day within each week"
        }
    }

    private func chartValue(for item: WeeklyTotal) -> TimeInterval {
        switch metric {
        case .total:
            return item.duration
        case .averagePerDay:
            let divisor = Double(daysInDisplayedWeek(startingAt: item.weekStart))
            return divisor > 0 ? item.duration / divisor : 0
        }
    }

    private func daysInDisplayedWeek(startingAt weekStart: Date) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let currentWeekStart = calendar.date(
            from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
        )!

        guard weekStart == currentWeekStart else { return 7 }
        return max(1, calendar.dateComponents([.day], from: weekStart, to: today).day! + 1)
    }
}
