import SwiftUI

struct DayDetailView: View {
    let day: Date
    let timerService: TimerService
    let persistenceService: PersistenceService

    @State private var persistedIntervals: [DayIntervalSummary] = []
    @State private var liveRefreshToken = 0
    @State private var intervalPendingEdit: DayIntervalSummary?
    @State private var intervalPendingDeletion: DayIntervalSummary?
    @State private var deletingIntervalID: String?
    @State private var deletionErrorMessage: String?

    private var displayedIntervals: [DayIntervalSummary] {
        _ = liveRefreshToken
        var intervals = persistedIntervals
        if let liveInterval = timerService.liveIntervalForDay(day) {
            intervals.append(liveInterval)
        }
        return intervals
    }

    private var displayedTotal: TimeInterval {
        displayedIntervals.reduce(0) { $0 + $1.duration }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LiveDayHeader(day: day, total: displayedTotal)
                .padding(.bottom, 8)

            if displayedIntervals.isEmpty {
                ContentUnavailableView {
                    Label("No Intervals", systemImage: "clock")
                } description: {
                    Text("No tracked time for this day.")
                }
            } else {
                List {
                    ForEach(displayedIntervals) { interval in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(interval.start.timeString) – \(interval.end.timeString)")
                                    .font(.body)
                            }
                            Spacer()
                            Text(interval.duration.formattedHoursMinutes)
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
        .task(id: day) { await refreshPersistedData() }
        .onReceive(NotificationCenter.default.publisher(for: .activeTrackPersistenceDidChange)) { notification in
            guard let change = notification.object as? PersistenceChange else {
                Task { await refreshPersistedData() }
                return
            }
            guard change.affects(day: day) else { return }
            Task { await refreshPersistedData() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeTrackDisplayTimeChanged)) { _ in
            guard timerService.isRunning, Calendar.current.isDateInToday(day) else { return }
            liveRefreshToken &+= 1
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
            Text("This will permanently remove the interval from \(interval.start.timeString) to \(interval.end.timeString).")
        }
        .alert("Couldn't Delete Interval", isPresented: deletionErrorBinding) {
            Button("OK", role: .cancel) {
                deletionErrorMessage = nil
            }
        } message: {
            Text(deletionErrorMessage ?? "Unknown error.")
        }
    }

    private func refreshPersistedData() async {
        persistedIntervals = (await persistenceService.intervalSummariesForDayAsync(day))
            .filter { !$0.isOpen }
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
    let day: Date
    let total: TimeInterval

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(day.shortDateString)
                    .font(.title2.bold())
                Text("Total: \(total.formattedHoursMinutes)")
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
