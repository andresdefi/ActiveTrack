import SwiftUI
import SwiftData
import AppKit
import os.log

private let logger_app = Logger(subsystem: "com.activetrack.app", category: "App")

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
        super.init()

        popover.contentSize = NSSize(width: 280, height: 240)
        popover.behavior = .transient
        popover.delegate = self

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
            }
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }

        if popover.contentViewController == nil {
            popover.contentViewController = NSHostingController(
                rootView: MenuBarPopoverView(timerService: timerService, persistenceService: persistenceService)
            )
        }

        if let contentView = popover.contentViewController?.view {
            contentView.layoutSubtreeIfNeeded()
            let fittingSize = contentView.fittingSize
            popover.contentSize = NSSize(width: 280, height: min(max(fittingSize.height, 180), 480))
        }

        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }

        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}

// MARK: - App

final class ActiveTrackAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
@MainActor
struct ActiveTrackApp: App {
    @NSApplicationDelegateAdaptor(ActiveTrackAppDelegate.self) private var appDelegate
    @State private var timerService: TimerService
    @State private var persistenceService: PersistenceService
    // Retained to keep the status item alive
    private let statusBarController: StatusBarController

    init() {
        let storeURL = Self.storeURL()
        HealthLog.event("app_launch", metadata: ["store_path": storeURL.path])
        let container: ModelContainer
        do {
            let config = ModelConfiguration(url: storeURL, allowsSave: true)
            container = try ModelContainer(
                for: ActiveInterval.self,
                migrationPlan: ActiveTrackMigrationPlan.self,
                configurations: config
            )
        } catch {
            logger_app.error("Failed to open persistent store at \(storeURL.path, privacy: .public): \(error.localizedDescription). Rebuilding local store.")
            HealthLog.event("store_open_failed", metadata: ["error": error.localizedDescription])
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
        }

        let persistence = PersistenceService(modelContext: container.mainContext, storeURL: storeURL)
        if let startupWarning = persistence.startupWarning {
            HealthLog.event("startup_warning", metadata: ["message": startupWarning])
        }
        let timer = TimerService(persistenceService: persistence)

        self._timerService = State(initialValue: timer)
        self._persistenceService = State(initialValue: persistence)
        self.statusBarController = StatusBarController(timerService: timer, persistenceService: persistence)
    }

    var body: some Scene {
        Window("ActiveTrack", id: "dashboard") {
            DashboardView(timerService: timerService, persistenceService: persistenceService)
        }
        .defaultSize(width: 900, height: 600)
    }

    private static func storeURL() -> URL {
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
}
