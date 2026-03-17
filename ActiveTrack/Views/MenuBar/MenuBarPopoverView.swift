import SwiftUI
import SwiftData

struct MenuBarPopoverView: View {
    let timerService: TimerService
    let persistenceService: PersistenceService
    @Environment(\.openWindow) private var openWindow
    @AppStorage("lastSeenReleaseNotesVersion") private var lastSeenReleaseNotesVersion = ""
    @State private var showingWhatsNew = false
    private let currentReleaseNotesVersion = "1.2.2"

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 16) {
                if let startupWarning = persistenceService.startupWarning {
                    HStack(spacing: 8) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .foregroundStyle(.yellow)
                        Text(startupWarning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        Spacer()
                    }
                    .padding(8)
                    .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }

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
                        NotificationCenter.default.post(name: .activeTrackShowDashboardOverview, object: nil)
                        HealthLog.event("dashboard_open")
                    }
                    .buttonStyle(.link)

                    Spacer()

                    Button {
                        showingWhatsNew = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("What's New")
                            if lastSeenReleaseNotesVersion != currentReleaseNotesVersion {
                                Circle()
                                    .fill(.blue)
                                    .frame(width: 6, height: 6)
                            }
                        }
                    }
                    .buttonStyle(.link)
                }

                HStack {
                    Button("Reset Today") {
                        timerService.resetToday()
                        HealthLog.event("reset_today_tapped")
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(.orange)

                    Spacer()

                    Button("Quit") {
                        timerService.pause()
                        HealthLog.event("app_quit")
                        NSApp.terminate(nil)
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showingWhatsNew) {
            whatsNewSheet
        }
        .onAppear {
            if lastSeenReleaseNotesVersion.isEmpty {
                HealthLog.event("release_notes_available", metadata: ["version": currentReleaseNotesVersion])
            }
        }
    }

    private func errorMessage(_ error: PersistenceError) -> String {
        switch error {
        case .saveFailed(let underlying):
            return "Save failed: \(underlying)"
        }
    }

    private var whatsNewSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's New in \(currentReleaseNotesVersion)")
                .font(.title3.bold())
            Text("• Added dashboard summary cards and richer daily, weekly, and monthly charts")
            Text("• Added total vs average-per-day chart views for weekly and monthly trends")
            Text("• Grouped history sidebar by month with overview navigation")
            Text("• Improved dashboard and menu bar layout behavior")
            Text("• Hardened persistence reads and crash recovery handling")
            HStack {
                Spacer()
                Button("Done") {
                    lastSeenReleaseNotesVersion = currentReleaseNotesVersion
                    showingWhatsNew = false
                    HealthLog.event("release_notes_seen", metadata: ["version": currentReleaseNotesVersion])
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}
