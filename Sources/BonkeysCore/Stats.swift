import Foundation

/// Per-day totals. Deliberately cannot represent which keys were typed.
public struct UsageStats: Codable, Sendable, Equatable {
    public struct Day: Codable, Sendable, Equatable { public var keys = 0; public var clicks = 0 }
    public var days: [String: Day] = [:]
    /// Wooden fish knocks. Optional so stats saved before it existed still load.
    public var merit: Int?
    public init() {}

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    public mutating func add(keys: Int, clicks: Int, on date: Date, calendar: Calendar = .current) {
        days[Self.dayKey(date, calendar: calendar), default: Day()].keys += keys
        days[Self.dayKey(date, calendar: calendar), default: Day()].clicks += clicks
    }
    public func keys(on date: Date, calendar: Calendar = .current) -> Int {
        days[Self.dayKey(date, calendar: calendar)]?.keys ?? 0
    }
    public var totalKeys: Int { days.values.reduce(0) { $0 + $1.keys } }
    public var totalClicks: Int { days.values.reduce(0) { $0 + $1.clicks } }

    /// Consecutive days with typing, ending today (or yesterday, if today hasn't started yet).
    public func streak(today: Date, calendar: Calendar = .current) -> Int {
        var day = today, n = 0
        if keys(on: day, calendar: calendar) == 0 { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day }
        while keys(on: day, calendar: calendar) > 0, let previous = calendar.date(byAdding: .day, value: -1, to: day) {
            n += 1
            day = previous
        }
        return n
    }
}

/// Quiet hours in minutes after midnight. An end before the start means it runs past midnight.
public struct QuietHours: Sendable {
    public static func contains(_ minute: Int, start: Int, end: Int) -> Bool {
        guard start != end else { return false }
        return start < end ? (start..<end).contains(minute) : (minute >= start || minute < end)
    }
}
