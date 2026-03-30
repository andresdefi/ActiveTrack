import SwiftUI
import SwiftData

struct MenuBarPopoverView: View {
    let timerService: TimerService
    let persistenceService: PersistenceService
    @Environment(\.openWindow) private var openWindow
    @AppStorage("lastSeenReleaseNotesVersion") private var lastSeenReleaseNotesVersion = ""
    @State private var showingWhatsNew = false
    private let currentReleaseNotesVersion = "1.2.6"

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
                TargetTimerView(timerService: timerService)

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
            Text("• Reused a persistent writable SQLite connection so start and pause writes avoid repeated open-and-schema work")
            Text("• Stopped the day detail screen from reloading storage every minute while a session is running")
            Text("• Kept dashboard sidebar totals and chart cards live without copying full history on each display refresh")
            Text("• Preserved stable interval identities so the detail list updates without unnecessary row churn")
            Text("• Added regression coverage for live interval overlays and day-summary reads")
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

private struct TargetTimerView: View {
    let timerService: TimerService

    @AppStorage("targetTimerDraftHours") private var draftHours = 6
    @AppStorage("targetTimerDraftMinutes") private var draftMinutes = 0
    @AppStorage("targetTimerDraftMode") private var draftModeRaw = TimerTargetMode.todayTotal.rawValue

    private let minuteOptions = Array(stride(from: 0, through: 55, by: 5))

    private var selectedDuration: TimeInterval {
        TimeInterval((draftHours * 3600) + (draftMinutes * 60))
    }

    private var selectedMode: Binding<TimerTargetMode> {
        Binding(
            get: { TimerTargetMode(rawValue: draftModeRaw) ?? .todayTotal },
            set: { draftModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Target")
                    .font(.headline)

                Spacer()

                if timerService.hasReachedTarget {
                    statusPill(title: "Reached", color: .orange)
                } else if timerService.isTargetActive {
                    statusPill(title: "Active", color: .blue)
                }
            }

            if timerService.hasReachedTarget {
                reachedCard
            } else if timerService.isTargetActive {
                activeCard
            }

            Picker("Count From", selection: selectedMode) {
                ForEach(TimerTargetMode.allCases) { mode in
                    Text(mode.title)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                Picker("Hours", selection: $draftHours) {
                    ForEach(0..<25, id: \.self) { hour in
                        Text("\(hour)h")
                            .tag(hour)
                    }
                }

                Picker("Minutes", selection: $draftMinutes) {
                    ForEach(minuteOptions, id: \.self) { minutes in
                        Text("\(minutes)m")
                            .tag(minutes)
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            HStack {
                Button(timerService.isTargetActive ? "Update Target" : "Set Target") {
                    timerService.setTarget(duration: selectedDuration, mode: selectedMode.wrappedValue)
                }
                .disabled(selectedDuration <= 0)

                Spacer()

                if timerService.hasReachedTarget {
                    Button("Dismiss") {
                        timerService.dismissReachedTarget()
                    }
                    .buttonStyle(.borderless)
                } else if timerService.isTargetActive {
                    Button("Clear") {
                        timerService.clearTarget()
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            syncDraftWithTargetIfNeeded()
        }
        .onChange(of: timerService.targetDuration) {
            syncDraftWithTargetIfNeeded()
        }
    }

    private var activeCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let targetDuration = timerService.targetDuration {
                Text("Tracking \(targetDuration.formattedHoursMinutes) \(timerService.targetMode.summaryText)")
                    .font(.subheadline.weight(.semibold))
                if let remainingTargetTime = timerService.remainingTargetTime {
                    Text("Remaining: \(remainingTargetTime.formattedHoursMinutes)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var reachedCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Time reached")
                .font(.subheadline.weight(.semibold))
            if let reachedTargetDuration = timerService.reachedTargetDuration,
               let reachedTargetMode = timerService.reachedTargetMode {
                Text("Paused at \(reachedTargetDuration.formattedHoursMinutes) \(reachedTargetMode.summaryText). Press Start to keep tracking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("The timer is paused. Press Start to keep tracking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func statusPill(title: String, color: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func syncDraftWithTargetIfNeeded() {
        guard let targetDuration = timerService.targetDuration else { return }
        draftModeRaw = timerService.targetMode.rawValue
        let totalMinutes = Int(targetDuration / 60)
        draftHours = min(totalMinutes / 60, 24)
        draftMinutes = minuteOptions.min(by: { abs($0 - (totalMinutes % 60)) < abs($1 - (totalMinutes % 60)) }) ?? 0
    }
}
