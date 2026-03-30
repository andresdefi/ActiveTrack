import SwiftUI

struct TodaySummaryView: View {
    let timerService: TimerService

    var body: some View {
        VStack(spacing: 4) {
            Text("Today")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(timerService.displayTime.formattedHoursMinutes)
                .font(.system(.title, design: .monospaced, weight: .medium))
                .contentTransition(.numericText())

            if timerService.isRunning {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Text("Running")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
