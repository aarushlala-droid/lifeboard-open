import Foundation
import LifeBoardCore

// Week-view data work per redraw: the previous per-view scans versus the
// PlannerIndex (built once per change, per-day agendas memoised). Synthetic data.
func measure(_ label: String, _ n: Int = 15, _ work: () -> Int) {
    var t: [Double] = []; var sink = 0
    for _ in 0..<n { let s = DispatchTime.now().uptimeNanoseconds; sink &+= work(); t.append(Double(DispatchTime.now().uptimeNanoseconds - s) / 1e6) }
    t.sort()
    print(label.padding(toLength: 52, withPad: " ", startingAt: 0) + String(format: "median %7.2f ms   max %7.2f ms", t[t.count / 2], t.last!) + (sink == 42 ? "" : ""))
}

let calendar = Calendar.current
let today = LocalDay.today
var data = LifeBoardData.seeded()
data.tasks = (0..<150).map { i in
    var t = TaskItem(title: "Task \(i)")
    t.isCompleted = i % 3 == 0
    if i % 2 == 0 { t.scheduledDay = today.adding(days: i % 14 - 4); if i % 4 == 0 { t.scheduledStartMinutes = 960 + (i % 6) * 30; t.scheduledDurationMinutes = 30 } }
    t.dueDay = i % 5 == 0 ? today.adding(days: i % 10) : nil
    return t
}
data.events = (0..<20).map { CalendarEvent(title: "Event \($0)", day: today.adding(days: $0 % 10), startMinutes: 1080, endMinutes: 1140) }
var external: [ExternalCalendarEvent] = []
for offset in -60...365 {
    let day = today.adding(days: offset)
    let weekday = calendar.component(.weekday, from: day.date())
    guard (2...6).contains(weekday) else { continue }
    for lesson in 0..<2 {
        let start = calendar.date(bySettingHour: 9 + lesson * 2, minute: 0, second: 0, of: day.date())!
        external.append(ExternalCalendarEvent(id: "e-\(offset)-\(lesson)", calendarID: "c", calendarTitle: "School", title: "Lesson", day: day, startMinutes: (9 + lesson * 2) * 60, endMinutes: (10 + lesson * 2) * 60, isAllDay: false, startInstant: start, endInstant: start.addingTimeInterval(3600), timeZoneIdentifier: calendar.timeZone.identifier))
    }
}
data.externalEvents = external
let days = WeekMath.days(of: today, mondayFirst: true)
print("tasks \(data.tasks.count), connected events \(data.externalEvents.count)")

// The previous WeekCalendar: each column, band and block scanned every record.
measure("previous: week view data per redraw") {
    var total = 0
    total += days.map { day in data.tasks.filter { !$0.isCompleted && $0.scheduledDay == day && $0.scheduledStartMinutes == nil }.count }.max() ?? 0
    total += data.externalEvents.contains { event in event.isAllDay && days.contains { SchedulingEngine.externalSegment(event, on: $0) != nil } } ? 1 : 0
    for day in days {
        total += data.tasks.filter { !$0.isCompleted && $0.scheduledDay == day && $0.scheduledStartMinutes == nil }.prefix(3).count
        total += data.externalEvents.filter { $0.isAllDay && SchedulingEngine.externalSegment($0, on: day) != nil }.count
        let allDay = Set(data.externalEvents.lazy.filter(\.isAllDay).map(\.id))
        let lanes = SchedulingEngine.lanes(SchedulingEngine.busyIntervals(data: data, day: day).filter { !allDay.contains($0.id) })
        for lane in lanes {
            if data.tasks.first(where: { $0.id.uuidString == lane.id }) != nil { total += 1 }
            else if data.events.first(where: { $0.id.uuidString == lane.id }) != nil { total += 2 }
            else if data.externalEvents.first(where: { $0.id == lane.id }) != nil { total += 3 }
        }
    }
    return total
}

MainActor.assumeIsolated {
    measure("overhaul: rebuild index + 7 agendas + lookups") {
        let index = PlannerIndex(data: data)
        var total = 0
        for day in days {
            let agenda = index.agenda(for: day)
            total += agenda.untimedTasks.count + agenda.allDay.count
            for lane in agenda.lanes {
                if let id = UUID(uuidString: lane.id), index.tasksByID[id] != nil { total += 1 }
                else if let id = UUID(uuidString: lane.id), index.eventsByID[id] != nil { total += 2 }
                else if index.externalByID[lane.id] != nil { total += 3 }
            }
        }
        return total
    }
    let index = PlannerIndex(data: data)
    for day in days { _ = index.agenda(for: day) }
    measure("overhaul: redraw with no data change (memoised)") {
        var total = 0
        for day in days { total += index.agenda(for: day).lanes.count }
        return total
    }
}
