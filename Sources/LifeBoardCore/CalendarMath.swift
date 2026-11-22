import Foundation

/// Week arithmetic shared by every calendar view. Pure and time-zone aware:
/// days are calendar days, never 24-hour offsets, so daylight-saving changes
/// cannot shift a week.
public enum WeekMath {
    /// The first day of the week containing `day`, honouring Settings.
    public static func start(of day: LocalDay, mondayFirst: Bool, calendar: Calendar = .current) -> LocalDay {
        let weekday = calendar.component(.weekday, from: day.date(calendar: calendar)) // 1 = Sunday
        let offset = mondayFirst ? (weekday + 5) % 7 : weekday - 1
        return day.adding(days: -offset, calendar: calendar)
    }
    public static func days(of day: LocalDay, mondayFirst: Bool) -> [LocalDay] {
        let first = start(of: day, mondayFirst: mondayFirst)
        return (0..<7).map { first.adding(days: $0) }
    }
    public static func weekdaySymbols(mondayFirst: Bool) -> [String] {
        let symbols = Calendar.current.shortWeekdaySymbols
        return mondayFirst ? Array(symbols[1...]) + [symbols[0]] : symbols
    }
}
