import SwiftUI

struct DayDetailView: View {
    let day: Date
    let timerService: TimerService
    let persistenceService: PersistenceService

    @State private var intervals: [(start: Date, end: Date, duration: TimeInterval)] = []
    @State private var total: TimeInterval = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LiveDayHeader(day: day, total: total, timerService: timerService)
                .padding(.bottom, 8)

            if intervals.isEmpty {
                ContentUnavailableView {
                    Label("No Intervals", systemImage: "clock")
                } description: {
                    Text("No tracked time for this day.")
                }
            } else {
                List {
                    ForEach(Array(intervals.enumerated()), id: \.offset) { _, interval in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(interval.start.timeString) – \(interval.end.timeString)")
                                    .font(.body)
                            }
                            Spacer()
                            Text(interval.duration.formattedHoursMinutes)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding()
        .onAppear { refreshData() }
        .onChange(of: day) { refreshData() }
        .onChange(of: timerService.isRunning) { refreshData() }
    }

    private func refreshData() {
        let dayIntervals = persistenceService.intervalsForDay(day)
        intervals = dayIntervals
        total = dayIntervals.reduce(0) { $0 + $1.duration }
    }
}

private struct LiveDayHeader: View {
    let day: Date
    let total: TimeInterval
    let timerService: TimerService

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(day.shortDateString)
                    .font(.title2.bold())
                Text("Total: \(displayTotal.formattedHoursMinutes)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var displayTotal: TimeInterval {
        if timerService.isRunning && Calendar.current.isDateInToday(day) {
            return total + timerService.currentIntervalElapsed
        }
        return total
    }
}
