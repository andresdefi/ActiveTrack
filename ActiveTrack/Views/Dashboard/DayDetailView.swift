import SwiftUI

struct DayDetailView: View {
    let day: Date
    let persistenceService: PersistenceService

    var body: some View {
        let intervals = persistenceService.intervalsForDay(day)
        let total = persistenceService.durationForDay(day)

        VStack(alignment: .leading, spacing: 16) {
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
    }
}
