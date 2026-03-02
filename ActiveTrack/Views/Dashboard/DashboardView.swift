import SwiftUI
import SwiftData

struct DashboardView: View {
    @Bindable var timerService: TimerService
    let persistenceService: PersistenceService
    @State private var selectedDay: Date?
    @State private var days: [Date] = []

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let day = selectedDay {
                DayDetailView(day: day, persistenceService: persistenceService)
            } else {
                ChartContainerView(persistenceService: persistenceService)
            }
        }
        .navigationTitle("ActiveTrack")
        .onAppear {
            refreshDays()
        }
        .onChange(of: timerService.isRunning) {
            refreshDays()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow, window.title == "ActiveTrack" || window.identifier?.rawValue == "dashboard" {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedDay) {
            if days.isEmpty {
                ContentUnavailableView {
                    Label("No Data Yet", systemImage: "clock")
                } description: {
                    Text("Start the timer from the menu bar to begin tracking.")
                }
            } else {
                ForEach(days, id: \.self) { day in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(day.shortDateString)
                                .font(.headline)
                            if Calendar.current.isDateInToday(day) {
                                Text("Today")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(durationForDay(day).formattedHoursMinutes)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .tag(day)
                    .padding(.vertical, 2)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220)
    }

    private func refreshDays() {
        days = persistenceService.daysWithData()
    }

    private func durationForDay(_ day: Date) -> TimeInterval {
        var total = persistenceService.durationForDay(day)
        if timerService.isRunning && Calendar.current.isDateInToday(day) {
            total = timerService.displayTime
        }
        return total
    }
}
