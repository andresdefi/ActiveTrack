import SwiftUI

enum ChartPeriod: String, CaseIterable {
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"
}

struct ChartContainerView: View {
    let timerService: TimerService
    let persistenceService: PersistenceService
    @State private var selectedPeriod: ChartPeriod = .daily

    var body: some View {
        VStack(spacing: 16) {
            Picker("Period", selection: $selectedPeriod) {
                ForEach(ChartPeriod.allCases, id: \.self) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            switch selectedPeriod {
            case .daily:
                DailyChartView(timerService: timerService, persistenceService: persistenceService)
            case .weekly:
                WeeklyChartView(timerService: timerService, persistenceService: persistenceService)
            case .monthly:
                MonthlyChartView(timerService: timerService, persistenceService: persistenceService)
            }
        }
        .padding()
    }
}
