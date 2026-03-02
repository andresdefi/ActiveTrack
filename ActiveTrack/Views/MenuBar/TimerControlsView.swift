import SwiftUI

struct TimerControlsView: View {
    @Bindable var timerService: TimerService

    var body: some View {
        Button(action: { timerService.toggle() }) {
            HStack {
                Image(systemName: timerService.isRunning ? "pause.fill" : "play.fill")
                Text(timerService.isRunning ? "Pause" : "Start")
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(timerService.isRunning ? .orange : .green)
    }
}
