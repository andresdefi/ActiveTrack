import SwiftUI

struct UITestHarnessView: View {
    let timerService: TimerService
    let persistenceService: PersistenceService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("UI Smoke Tests")
                .font(.title2.bold())
                .accessibilityIdentifier("activeTrack.uiSmokeTitle")

            TodaySummaryView(displaySnapshot: timerService.displaySnapshot)
            TimerControlsView(timerService: timerService)
            TargetTimerView(targetSnapshot: timerService.targetSnapshot, timerService: timerService)

            Divider()

            Text("This window exists only for launch-argument-driven UI smoke tests.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 320)
    }
}
