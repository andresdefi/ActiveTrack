import SwiftUI
import SwiftData

struct MenuBarPopoverView: View {
    @Bindable var timerService: TimerService
    let persistenceService: PersistenceService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 16) {
            TodaySummaryView(timerService: timerService)
            TimerControlsView(timerService: timerService)

            Divider()

            HStack {
                Button("Dashboard") {
                    openWindow(id: "dashboard")
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.link)

                Spacer()

                Button("Quit") {
                    timerService.pause()
                    NSApp.terminate(nil)
                }
                .buttonStyle(.link)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 260)
    }
}
