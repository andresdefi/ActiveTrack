import SwiftUI
import SwiftData
import AppKit
import os.log

private let logger_app = Logger(subsystem: "com.activetrack.app", category: "App")

// MARK: - AppKit Status Bar Controller

/// Manages the NSStatusItem directly via AppKit, bypassing MenuBarExtra's
/// label hosting which doesn't support reactive SwiftUI updates.
@MainActor
final class StatusBarController {
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private var updateTimer: Timer?
    private var hasRunThisDay = false
    private var trackedDayStart = Calendar.current.startOfDay(for: .now)

    private let timerService: TimerService
    private let persistenceService: PersistenceService

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
        popover.contentSize = NSSize(width: 280, height: 240)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(timerService: timerService, persistenceService: persistenceService)
        )

        if let button = statusItem.button {
            button.image = Self.idleImage
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        updateStatusItem()
        startUpdateTimer()
    }

    deinit {
        MainActor.assumeIsolated {
            updateTimer?.invalidate()
        }
    }

    private func startUpdateTimer() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateStatusItem()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        updateTimer = timer
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: .now)

        if todayStart != trackedDayStart {
            trackedDayStart = todayStart
            hasRunThisDay = false
        }

        if timerService.isRunning {
            hasRunThisDay = true
            button.image = Self.redDotImage
            button.imagePosition = .imageLeading
            button.title = " " + timerService.displayTime.compactFormatted
        } else if timerService.todayTotal > 0 || hasRunThisDay {
            button.image = Self.yellowDotImage
            button.imagePosition = .imageLeading
            button.title = " " + timerService.displayTime.compactFormatted
        } else {
            button.image = Self.idleImage
            button.imagePosition = .imageOnly
            button.title = ""
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            if let contentView = popover.contentViewController?.view {
                let fittingSize = contentView.fittingSize
                popover.contentSize = NSSize(width: 280, height: min(max(fittingSize.height, 180), 420))
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Ensure the popover's window becomes key so clicks work
            popover.contentViewController?.view.window?.makeKey()
        }
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
