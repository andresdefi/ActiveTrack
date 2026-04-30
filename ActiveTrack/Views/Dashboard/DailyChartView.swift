import SwiftUI
import Charts

struct DailyChartView: View {
    let presentation: DailyChartPresentation

    var body: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Last 14 Days")
                    .font(.headline)
                Text(presentation.summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)

            if !presentation.hasData {
                ContentUnavailableView {
                    Label("No Data", systemImage: "chart.bar")
                } description: {
                    Text("Start tracking time to see daily charts.")
                }
                .frame(maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(presentation.points) { item in
                        BarMark(
                            x: .value("Day", item.date, unit: .day),
                            y: .value("Hours", item.hours)
                        )
                        .foregroundStyle(.blue.gradient)
                        .cornerRadius(4)
                    }

                    if presentation.averageHours > 0 {
                        RuleMark(y: .value("Average", presentation.averageHours))
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
}
