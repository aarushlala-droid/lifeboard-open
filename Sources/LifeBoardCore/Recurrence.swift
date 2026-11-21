import Foundation

public enum RecurrenceEngine {
    public static func nextDay(for task: TaskItem, completedOn day: LocalDay = .today) -> LocalDay? {
        guard let recurrence = task.recurrence, (1...365).contains(recurrence.interval) else { return nil }
        let anchor = recurrence.nextDay ?? task.scheduledDay ?? task.dueDay ?? day
        switch recurrence.frequency {
        case "daily": return anchor.adding(days: recurrence.interval)
        case "weekly": return anchor.adding(days: 7 * recurrence.interval)
        case "monthly":
            let total = anchor.year * 12 + anchor.month - 1 + recurrence.interval
            let year = total / 12, month = total % 12 + 1
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let first = calendar.date(from: DateComponents(year: year, month: month, day: 1, hour: 12))!
            let count = calendar.range(of: .day, in: .month, for: first)!.count
            return LocalDay(year: year, month: month, day: min(anchor.day, count))
        default: return nil
        }
    }
    public static func occurrenceID(seriesID: UUID, day: LocalDay) -> UUID {
        var tuple = seriesID.uuid
        withUnsafeMutableBytes(of: &tuple) { bytes in
            let stamp = UInt32(day.year * 372 + (day.month - 1) * 31 + day.day)
            for i in 0..<4 { bytes[12 + i] ^= UInt8((stamp >> UInt32(24 - i * 8)) & 255) }
            bytes[6] = (bytes[6] & 0x0f) | 0x50
            bytes[8] = (bytes[8] & 0x3f) | 0x80
        }
        return UUID(uuid: tuple)
    }
    public static func nextTask(after task: TaskItem, completedOn day: LocalDay = .today) -> TaskItem? {
        guard let nextDay = nextDay(for: task, completedOn: day), nextDay.year <= 9999 else { return nil }
        var next = task
        let series = task.recurrenceSeriesID ?? task.id
        next.id = occurrenceID(seriesID: series, day: nextDay); next.recurrenceSeriesID = series
        next.isCompleted = false; next.completedAt = nil; next.completionPercent = 0
        next.isArchived = false; next.archivedAt = nil; next.actualMinutes = nil
        next.dueDay = task.dueDay == nil ? nil : nextDay
        next.scheduledDay = task.scheduledDay == nil ? nil : nextDay
        next.recurrence?.nextDay = nextDay
        next.createdAt = .now; next.modifiedAt = .now
        next.subtasks = next.subtasks?.map { subtask in var item = subtask; item.isCompleted = false; return item }
        return next
    }

    /// Completion and next occurrence share the same durable transaction.
    public static func appendNextOccurrence(after task: TaskItem, in data: inout LifeBoardData, completedOn day: LocalDay = .today) {
        guard let next = nextTask(after: task, completedOn: day), !data.tasks.contains(where: { $0.id == next.id }) else { return }
        data.tasks.append(next)
    }
}
