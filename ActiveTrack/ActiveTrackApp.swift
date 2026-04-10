import SwiftUI
import SwiftData
import AppKit
import os.log

private let logger_app = Logger(subsystem: "com.activetrack.app", category: "App")

@MainActor
private final class AppTerminationCoordinator {
    static let shared = AppTerminationCoordinator()

    weak var timerService: TimerService?
}

@MainActor
private final class UITestLaunchCoordinator {
    static let shared = UITestLaunchCoordinator()

    var windowLauncher: UITestWindowLauncher?
    var isUITesting = false

    func presentConfiguredWindowsIfNeeded() {
        if isUITesting {
            closePlaceholderWindows()
        }
        windowLauncher?.presentConfiguredWindows()
    }

    private func closePlaceholderWindows() {
        for window in NSApp.windows where window.title == "ActiveTrack" {
            window.close()
        }
    }
}

@MainActor
private final class UITestWindowLauncher {
    private let options: AppLaunchOptions
    private let timerService: TimerService
    private let persistenceService: PersistenceService
    private var windows: [NSWindow] = []

    init(options: AppLaunchOptions, timerService: TimerService, persistenceService: PersistenceService) {
        self.options = options
        self.timerService = timerService
        self.persistenceService = persistenceService
    }

    func presentConfiguredWindows() {
        guard options.isUITesting else { return }

        NSApp.setActivationPolicy(.regular)

        if options.openUISmokeWindowOnLaunch {
            windows.append(makeWindow(title: "ActiveTrack Smoke Tests") {
                UITestHarnessView(timerService: timerService, persistenceService: persistenceService)
            })
        }

        if options.openDashboardOnLaunch {
            windows.append(makeWindow(title: "ActiveTrack Dashboard") {
                DashboardView(timerService: timerService, persistenceService: persistenceService)
            })
        }

        if options.openSettingsOnLaunch {
            windows.append(makeWindow(title: "ActiveTrack Settings") {
                SettingsView(persistenceService: persistenceService)
            })
        }

        windows.forEach { window in
            window.center()
            window.makeKeyAndOrderFront(nil)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> NSWindow {
        let controller = NSHostingController(rootView: content())
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.setContentSize(NSSize(width: 900, height: 620))
        window.styleMask.insert(.resizable)
        window.identifier = NSUserInterfaceItemIdentifier(title)
        return window
    }
}

// MARK: - AppKit Status Bar Controller

/// Manages the NSStatusItem directly via AppKit, bypassing MenuBarExtra's
/// label hosting which doesn't support reactive SwiftUI updates.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private enum StatusAppearance {
        case idle
        case paused
        case running
    }

    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private let popoverViewController: NSHostingController<MenuBarPopoverView>
    private var timerStatusObserver: Any?
    private var displayTimeObserver: Any?
    private var targetReachedObserver: Any?
    private var hasRunThisDay = false
    private var trackedDayStart = Calendar.current.startOfDay(for: .now)
    private var currentAppearance: StatusAppearance?

    private let timerService: TimerService
    private let persistenceService: PersistenceService
    private let calendar = Calendar.autoupdatingCurrent

    private static let redDotImage: NSImage = {
        let size = NSSize(width: 7, height: 7)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.red.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()

    private static let yellowDotImage: NSImage = {
        let size = NSSize(width: 7, height: 7)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemYellow.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()

    private static let idleImage: NSImage = {
        let image = NSImage(systemSymbolName: "timer.circle", accessibilityDescription: "ActiveTrack")!
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        return image.withSymbolConfiguration(config)!
    }()

    init(timerService: TimerService, persistenceService: PersistenceService) {
        self.timerService = timerService
        self.persistenceService = persistenceService

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        popoverViewController = NSHostingController(
            rootView: MenuBarPopoverView(timerService: timerService, persistenceService: persistenceService)
        )
        super.init()

        popover.contentSize = NSSize(width: 280, height: 240)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = popoverViewController

        if let button = statusItem.button {
            button.image = Self.idleImage
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        updateStatusItem()
        observeTimerStatus()
        observeTargetReached()
        reconcileStatusUpdates()
    }

    deinit {
        MainActor.assumeIsolated {
            if let timerStatusObserver {
                NotificationCenter.default.removeObserver(timerStatusObserver)
            }
            if let displayTimeObserver {
                NotificationCenter.default.removeObserver(displayTimeObserver)
            }
            if let targetReachedObserver {
                NotificationCenter.default.removeObserver(targetReachedObserver)
            }
        }
    }

    private func reconcileStatusUpdates() {
        updateStatusItem()
    }

    private func observeTimerStatus() {
        timerStatusObserver = NotificationCenter.default.addObserver(
            forName: .activeTrackTimerStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.reconcileStatusUpdates()
            }
        }

        displayTimeObserver = NotificationCenter.default.addObserver(
            forName: .activeTrackDisplayTimeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.updateStatusItem()
            }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let todayStart = calendar.startOfDay(for: .now)

        if todayStart != trackedDayStart {
            trackedDayStart = todayStart
            hasRunThisDay = false
        }

        if timerService.isRunning {
            hasRunThisDay = true
            applyStatusAppearance(.running, title: " " + timerService.displayTime.compactFormatted, to: button)
        } else if timerService.todayTotal > 0 || hasRunThisDay {
            applyStatusAppearance(.paused, title: " " + timerService.displayTime.compactFormatted, to: button)
        } else {
            applyStatusAppearance(.idle, title: "", to: button)
        }
    }

    private func applyStatusAppearance(_ appearance: StatusAppearance, title: String, to button: NSStatusBarButton) {
        if currentAppearance != appearance {
            switch appearance {
            case .idle:
                button.image = Self.idleImage
                button.imagePosition = .imageOnly
            case .paused:
                button.image = Self.yellowDotImage
                button.imagePosition = .imageLeading
            case .running:
                button.image = Self.redDotImage
                button.imagePosition = .imageLeading
            }
            currentAppearance = appearance
        }

        if button.title != title {
            button.title = title
        }
    }

    private func observeTargetReached() {
        targetReachedObserver = NotificationCenter.default.addObserver(
            forName: .activeTrackTargetReached,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.showPopover()
                guard let self,
                      let duration = self.timerService.reachedTargetDuration,
                      let mode = self.timerService.reachedTargetMode else { return }
                Task {
                    await TargetNotificationController.postTargetReachedNotification(duration: duration, mode: mode)
                }
            }
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }

        let contentView = popoverViewController.view
        contentView.layoutSubtreeIfNeeded()
        let fittingSize = contentView.fittingSize
        popover.contentSize = NSSize(width: 280, height: min(max(fittingSize.height, 180), 480))

        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }

        NSApp.activate(ignoringOtherApps: true)
        popoverViewController.view.window?.makeKey()
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    func popoverDidClose(_ notification: Notification) {
    }
}

// MARK: - App

@MainActor
final class ActiveTrackAppDelegate: NSObject, NSApplicationDelegate {
    private let terminationAttempt: () -> (shouldTerminate: Bool, error: PersistenceError?)
    private let blockedAlertPresenter: (PersistenceError?) -> Void

    override init() {
        self.terminationAttempt = Self.defaultTerminationAttempt
        self.blockedAlertPresenter = Self.presentTerminationBlockedAlert
        super.init()
    }

    init(
        terminationAttempt: @escaping () -> (shouldTerminate: Bool, error: PersistenceError?),
        blockedAlertPresenter: @escaping (PersistenceError?) -> Void = { _ in }
    ) {
        self.terminationAttempt = terminationAttempt
        self.blockedAlertPresenter = blockedAlertPresenter
        super.init()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UITestLaunchCoordinator.shared.presentConfiguredWindowsIfNeeded()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let termination = terminationAttempt()
        guard termination.shouldTerminate else {
            HealthLog.event(
                "app_quit_blocked",
                metadata: ["error": Self.terminationErrorMessage(termination.error)]
            )
            blockedAlertPresenter(termination.error)
            return .terminateCancel
        }

        HealthLog.event("app_quit")
        return .terminateNow
    }

    private static func defaultTerminationAttempt() -> (shouldTerminate: Bool, error: PersistenceError?) {
        guard let timerService = AppTerminationCoordinator.shared.timerService else {
            return (true, nil)
        }

        let shouldTerminate = timerService.prepareForTermination()
        return (shouldTerminate, timerService.lastError)
    }

    private static func presentTerminationBlockedAlert(error: PersistenceError?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ActiveTrack couldn't save your running timer before quitting."
        alert.informativeText = "The app is staying open so you can retry without losing tracked time.\n\n\(terminationErrorMessage(error))"
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func terminationErrorMessage(_ error: PersistenceError?) -> String {
        guard let error else {
            return "Unknown persistence error."
        }

        switch error {
        case .saveFailed(let underlying):
            return underlying
        }
    }

}

@main
@MainActor
struct ActiveTrackApp: App {
    @NSApplicationDelegateAdaptor(ActiveTrackAppDelegate.self) private var appDelegate
    @State private var timerService: TimerService
    @State private var persistenceService: PersistenceService
    private let isUITesting: Bool
    // Retained to keep the status item alive
    private let statusBarController: StatusBarController?
    private let uiTestWindowLauncher: UITestWindowLauncher?

    init() {
        let launchOptions = AppLaunchOptions()
        let storeURL = Self.storeURL(for: launchOptions)
        HealthLog.event("app_launch", metadata: ["store_path": storeURL?.path ?? "in-memory"])
        let container: ModelContainer
        do {
            let config: ModelConfiguration
            if let storeURL {
                config = ModelConfiguration(url: storeURL, allowsSave: true)
            } else {
                config = ModelConfiguration(isStoredInMemoryOnly: true)
            }
            container = try ModelContainer(
                for: ActiveInterval.self,
                migrationPlan: ActiveTrackMigrationPlan.self,
                configurations: config
            )
        } catch {
            if let storeURL {
                logger_app.error("Failed to open persistent store at \(storeURL.path, privacy: .public): \(error.localizedDescription). Rebuilding local store.")
            } else {
                logger_app.error("Failed to open in-memory store: \(error.localizedDescription).")
            }
            HealthLog.event("store_open_failed", metadata: ["error": error.localizedDescription])
            if let storeURL {
                Self.quarantineStoreFiles(at: storeURL)
                do {
                    let freshConfig = ModelConfiguration(url: storeURL, allowsSave: true)
                    container = try ModelContainer(
                        for: ActiveInterval.self,
                        migrationPlan: ActiveTrackMigrationPlan.self,
                        configurations: freshConfig
                    )
                } catch {
                    logger_app.error("Failed to rebuild persistent store: \(error.localizedDescription). Falling back to in-memory store.")
                    HealthLog.event("store_rebuild_failed", metadata: ["error": error.localizedDescription])
                    let memoryConfig = ModelConfiguration(isStoredInMemoryOnly: true)
                    do {
                        container = try ModelContainer(
                            for: ActiveInterval.self,
                            migrationPlan: ActiveTrackMigrationPlan.self,
                            configurations: memoryConfig
                        )
                    } catch {
                        fatalError("Failed to create model container: \(error)")
                    }
                }
            } else {
                let memoryConfig = ModelConfiguration(isStoredInMemoryOnly: true)
                do {
                    container = try ModelContainer(
                        for: ActiveInterval.self,
                        migrationPlan: ActiveTrackMigrationPlan.self,
                        configurations: memoryConfig
                    )
                } catch {
                    fatalError("Failed to create in-memory model container: \(error)")
                }
            }
        }

        let persistence = PersistenceService(modelContext: container.mainContext, storeURL: storeURL)
        if let startupWarning = persistence.startupWarning {
            HealthLog.event("startup_warning", metadata: ["message": startupWarning])
        }
        let timer = TimerService(persistenceService: persistence)
        if launchOptions.seedSampleHistory {
            Self.seedUITestHistory(using: persistence)
            timer.refreshTodayTotal()
        }
        if launchOptions.startRunningTimerOnLaunch {
            timer.start()
        }
        if storeURL != nil && !launchOptions.isUITesting {
            Task { @MainActor in
                do {
                    _ = try persistence.createAutomaticBackupIfNeeded()
                } catch {
                    HealthLog.event("automatic_backup_failed", metadata: ["error": error.localizedDescription])
                }
            }
        }
        AppTerminationCoordinator.shared.timerService = timer

        self._timerService = State(initialValue: timer)
        self._persistenceService = State(initialValue: persistence)
        self.isUITesting = launchOptions.isUITesting
        self.statusBarController = launchOptions.isUITesting ? nil : StatusBarController(timerService: timer, persistenceService: persistence)
        let launcher = UITestWindowLauncher(options: launchOptions, timerService: timer, persistenceService: persistence)
        self.uiTestWindowLauncher = launchOptions.isUITesting ? launcher : nil
        UITestLaunchCoordinator.shared.isUITesting = launchOptions.isUITesting
        UITestLaunchCoordinator.shared.windowLauncher = launchOptions.isUITesting ? launcher : nil
    }

    var body: some Scene {
        Window("ActiveTrack", id: "dashboard") {
            Group {
                if isUITesting {
                    EmptyView()
                } else {
                    DashboardView(timerService: timerService, persistenceService: persistenceService)
                }
            }
        }
        .defaultSize(width: isUITesting ? 1 : 900, height: isUITesting ? 1 : 600)

        Settings {
            SettingsView(persistenceService: persistenceService)
        }
    }

    private static func storeURL(for launchOptions: AppLaunchOptions) -> URL? {
        if launchOptions.useInMemoryStore {
            return nil
        }

        if launchOptions.isUITesting {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ActiveTrack-UITests", isDirectory: true)
                .appendingPathComponent(String(ProcessInfo.processInfo.processIdentifier), isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent("ActiveTrack.store")
        }

        return persistentStoreURL()
    }

    private static func persistentStoreURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("ActiveTrack", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("ActiveTrack.store")
    }

    private static func quarantineStoreFiles(at storeURL: URL) {
        let fileManager = FileManager.default
        let timestamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let backup = URL(fileURLWithPath: source.path + ".corrupt-\(timestamp)")
            try? fileManager.moveItem(at: source, to: backup)
        }
    }

    private static func seedUITestHistory(using persistence: PersistenceService) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        func insertInterval(on day: Date, startHour: Int, startMinute: Int, endHour: Int, endMinute: Int) {
            guard let start = calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: day),
                  let end = calendar.date(bySettingHour: endHour, minute: endMinute, second: 0, of: day) else {
                return
            }
            do {
                let interval = try persistence.createInterval(startDate: start)
                try persistence.closeInterval(interval, endDate: end)
            } catch {
                HealthLog.event("ui_test_seed_failed", metadata: ["error": error.localizedDescription])
            }
        }

        insertInterval(on: yesterday, startHour: 14, startMinute: 0, endHour: 15, endMinute: 30)
        insertInterval(on: today, startHour: 9, startMinute: 0, endHour: 10, endMinute: 0)
    }
}
