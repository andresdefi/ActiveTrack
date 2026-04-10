import SwiftUI
import AppKit
import UserNotifications

struct SettingsView: View {
    let persistenceService: PersistenceService

    @AppStorage(AppPreferenceKey.timeDisplayPreference) private var timeDisplayPreferenceRaw = TimeDisplayPreference.system.rawValue
    @AppStorage(AppPreferenceKey.pauseOnSleep) private var pauseOnSleep = true
    @AppStorage(AppPreferenceKey.resumeAfterWake) private var resumeAfterWake = false
    @AppStorage(AppPreferenceKey.targetNotificationsEnabled) private var targetNotificationsEnabled = false
    @AppStorage(AppPreferenceKey.automaticBackupsEnabled) private var automaticBackupsEnabled = true

    @State private var launchAtLoginEnabled = false
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    private var timeDisplayPreference: Binding<TimeDisplayPreference> {
        Binding(
            get: { TimeDisplayPreference(rawValue: timeDisplayPreferenceRaw) ?? .system },
            set: { timeDisplayPreferenceRaw = $0.rawValue }
        )
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            trackingTab
                .tabItem {
                    Label("Tracking", systemImage: "timer")
                }

            notificationsTab
                .tabItem {
                    Label("Notifications", systemImage: "bell.badge")
                }

            dataTab
                .tabItem {
                    Label("Data", systemImage: "externaldrive")
                }
        }
        .frame(width: 560, height: 430)
        .padding(18)
        .accessibilityIdentifier("activeTrack.settingsRoot")
        .task {
            launchAtLoginEnabled = LaunchAtLoginController.isEnabled()
            notificationAuthorizationStatus = await TargetNotificationController.authorizationStatus()
        }
        .alert("Settings Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "Unknown error.")
        }
    }

    private var generalTab: some View {
        Form {
            Toggle("Launch ActiveTrack when I log in", isOn: launchAtLoginBinding)
            Text("This launches the app into your menu bar at login. It does not start the timer automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Time format", selection: timeDisplayPreference) {
                ForEach(TimeDisplayPreference.allCases) { preference in
                    Text(preference.title)
                        .tag(preference)
                }
            }
            .pickerStyle(.menu)

            Text("Time rows in the dashboard and interval editor will follow this format.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var trackingTab: some View {
        Form {
            Toggle("Pause when Mac sleeps", isOn: $pauseOnSleep)

            Toggle("Resume automatically after wake", isOn: $resumeAfterWake)
                .disabled(!pauseOnSleep)

            Text("Sleep pause stays on by default, and automatic resume remains optional.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var notificationsTab: some View {
        Form {
            Toggle("Notify when a target is reached", isOn: targetNotificationsBinding)

            Text(notificationStatusDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var dataTab: some View {
        Form {
            Toggle("Create automatic daily backups", isOn: $automaticBackupsEnabled)

            if let lastBackupDate = AppPreferences.lastBackupDate() {
                LabeledContent("Last backup") {
                    Text(lastBackupDate.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Export CSV") {
                    exportCSV()
                }
                .accessibilityIdentifier("activeTrack.exportCSVButton")

                Button("Export JSON") {
                    exportJSON()
                }
                .accessibilityIdentifier("activeTrack.exportJSONButton")
            }

            HStack {
                Button("Create Backup Now") {
                    createBackupNow()
                }
                .accessibilityIdentifier("activeTrack.createBackupButton")

                Button("Reveal Backup Folder") {
                    revealBackupFolder()
                }
                .accessibilityIdentifier("activeTrack.revealBackupFolderButton")
            }

            if let infoMessage {
                Text(infoMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { newValue in
                do {
                    try LaunchAtLoginController.setEnabled(newValue)
                    launchAtLoginEnabled = newValue
                    infoMessage = newValue ? "ActiveTrack will launch at login." : "Launch at login disabled."
                } catch {
                    launchAtLoginEnabled = LaunchAtLoginController.isEnabled()
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    private var targetNotificationsBinding: Binding<Bool> {
        Binding(
            get: { targetNotificationsEnabled },
            set: { newValue in
                if !newValue {
                    targetNotificationsEnabled = false
                    infoMessage = "Target notifications disabled."
                    return
                }

                targetNotificationsEnabled = true
                Task {
                    do {
                        try await TargetNotificationController.setNotificationsEnabled(true)
                        notificationAuthorizationStatus = await TargetNotificationController.authorizationStatus()
                        infoMessage = "Target notifications enabled."
                    } catch {
                        targetNotificationsEnabled = false
                        notificationAuthorizationStatus = await TargetNotificationController.authorizationStatus()
                        errorMessage = error.localizedDescription
                    }
                }
            }
        )
    }

    private var notificationStatusDescription: String {
        switch notificationAuthorizationStatus {
        case .notDetermined:
            return "ActiveTrack will ask for permission when you enable target notifications."
        case .denied:
            return "Notifications are currently denied for ActiveTrack in macOS settings."
        case .authorized, .provisional, .ephemeral:
            return "When enabled, ActiveTrack will post a local notification when a target pauses the timer."
        @unknown default:
            return "Notification permission status is unavailable."
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }

    private func exportCSV() {
        export(
            defaultName: "ActiveTrack-Export-\(timestamp()).csv",
            dataBuilder: { try persistenceService.exportCSV() }
        )
    }

    private func exportJSON() {
        export(
            defaultName: "ActiveTrack-Export-\(timestamp()).json",
            dataBuilder: { try persistenceService.exportJSON() }
        )
    }

    private func export(defaultName: String, dataBuilder: () throws -> Data) {
        do {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = defaultName

            guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
            let data = try dataBuilder()
            try data.write(to: destinationURL, options: .atomic)
            infoMessage = "Saved \(destinationURL.lastPathComponent)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createBackupNow() {
        do {
            let backupURL = try persistenceService.createBackupNow()
            infoMessage = "Created backup \(backupURL.lastPathComponent)."
            NSWorkspace.shared.activateFileViewerSelecting([backupURL])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revealBackupFolder() {
        do {
            let backupsURL = try persistenceService.backupsDirectoryURL()
            NSWorkspace.shared.open(backupsURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func timestamp(now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: now)
    }
}
