import Foundation

enum Format {
    /// 184_812 -> "184.8K", 1_240_000 -> "1.2M", 812 -> "812"
    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        switch value {
        case 1_000_000...:
            return trimmed(value / 1_000_000) + "M"
        case 1_000...:
            return trimmed(value / 1_000) + "K"
        default:
            return String(count)
        }
    }

    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
    }

    /// "Resets in 21m", "Resets in 6d 4h", "Resets soon"
    static func resets(at date: Date?, from now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 60 else { return "Resets soon" }

        let minutes = Int(seconds / 60)
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        let mins = minutes % 60

        if days > 0 {
            return hours > 0 ? "Resets in \(days)d \(hours)h" : "Resets in \(days)d"
        }
        if hours > 0 {
            return mins > 0 ? "Resets in \(hours)h \(mins)m" : "Resets in \(hours)h"
        }
        return "Resets in \(mins)m"
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}
