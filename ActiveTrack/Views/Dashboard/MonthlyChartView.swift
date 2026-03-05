import SwiftUI
import Charts

struct MonthlyChartView: View {
    let timerService: TimerService
    let persistenceService: PersistenceService
    @State private var data: [MonthlyTotal] = []

    var body: some View {
        VStack(alignment: .leading) {
            Text("Last 12 Months")
                .font(.headline)
                .padding(.bottom, 4)

            if data.allSatisfy({ $0.duration == 0 }) {
                ContentUnavailableView {
                    Label("No Data", systemImage: "chart.bar")
                } description: {
                    Text("Start tracking time to see monthly charts.")
                }
                .frame(maxHeight: .infinity)
            } else {
                Chart(data) { item in
                    BarMark(
                        x: .value("Month", item.monthStart, unit: .month),
                        y: .value("Hours", item.duration / 3600)
                    )
                    .foregroundStyle(.teal.gradient)
                    .cornerRadius(4)
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
                .frame(maxHeight: .infinity)
            }
        }
        .onAppear { refreshData() }
        .onChange(of: timerService.isRunning) { refreshData() }
    }

    private func refreshData() {
        data = persistenceService.monthlyTotals(months: 12)
    }
}
