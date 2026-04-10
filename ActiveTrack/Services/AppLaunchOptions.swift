import Foundation

struct AppLaunchOptions {
    let isUITesting: Bool
    let useInMemoryStore: Bool
    let openUISmokeWindowOnLaunch: Bool
    let openDashboardOnLaunch: Bool
    let openSettingsOnLaunch: Bool
    let seedSampleHistory: Bool
    let startRunningTimerOnLaunch: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let argumentSet = Set(arguments)
        let isUITesting = argumentSet.contains("-ui-testing")
        self.isUITesting = isUITesting
        self.useInMemoryStore = argumentSet.contains("-use-in-memory-store")
        self.openDashboardOnLaunch = argumentSet.contains("-open-dashboard-on-launch")
        self.openSettingsOnLaunch = argumentSet.contains("-open-settings-on-launch")
        self.seedSampleHistory = argumentSet.contains("-seed-sample-history")
        self.startRunningTimerOnLaunch = argumentSet.contains("-start-running-timer")

        let explicitlyRequestedSmokeWindow = argumentSet.contains("-open-ui-smoke-window")
        self.openUISmokeWindowOnLaunch = explicitlyRequestedSmokeWindow || (isUITesting && !openDashboardOnLaunch && !openSettingsOnLaunch)
    }
}
