import Foundation

extension TimeInterval {
    var formattedHoursMinutes: String {
        let totalSeconds = Int(self)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        return "\(hours)h \(minutes)m"
    }

    var formattedHoursMinutesSeconds: String {
        let totalSeconds = Int(self)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%dh %02dm %02ds", hours, minutes, seconds)
    }

    var compactFormatted: String {
        let totalSeconds = Int(self)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

extension Date {
    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var shortDateString: String {
        Self.shortDateFormatter.string(from: self)
    }

    var timeString: String {
        Self.timeFormatter.string(from: self)
    }

    var weekOfYear: Int {
        Calendar.current.component(.weekOfYear, from: self)
    }

    var monthYearString: String {
        self.formatted(.dateTime.month(.abbreviated).year())
    }

    var weekRangeString: String {
        let calendar = Calendar.current
        guard let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: self)),
              let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) else {
            return ""
        }
        let startFormatted = weekStart.formatted(.dateTime.month(.abbreviated).day())
        let endFormatted = weekEnd.formatted(.dateTime.month(.abbreviated).day())
        return "\(startFormatted)–\(endFormatted)"
    }
}
