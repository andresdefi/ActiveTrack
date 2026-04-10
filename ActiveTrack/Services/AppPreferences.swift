import Foundation
import ServiceManagement
import UserNotifications

enum AppPreferenceKey {
    static let timeDisplayPreference = "timeDisplayPreference"
    static let targetSectionEnabled = "targetSectionEnabled"
    static let pauseOnSleep = "pauseOnSleep"
    static let resumeAfterWake = "resumeAfterWake"
    static let targetNotificationsEnabled = "targetNotificationsEnabled"
    static let automaticBackupsEnabled = "automaticBackupsEnabled"
    static let lastBackupDate = "lastBackupDate"
}

enum TimeDisplayPreference: String, CaseIterable, Identifiable {
    case system
    case twentyFourHour
    case twelveHour

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .twentyFourHour:
            return "24-hour"
        case .twelveHour:
            return "12-hour"
        }
    }
}

enum AppPreferences {
    static func timeDisplayPreference(userDefaults: UserDefaults = .standard) -> TimeDisplayPreference {
        guard let rawValue = userDefaults.string(forKey: AppPreferenceKey.timeDisplayPreference),
              let preference = TimeDisplayPreference(rawValue: rawValue) else {
            return .system
        }
        return preference
    }

    static func pauseOnSleepEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        bool(forKey: AppPreferenceKey.pauseOnSleep, defaultValue: true, userDefaults: userDefaults)
    }

    static func resumeAfterWakeEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        bool(forKey: AppPreferenceKey.resumeAfterWake, defaultValue: false, userDefaults: userDefaults)
    }

    static func targetNotificationsEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        bool(forKey: AppPreferenceKey.targetNotificationsEnabled, defaultValue: false, userDefaults: userDefaults)
    }

    static func automaticBackupsEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        bool(forKey: AppPreferenceKey.automaticBackupsEnabled, defaultValue: true, userDefaults: userDefaults)
    }

    static func lastBackupDate(userDefaults: UserDefaults = .standard) -> Date? {
        userDefaults.object(forKey: AppPreferenceKey.lastBackupDate) as? Date
    }

    static func setLastBackupDate(_ date: Date?, userDefaults: UserDefaults = .standard) {
        if let date {
            userDefaults.set(date, forKey: AppPreferenceKey.lastBackupDate)
        } else {
            userDefaults.removeObject(forKey: AppPreferenceKey.lastBackupDate)
        }
    }

    private static func bool(forKey key: String, defaultValue: Bool, userDefaults: UserDefaults) -> Bool {
        guard userDefaults.object(forKey: key) != nil else { return defaultValue }
        return userDefaults.bool(forKey: key)
    }
}

enum TargetNotificationControllerError: LocalizedError {
    case permissionDenied
    case deliveryFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "ActiveTrack couldn't enable target notifications because notification permission was denied."
        case .deliveryFailed(let message):
            return message
        }
    }
}

@MainActor
enum LaunchAtLoginController {
    static func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled else { return }
            try service.unregister()
        }
    }
}

enum TargetNotificationController {
    static func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    static func setNotificationsEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) async throws {
        if enabled {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            guard granted else {
                throw TargetNotificationControllerError.permissionDenied
            }
        }

        userDefaults.set(enabled, forKey: AppPreferenceKey.targetNotificationsEnabled)
    }

    static func postTargetReachedNotification(
        duration: TimeInterval,
        mode: TimerTargetMode,
        userDefaults: UserDefaults = .standard
    ) async {
        guard AppPreferences.targetNotificationsEnabled(userDefaults: userDefaults) else { return }
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = "Target reached"
        content.body = "ActiveTrack paused after \(duration.formattedHoursMinutes) \(mode.summaryText)."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "ActiveTrack.targetReached.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            HealthLog.event("target_notification_failed", metadata: ["error": error.localizedDescription])
        }
    }
}
