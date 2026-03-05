import SwiftUI
import SwiftData

struct DashboardView: View {
    let timerService: TimerService
    let persistenceService: PersistenceService
    @State private var selectedDay: Date?
    @State private var days: [Date] = []

    var body: some View {
        if timerService.isDashboardSafeMode {
            VStack(alignment: .leading, spacing: 12) {
                Text("Dashboard (Safe Mode)")
                    .font(.title2.bold())
                Text("History charts are temporarily disabled to keep ActiveTrack stable.")
                    .foregroundStyle(.secondary)
                Text("Timer persistence is active, and tracking continues from the menu bar.")
                    .foregroundStyle(.secondary)
                Text("Current session: \(timerService.displayTime.formattedHoursMinutesSeconds)")
                    .font(.system(.title3, design: .monospaced, weight: .medium))
                    .padding(.top, 6)
                Spacer()
            }
            .padding(24)
            .navigationTitle("ActiveTrack")
        } else {
        NavigationSplitView {
            sidebar
        } detail: {
            if let day = selectedDay {
                DayDetailView(day: day, timerService: timerService, persistenceService: persistenceService)
            } else {
                ChartContainerView(timerService: timerService, persistenceService: persistenceService)
            }
        }
        .navigationTitle("ActiveTrack")
        .onAppear {
            refreshDays()
        }
        .onChange(of: timerService.isRunning) {
            refreshDays()
        }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedDay) {
            if days.isEmpty {
                ContentUnavailableView {
                    Label("No Data Yet", systemImage: "clock")
                } description: {
                    Text("Start the timer from the menu bar to begin tracking.")
                }
            } else {
                ForEach(days, id: \.self) { day in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(day.shortDateString)
                                .font(.headline)
                            if Calendar.current.isDateInToday(day) {
                                Text("Today")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(durationForDay(day).formattedHoursMinutes)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .tag(day)
                    .padding(.vertical, 2)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220)
    }

    private func refreshDays() {
        days = persistenceService.daysWithData()
    }

    private func durationForDay(_ day: Date) -> TimeInterval {
        let total = persistenceService.durationForDay(day)
        if timerService.isRunning && Calendar.current.isDateInToday(day) {
            return total + timerService.currentIntervalElapsed
        }
        return total
    }
}
