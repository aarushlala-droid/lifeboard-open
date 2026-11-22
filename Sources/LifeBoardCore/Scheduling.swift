import Foundation

/// Half-open wall-clock intervals. External events retain their true instants in storage.
public struct BusyInterval: Hashable, Sendable {
    public var id: String
    public var start: Int
    public var end: Int
    public init(id: String = UUID().uuidString, start: Int, end: Int) { self.id = id; self.start = start; self.end = end }
}
public struct ScheduleRequest: Sendable {
    public var id: UUID
    public var duration: Int
    public var explicitStart: Int?
    public init(id: UUID, duration: Int, explicitStart: Int? = nil) { self.id = id; self.duration = duration; self.explicitStart = explicitStart }
}
public struct ScheduleSuggestion: Sendable {
    public var id: UUID
    public var start: Int?
    public var reason: String?
}
public struct CalendarLane: Identifiable, Sendable {
    public var id: String
    public var start: Int
    public var end: Int
    public var lane: Int
    public var laneCount: Int
}
public enum SchedulingEngine {
    /// Convert timeline coordinates to wall-clock minutes. Local events must
    /// fit within their day, while tasks can continue into the following day.
    public static func calendarDropStart(y: Double, hourHeight: Double, eventDuration: Int? = nil) -> Int {
        guard y.isFinite, hourHeight.isFinite, hourHeight > 0 else { return 0 }
        let minute = min(1435, max(0, y / hourHeight * 60))
        let snapped = Int((minute / 5).rounded()) * 5
        return min(snapped, 1440 - min(1440, max(1, eventDuration ?? 1)))
    }

    /// All-day selected calendars are busy by default. No source event is modified.
    public static func externalSegment(_ event: ExternalCalendarEvent, on day: LocalDay, calendar: Calendar = .current) -> BusyInterval? {
        if let start = event.startInstant, let end = event.endInstant {
            let midnight = calendar.startOfDay(for: day.date(calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: midnight), start < next, end > midnight, end > start else { return nil }
            if event.isAllDay { return BusyInterval(id: event.id, start: 0, end: 1440) }
            let clippedStart = max(start, midnight), clippedEnd = min(end, next)
            let a = calendar.dateComponents([.hour, .minute], from: clippedStart)
            let b = calendar.dateComponents([.hour, .minute], from: clippedEnd)
            let first = clippedStart == midnight ? 0 : (a.hour ?? 0) * 60 + (a.minute ?? 0)
            let last = clippedEnd == next ? 1440 : (b.hour ?? 0) * 60 + (b.minute ?? 0)
            // During a repeated DST hour, both occurrences must remain unavailable.
            return BusyInterval(id: event.id, start: min(first, last), end: min(1440, max(first + Int(ceil(clippedEnd.timeIntervalSince(clippedStart) / 60)), last)))
        }
        guard event.day == day else { return nil }
        return BusyInterval(id: event.id, start: event.isAllDay ? 0 : event.startMinutes, end: event.isAllDay ? 1440 : event.endMinutes)
    }
    public static func taskSegment(_ task: TaskItem, on day: LocalDay, calendar: Calendar = .current) -> BusyInterval? {
        guard !task.isArchived, !task.isCompleted, let sourceDay = task.scheduledDay, let start = task.scheduledStartMinutes else { return nil }
        let delta = calendar.dateComponents([.day], from: sourceDay.date(calendar: calendar), to: day.date(calendar: calendar)).day ?? 0
        let first = start - delta * 1440, last = first + (task.scheduledDurationMinutes ?? task.estimatedMinutes)
        guard first < 1440, last > 0 else { return nil }
        return BusyInterval(id: task.id.uuidString, start: max(0, first), end: min(1440, last))
    }
    public static func busyIntervals(data: LifeBoardData, day: LocalDay, excluding: Set<UUID> = [], calendar: Calendar = .current) -> [BusyInterval] {
        let tasks = data.tasks.filter { !excluding.contains($0.id) }.compactMap { taskSegment($0, on: day, calendar: calendar) }
        let events = data.events.compactMap { event -> BusyInterval? in
            let delta = calendar.dateComponents([.day], from: event.day.date(calendar: calendar), to: day.date(calendar: calendar)).day ?? 0
            let start = event.startMinutes - delta * 1440, end = event.endMinutes - delta * 1440
            guard start < 1440, end > 0 else { return nil }
            return BusyInterval(id: event.id.uuidString, start: max(0, start), end: min(1440, end))
        }
        return tasks + events + data.externalEvents.compactMap { externalSegment($0, on: day, calendar: calendar) }
    }
    public static func suggest(_ requests: [ScheduleRequest], busy: [BusyInterval], windowStart: Int, hardStop: Int, breakMinutes: Int, notBefore: Int = 0) -> [ScheduleSuggestion] {
        var occupied = busy
        var suggestions: [ScheduleSuggestion] = []
        let lower = max(0, windowStart, notBefore), upper = min(1440, hardStop), rest = max(0, breakMinutes)
        for request in requests {
            guard request.duration > 0 else { suggestions.append(.init(id: request.id, reason: "Duration must be positive")); continue }
            var candidate = request.explicitStart ?? lower
            func clashes(_ start: Int) -> [BusyInterval] { occupied.filter { start < $0.end + rest && start + request.duration + rest > $0.start } }
            if request.explicitStart == nil {
                while let blockingEnd = clashes(candidate).map({ $0.end + rest }).max() { candidate = blockingEnd }
            }
            let reason: String? = candidate < lower ? "This time is in the past or outside the planning window" : candidate + request.duration > upper ? "Full duration does not fit before the hard stop" : !clashes(candidate).isEmpty ? "This time conflicts with another item or its break" : nil
            if let reason { suggestions.append(.init(id: request.id, reason: reason)) }
            else { suggestions.append(.init(id: request.id, start: candidate)); occupied.append(.init(id: request.id.uuidString, start: candidate, end: candidate + request.duration)) }
        }
        return suggestions
    }
    public static func suggest(_ requests: [ScheduleRequest], data: LifeBoardData, day: LocalDay, now: Date = .now, windowStart: Int? = nil, hardStop: Int? = nil) -> [ScheduleSuggestion] {
        let nowDay = LocalDay(now)
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        let minimum = day < nowDay ? 1440 : day == nowDay ? (parts.hour ?? 0) * 60 + (parts.minute ?? 0) + ((parts.second ?? 0) > 0 ? 1 : 0) : 0
        return suggest(requests, busy: busyIntervals(data: data, day: day, excluding: Set(requests.map(\.id))), windowStart: windowStart ?? data.settings.eveningStartMinutes, hardStop: hardStop ?? data.settings.eveningEndMinutes, breakMinutes: data.settings.breakMinutes, notBefore: minimum)
    }
    /// Lanes are allocated per connected overlap group, so independent items keep full width.
    public static func lanes(_ intervals: [BusyInterval]) -> [CalendarLane] {
        let sorted = intervals.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        var output: [CalendarLane] = [], group: [CalendarLane] = [], ends: [Int] = [], groupEnd = -1
        func flush() { let count = max(1, ends.count); output += group.map { var item = $0; item.laneCount = count; return item }; group = []; ends = []; groupEnd = -1 }
        for interval in sorted {
            if interval.start >= groupEnd { flush() }
            let lane = ends.firstIndex { $0 <= interval.start } ?? ends.count
            if lane == ends.count { ends.append(interval.end) } else { ends[lane] = interval.end }
            group.append(.init(id: interval.id, start: interval.start, end: interval.end, lane: lane, laneCount: 1)); groupEnd = max(groupEnd, interval.end)
        }
        flush(); return output
    }
}
