import SwiftUI

struct DayDetailIntervalRow: Identifiable, Sendable, Hashable {
    let interval: DayIntervalSummary
    let timeRangeText: String
    let durationText: String

    var id: String { interval.id }
}

struct DayDetailDisplaySnapshot: Sendable, Hashable {
    static func empty(day: Date, timeDisplayPreference: TimeDisplayPreference) -> DayDetailDisplaySnapshot {
        DayDetailDisplaySnapshot(
            day: day,
            intervals: [],
            timeDisplayPreference: timeDisplayPreference
        )
    }

    let day: Date
    let titleText: String
    let total: TimeInterval
    let totalText: String
    let rows: [DayDetailIntervalRow]

    var isEmpty: Bool {
        rows.isEmpty
    }

    init(
        day: Date,
        intervals: [DayIntervalSummary],
        timeDisplayPreference: TimeDisplayPreference
    ) {
        self.day = day
        self.titleText = day.shortDateString
        self.total = intervals.reduce(0) { $0 + $1.duration }
        self.totalText = total.formattedHoursMinutes
        self.rows = intervals.map { interval in
            DayDetailIntervalRow(
                interval: interval,
                timeRangeText: "\(interval.start.timeString(using: timeDisplayPreference)) – \(interval.end.timeString(using: timeDisplayPreference))",
                durationText: interval.duration.formattedHoursMinutes
            )
        }
    }
}

@MainActor
@Observable
final class DayDetailStore {
    private let persistenceService: PersistenceService
    private(set) var snapshot: DayDetailDisplaySnapshot
    private var day: Date
    private var persistedIntervals: [DayIntervalSummary] = []
    private var liveInterval: DayIntervalSummary?
    private var timeDisplayPreference: TimeDisplayPreference

    init(day: Date, persistenceService: PersistenceService, timeDisplayPreference: TimeDisplayPreference) {
        self.day = day
        self.persistenceService = persistenceService
        self.timeDisplayPreference = timeDisplayPreference
        self.snapshot = DayDetailDisplaySnapshot.empty(
            day: day,
            timeDisplayPreference: timeDisplayPreference
        )
    }

    func reload(day: Date, timeDisplayPreference: TimeDisplayPreference) async {
        updateInputs(day: day, timeDisplayPreference: timeDisplayPreference)
        persistedIntervals = (await persistenceService.intervalSummariesForDayAsync(day))
            .filter { !$0.isOpen }
        rebuildSnapshot()
    }

    func updateLiveInterval(
        _ interval: DayIntervalSummary?,
        day: Date,
        timeDisplayPreference: TimeDisplayPreference
    ) {
        updateInputs(day: day, timeDisplayPreference: timeDisplayPreference)
        liveInterval = interval
        rebuildSnapshot()
    }

    func updateTimeDisplayPreference(_ preference: TimeDisplayPreference) {
        guard preference != timeDisplayPreference else { return }
        timeDisplayPreference = preference
        rebuildSnapshot()
    }

    private func updateInputs(day: Date, timeDisplayPreference: TimeDisplayPreference) {
        guard day != self.day else {
            self.timeDisplayPreference = timeDisplayPreference
            return
        }

        self.day = day
        self.timeDisplayPreference = timeDisplayPreference
        persistedIntervals = []
        liveInterval = nil
        rebuildSnapshot()
    }

    private func rebuildSnapshot() {
        var intervals = persistedIntervals
        if let liveInterval {
            intervals.append(liveInterval)
        }

        snapshot = DayDetailDisplaySnapshot(
            day: day,
            intervals: intervals,
            timeDisplayPreference: timeDisplayPreference
        )
    }
}

struct DayDetailView: View {
    let day: Date
    let timerService: TimerService
    let persistenceService: PersistenceService

    @State private var dayStore: DayDetailStore
    @State private var intervalPendingEdit: DayIntervalSummary?
    @State private var intervalPendingDeletion: DayIntervalSummary?
    @State private var deletingIntervalID: String?
    @State private var deletionErrorMessage: String?
    @AppStorage(AppPreferenceKey.timeDisplayPreference) private var timeDisplayPreferenceRaw = TimeDisplayPreference.system.rawValue

    init(day: Date, timerService: TimerService, persistenceService: PersistenceService) {
        self.day = day
        self.timerService = timerService
        self.persistenceService = persistenceService
        let timeDisplayPreference = AppPreferences.timeDisplayPreference()
        _dayStore = State(
            initialValue: DayDetailStore(
                day: day,
                persistenceService: persistenceService,
                timeDisplayPreference: timeDisplayPreference
            )
        )
    }

    private var timeDisplayPreference: TimeDisplayPreference {
        TimeDisplayPreference(rawValue: timeDisplayPreferenceRaw) ?? .system
    }

    private var displaySnapshot: DayDetailDisplaySnapshot {
        guard Calendar.current.isDate(dayStore.snapshot.day, inSameDayAs: day) else {
            return .empty(day: day, timeDisplayPreference: timeDisplayPreference)
        }
        return dayStore.snapshot
    }

    var body: some View {
        let snapshot = displaySnapshot

        VStack(alignment: .leading, spacing: 16) {
            LiveDayHeader(title: snapshot.titleText, totalText: snapshot.totalText)
                .padding(.bottom, 8)

            if snapshot.isEmpty {
                ContentUnavailableView {
                    Label("No Intervals", systemImage: "clock")
                } description: {
                    Text("No tracked time for this day.")
                }
            } else {
                List {
                    ForEach(snapshot.rows) { row in
                        let interval = row.interval

                        HStack {
                            VStack(alignment: .leading) {
                                Text(row.timeRangeText)
                                    .font(.body)
                            }
                            Spacer()
                            Text(row.durationText)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if deletingIntervalID == interval.id {
                                ProgressView()
                                    .controlSize(.small)
                            } else if !interval.isOpen {
                                Button {
                                    intervalPendingEdit = interval
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .help("Edit interval")
                                .disabled(isDeleting)

                                Button(role: .destructive) {
                                    intervalPendingDeletion = interval
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Delete interval")
                                .disabled(isDeleting)
                            }
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            if !interval.isOpen {
                                Button("Edit Interval", systemImage: "pencil") {
                                    intervalPendingEdit = interval
                                }
                                .disabled(isDeleting)

                                Button("Delete Interval", systemImage: "trash", role: .destructive) {
                                    intervalPendingDeletion = interval
                                }
                                .disabled(isDeleting)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !interval.isOpen {
                                Button {
                                    intervalPendingEdit = interval
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                                .disabled(isDeleting)

                                Button(role: .destructive) {
                                    intervalPendingDeletion = interval
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .disabled(isDeleting)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .task(id: day) {
            await dayStore.reload(day: day, timeDisplayPreference: timeDisplayPreference)
            dayStore.updateLiveInterval(
                liveIntervalForDisplayedDay(),
                day: day,
                timeDisplayPreference: timeDisplayPreference
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeTrackPersistenceDidChange)) { notification in
            guard let change = notification.object as? PersistenceChange else {
                Task { await reloadDisplayData() }
                return
            }
            guard change.affects(day: day) else { return }
            Task { await reloadDisplayData() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeTrackDisplayTimeChanged)) { _ in
            refreshLiveInterval()
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeTrackTimerStatusChanged)) { _ in
            refreshLiveInterval()
        }
        .onChange(of: timeDisplayPreferenceRaw) {
            dayStore.updateTimeDisplayPreference(timeDisplayPreference)
        }
        .sheet(item: $intervalPendingEdit) { interval in
            IntervalEditorSheet(interval: interval) { newStartDate, newEndDate in
                try persistenceService.updateInterval(
                    matching: interval,
                    newStartDate: newStartDate,
                    newEndDate: newEndDate
                )
            }
        }
        .alert(
            "Delete Interval?",
            isPresented: Binding(
                get: { intervalPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        intervalPendingDeletion = nil
                    }
                }
            ),
            presenting: intervalPendingDeletion
        ) { interval in
            Button("Delete", role: .destructive) {
                delete(interval)
            }
            Button("Cancel", role: .cancel) {
                intervalPendingDeletion = nil
            }
        } message: { interval in
            Text("This will permanently remove the interval from \(interval.start.timeString(using: timeDisplayPreference)) to \(interval.end.timeString(using: timeDisplayPreference)).")
        }
        .alert("Couldn't Delete Interval", isPresented: deletionErrorBinding) {
            Button("OK", role: .cancel) {
                deletionErrorMessage = nil
            }
        } message: {
            Text(deletionErrorMessage ?? "Unknown error.")
        }
    }

    private func reloadDisplayData() async {
        await dayStore.reload(day: day, timeDisplayPreference: timeDisplayPreference)
        dayStore.updateLiveInterval(
            liveIntervalForDisplayedDay(),
            day: day,
            timeDisplayPreference: timeDisplayPreference
        )
    }

    private func refreshLiveInterval() {
        dayStore.updateLiveInterval(
            liveIntervalForDisplayedDay(),
            day: day,
            timeDisplayPreference: timeDisplayPreference
        )
    }

    private func liveIntervalForDisplayedDay() -> DayIntervalSummary? {
        guard Calendar.current.isDateInToday(day) else { return nil }
        return timerService.liveIntervalForDay(day)
    }

    private var deletionErrorBinding: Binding<Bool> {
        Binding(
            get: { deletionErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    deletionErrorMessage = nil
                }
            }
        )
    }

    private var isDeleting: Bool {
        deletingIntervalID != nil
    }

    private func delete(_ interval: DayIntervalSummary) {
        deletingIntervalID = interval.id
        defer { deletingIntervalID = nil }

        do {
            try persistenceService.deleteInterval(matching: interval)
            intervalPendingDeletion = nil
        } catch let error as PersistenceError {
            intervalPendingDeletion = nil
            deletionErrorMessage = errorMessage(error)
        } catch {
            intervalPendingDeletion = nil
            deletionErrorMessage = error.localizedDescription
        }
    }

    private func errorMessage(_ error: PersistenceError) -> String {
        switch error {
        case .saveFailed(let underlying):
            return underlying
        }
    }
}

private struct LiveDayHeader: View {
    let title: String
    let totalText: String

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                    .font(.title2.bold())
                Text("Total: \(totalText)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct IntervalEditorSheet: View {
    let interval: DayIntervalSummary
    let onSave: (Date, Date) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var errorMessage: String?

    init(interval: DayIntervalSummary, onSave: @escaping (Date, Date) throws -> Void) {
        self.interval = interval
        self.onSave = onSave
        _startDate = State(initialValue: interval.sourceStart)
        _endDate = State(initialValue: interval.sourceEnd ?? interval.end)
    }

    private var isClippedToDay: Bool {
        interval.start != interval.sourceStart || interval.end != (interval.sourceEnd ?? interval.end)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Interval")
                .font(.title3.bold())

            if isClippedToDay {
                Text("You're editing the full interval, not only the clipped portion shown in this day view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Form {
                DatePicker("Start", selection: $startDate)
                DatePicker("End", selection: $endDate)
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(endDate <= startDate)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }

    private func save() {
        do {
            try onSave(startDate, endDate)
            dismiss()
        } catch let error as PersistenceError {
            errorMessage = message(for: error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func message(for error: PersistenceError) -> String {
        switch error {
        case .saveFailed(let underlying):
            return underlying
        }
    }
}
