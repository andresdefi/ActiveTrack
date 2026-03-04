import SwiftUI
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.activetrack.app", category: "App")

@main
struct ActiveTrackApp: App {
    let modelContainer: ModelContainer
    @State private var timerService: TimerService
    @State private var persistenceService: PersistenceService

    init() {
        let storeURL = ActiveTrackApp.storeURL()
        ActiveTrackApp.migrateDefaultStoreIfNeeded(to: storeURL)

        let config = ModelConfiguration(
            url: storeURL,
            allowsSave: true
        )
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: ActiveInterval.self,
                migrationPlan: ActiveTrackMigrationPlan.self,
                configurations: config
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        let persistence = PersistenceService(modelContext: container.mainContext)
        let timer = TimerService()
        timer.configure(persistenceService: persistence)

        self.modelContainer = container
        self._timerService = State(initialValue: timer)
        self._persistenceService = State(initialValue: persistence)
    }

    private static func storeURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ActiveTrack", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ActiveTrack.store")
    }

    private static func migrateDefaultStoreIfNeeded(to newURL: URL) {
        guard !FileManager.default.fileExists(atPath: newURL.path) else { return }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let defaultStore = appSupport.appendingPathComponent("default.store")

        guard FileManager.default.fileExists(atPath: defaultStore.path) else { return }

        do {
            try FileManager.default.moveItem(at: defaultStore, to: newURL)
            logger.info("Migrated default.store to ActiveTrack.store")

            // Also move WAL and SHM files if they exist
            for suffix in ["-wal", "-shm"] {
                let src = URL(fileURLWithPath: defaultStore.path + suffix)
                let dst = URL(fileURLWithPath: newURL.path + suffix)
                if FileManager.default.fileExists(atPath: src.path) {
                    try FileManager.default.moveItem(at: src, to: dst)
                }
            }
        } catch {
            logger.error("Failed to migrate default.store: \(error.localizedDescription)")
        }
    }

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

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView(timerService: timerService, persistenceService: persistenceService)
        } label: {
            if timerService.isRunning {
                HStack(spacing: 4) {
                    Image(nsImage: Self.redDotImage)
                    Text(timerService.displayTime.compactFormatted)
                }
            } else if timerService.todayTotal > 0 {
                HStack(spacing: 4) {
                    Image(nsImage: Self.yellowDotImage)
                    Text(timerService.displayTime.compactFormatted)
                }
            } else {
                Image(systemName: "timer.circle")
            }
        }
        .menuBarExtraStyle(.window)
        .modelContainer(modelContainer)

        Window("ActiveTrack", id: "dashboard") {
            DashboardView(timerService: timerService, persistenceService: persistenceService)
        }
        .modelContainer(modelContainer)
        .defaultSize(width: 900, height: 600)
    }
}
