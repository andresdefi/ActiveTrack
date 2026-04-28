import SwiftUI

struct TodaySummaryView: View {
    let displaySnapshot: TimerDisplaySnapshot

    var body: some View {
        VStack(spacing: 4) {
            Text("Today")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(displaySnapshot.fullText)
                .font(.system(.title, design: .monospaced, weight: .medium))
                .contentTransition(.numericText())
                .accessibilityIdentifier("activeTrack.todayTotalText")

            if displaySnapshot.isRunning {
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
