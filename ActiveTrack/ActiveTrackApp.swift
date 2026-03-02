import SwiftUI
import SwiftData

@main
struct ActiveTrackApp: App {
    let modelContainer: ModelContainer
    @State private var timerService: TimerService
    @State private var persistenceService: PersistenceService

    init() {
        let container = try! ModelContainer(for: ActiveInterval.self)
        let persistence = PersistenceService(modelContext: container.mainContext)
        let timer = TimerService()
        timer.configure(persistenceService: persistence)

        self.modelContainer = container
        self._timerService = State(initialValue: timer)
        self._persistenceService = State(initialValue: persistence)
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

        WindowGroup(id: "dashboard") {
            DashboardView(timerService: timerService, persistenceService: persistenceService)
        }
        .modelContainer(modelContainer)
        .defaultSize(width: 900, height: 600)
    }
}
