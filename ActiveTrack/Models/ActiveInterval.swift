import Foundation
import SwiftData

@Model
final class ActiveInterval {
    var id: UUID
    var startDate: Date
    var endDate: Date?

    init(startDate: Date = .now, endDate: Date? = nil) {
        self.id = UUID()
        self.startDate = startDate
        self.endDate = endDate
    }

    var duration: TimeInterval {
        let end = endDate ?? .now
        return end.timeIntervalSince(startDate)
    }

    var isRunning: Bool {
        endDate == nil
    }
}
