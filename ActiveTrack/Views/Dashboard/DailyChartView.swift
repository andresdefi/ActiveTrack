import SwiftUI
import Charts

struct DailyChartView: View {
    let persistenceService: PersistenceService
    @State private var data: [DailyTotal] = []

    var body: some View {
        VStack(alignment: .leading) {
            Text("Last 14 Days")
                .font(.headline)
                .padding(.bottom, 4)

            if data.allSatisfy({ $0.duration == 0 }) {
                ContentUnavailableView {
                    Label("No Data", systemImage: "chart.bar")
                } description: {
                    Text("Start tracking time to see daily charts.")
                }
                .frame(maxHeight: .infinity)
            } else {
                Chart(data) { item in
                    BarMark(
                        x: .value("Day", item.date, unit: .day),
                        y: .value("Hours", item.duration / 3600)
                    )
                    .foregroundStyle(.blue.gradient)
                    .cornerRadius(4)
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
                .frame(maxHeight: .infinity)
            }
        }
        .onAppear { refreshData() }
    }

    private func refreshData() {
        data = persistenceService.dailyTotals(days: 14)
    }
}
