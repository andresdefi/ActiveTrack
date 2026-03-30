import SwiftUI

struct DayDetailView: View {
    let day: Date
    let timerService: TimerService
    let persistenceService: PersistenceService

    @State private var persistedIntervals: [DayIntervalSummary] = []

    private var displayedIntervals: [DayIntervalSummary] {
        var intervals = persistedIntervals.filter { !$0.isOpen }
        if let liveInterval = timerService.liveIntervalForDay(day) {
            intervals.append(liveInterval)
        }
        return intervals.sorted { $0.start < $1.start }
    }

    private var displayedTotal: TimeInterval {
        displayedIntervals.reduce(0) { $0 + $1.duration }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LiveDayHeader(day: day, total: displayedTotal)
                .padding(.bottom, 8)

            if displayedIntervals.isEmpty {
                ContentUnavailableView {
                    Label("No Intervals", systemImage: "clock")
                } description: {
                    Text("No tracked time for this day.")
                }
            } else {
                List {
                    ForEach(displayedIntervals) { interval in
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
        .task(id: day) { await refreshPersistedData() }
        .onReceive(NotificationCenter.default.publisher(for: .activeTrackPersistenceDidChange)) { _ in
            Task { await refreshPersistedData() }
        }
    }

    private func refreshPersistedData() async {
        persistedIntervals = await persistenceService.intervalSummariesForDayAsync(day)
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
