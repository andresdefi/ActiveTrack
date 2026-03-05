import SwiftUI
import Charts

struct WeeklyChartView: View {
    let timerService: TimerService
    let persistenceService: PersistenceService
    @State private var data: [WeeklyTotal] = []

    var body: some View {
        VStack(alignment: .leading) {
            Text("Last 12 Weeks")
                .font(.headline)
                .padding(.bottom, 4)

            if data.allSatisfy({ $0.duration == 0 }) {
                ContentUnavailableView {
                    Label("No Data", systemImage: "chart.bar")
                } description: {
                    Text("Start tracking time to see weekly charts.")
                }
                .frame(maxHeight: .infinity)
            } else {
                Chart(data) { item in
                    BarMark(
                        x: .value("Week", item.weekStart, unit: .weekOfYear),
                        y: .value("Hours", item.duration / 3600)
                    )
                    .foregroundStyle(.indigo.gradient)
                    .cornerRadius(4)
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
                .frame(maxHeight: .infinity)
            }
        }
        .onAppear { refreshData() }
        .onChange(of: timerService.isRunning) { refreshData() }
    }

    private func refreshData() {
        data = persistenceService.weeklyTotals(weeks: 12)
    }
}
