import SwiftUI
import Charts

struct DailyChartView: View {
    let data: [DailyTotal]

    var body: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Last 14 Days")
                    .font(.headline)
                Text("Average: \(averageDuration.formattedHoursMinutes) per day")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)

            if data.allSatisfy({ $0.duration == 0 }) {
                ContentUnavailableView {
                    Label("No Data", systemImage: "chart.bar")
                } description: {
                    Text("Start tracking time to see daily charts.")
                }
                .frame(maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(data) { item in
                        BarMark(
                            x: .value("Day", item.date, unit: .day),
                            y: .value("Hours", item.duration / 3600)
                        )
                        .foregroundStyle(.blue.gradient)
                        .cornerRadius(4)
                    }

                    if averageDuration > 0 {
                        RuleMark(y: .value("Average", averageDuration / 3600))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 2)) { value in
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
}
