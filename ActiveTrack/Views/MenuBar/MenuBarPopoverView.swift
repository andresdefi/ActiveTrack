import SwiftUI
import SwiftData

struct MenuBarPopoverView: View {
    let timerService: TimerService
    let persistenceService: PersistenceService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 16) {
            if let error = timerService.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(errorMessage(error))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Retry") {
                        timerService.toggle()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(8)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }

            TodaySummaryView(timerService: timerService)
            TimerControlsView(timerService: timerService)

            Divider()

            HStack {
                Button("Dashboard") {
                    openWindow(id: "dashboard")
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

    private func errorMessage(_ error: PersistenceError) -> String {
        switch error {
        case .saveFailed(let underlying):
            return "Save failed: \(underlying)"
        }
    }
}
