import SwiftUI

struct DayDetailView: View {
    let day: Date
    let timerService: TimerService
    let persistenceService: PersistenceService

    @State private var intervals: [(start: Date, end: Date, duration: TimeInterval)] = []
    @State private var total: TimeInterval = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LiveDayHeader(day: day, total: total)
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
        .task(id: day) { await refreshData() }
        .onChange(of: timerService.isRunning) {
            guard Calendar.current.isDateInToday(day) else { return }
            Task { await refreshData() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeTrackDisplayTimeChanged)) { _ in
            guard timerService.isRunning, Calendar.current.isDateInToday(day) else { return }
            Task { await refreshData() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeTrackPersistenceDidChange)) { _ in
            Task { await refreshData() }
        }
    }

    private func refreshData() async {
        let dayIntervals = await persistenceService.intervalsForDayAsync(day)
        intervals = dayIntervals
        total = dayIntervals.reduce(0) { $0 + $1.duration }
    }
}

private struct LiveDayHeader: View {
    let day: Date
    let total: TimeInterval

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(day.shortDateString)
                    .font(.title2.bold())
                Text("Total: \(total.formattedHoursMinutes)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
