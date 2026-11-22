import Foundation
import LifeBoardCore

// Calendar positioning across daylight-saving changes and time zones.
func require(_ condition: Bool, _ message: String) {
    guard condition else { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
    print("PASS: \(message)")
}
func calendar(_ zone: String) -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }
func instant(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

let london = calendar("Europe/London")
let springForward = LocalDay(year: 2026, month: 3, day: 29)   // 01:00 GMT becomes 02:00 BST
let fallBack = LocalDay(year: 2026, month: 10, day: 25)       // 02:00 BST becomes 01:00 GMT

// Calendar days, not 24-hour steps.
require(springForward.adding(days: -1, calendar: london) == LocalDay(year: 2026, month: 3, day: 28) && springForward.adding(days: 1, calendar: london) == LocalDay(year: 2026, month: 3, day: 30), "adding days crosses the spring change without skipping or repeating a day")
require(fallBack.adding(days: 1, calendar: london) == LocalDay(year: 2026, month: 10, day: 26) && fallBack.adding(days: 7, calendar: london) == LocalDay(year: 2026, month: 11, day: 1), "adding days crosses the autumn change")
require(LocalDay(springForward.date(calendar: london), calendar: london) == springForward, "a day's noon anchor maps back to the same day on a 23-hour day")

// Weeks honour the Monday/Sunday setting, including across the change.
require(WeekMath.start(of: springForward, mondayFirst: true, calendar: london) == LocalDay(year: 2026, month: 3, day: 23), "Monday-first week containing the spring Sunday starts on Monday 23 March")
require(WeekMath.start(of: springForward, mondayFirst: false, calendar: london) == springForward, "Sunday-first week starts on that Sunday")
require(WeekMath.days(of: fallBack, mondayFirst: true).count == 7 && Set(WeekMath.days(of: fallBack, mondayFirst: true)).count == 7, "a week over the autumn change has seven distinct days")
require(WeekMath.weekdaySymbols(mondayFirst: true).count == 7, "weekday symbols match the week")

// Connected-calendar events keep their real instants and land on the wall clock.
let spring = ExternalCalendarEvent(id: "spring", calendarID: "c", calendarTitle: "School", title: "Overnight", day: springForward, startMinutes: 30, endMinutes: 210, isAllDay: false,
                                   startInstant: instant("2026-03-29T00:30:00Z"), endInstant: instant("2026-03-29T02:30:00Z"), timeZoneIdentifier: "Europe/London")
let springSegment = SchedulingEngine.externalSegment(spring, on: springForward, calendar: london)
require(springSegment?.start == 30 && springSegment?.end == 210, "a two-hour event over the spring change spans 00:30 to 03:30 on the clock")

let autumn = ExternalCalendarEvent(id: "autumn", calendarID: "c", calendarTitle: "School", title: "Repeated hour", day: fallBack, startMinutes: 30, endMinutes: 90, isAllDay: false,
                                   startInstant: instant("2026-10-24T23:30:00Z"), endInstant: instant("2026-10-25T01:30:00Z"), timeZoneIdentifier: "Europe/London")
let autumnSegment = SchedulingEngine.externalSegment(autumn, on: fallBack, calendar: london)
require(autumnSegment?.start == 30 && (autumnSegment?.end ?? 0) >= 150, "both occurrences of the repeated autumn hour stay busy")

let lateLesson = ExternalCalendarEvent(id: "late", calendarID: "c", calendarTitle: "School", title: "Late", day: LocalDay(year: 2026, month: 11, day: 20), startMinutes: 1380, endMinutes: 1440, isAllDay: false,
                                       startInstant: instant("2026-11-20T23:00:00Z"), endInstant: instant("2026-11-21T01:00:00Z"), timeZoneIdentifier: "Europe/London")
require(SchedulingEngine.externalSegment(lateLesson, on: LocalDay(year: 2026, month: 11, day: 20), calendar: london).map { [$0.start, $0.end] } == [1380, 1440], "an event crossing midnight fills the end of its first day")
require(SchedulingEngine.externalSegment(lateLesson, on: LocalDay(year: 2026, month: 11, day: 21), calendar: london).map { [$0.start, $0.end] } == [0, 60], "and continues at the start of the next day")
require(SchedulingEngine.externalSegment(lateLesson, on: LocalDay(year: 2026, month: 11, day: 22), calendar: london) == nil, "and is absent on the day after")

// Travelling: the same instant moves on the wall clock with the time zone.
let lesson = ExternalCalendarEvent(id: "tz", calendarID: "c", calendarTitle: "School", title: "Lesson", day: LocalDay(year: 2026, month: 11, day: 23), startMinutes: 840, endMinutes: 900, isAllDay: false,
                                   startInstant: instant("2026-11-23T14:00:00Z"), endInstant: instant("2026-11-23T15:00:00Z"), timeZoneIdentifier: "Europe/London")
require(SchedulingEngine.externalSegment(lesson, on: LocalDay(year: 2026, month: 11, day: 23), calendar: calendar("Europe/Paris"))?.start == 900, "14:00 UTC shows at 15:00 in Paris")
require(SchedulingEngine.externalSegment(lesson, on: LocalDay(year: 2026, month: 11, day: 23), calendar: calendar("America/New_York"))?.start == 540, "and at 09:00 in New York")

// Tasks are wall-clock plans: 17:00 stays 17:00 whatever the offset.
var task = TaskItem(title: "Revise"); task.scheduledDay = springForward; task.scheduledStartMinutes = 17 * 60; task.scheduledDurationMinutes = 45
require(SchedulingEngine.taskSegment(task, on: springForward, calendar: london).map { [$0.start, $0.end] } == [1020, 1065], "a planned task keeps its clock time on a 23-hour day")
task.scheduledDay = springForward.adding(days: -1, calendar: london); task.scheduledStartMinutes = 23 * 60 + 30; task.scheduledDurationMinutes = 90
require(SchedulingEngine.taskSegment(task, on: springForward, calendar: london).map { [$0.start, $0.end] } == [0, 60], "a late task continues past midnight into the change day")

// All-day connected events occupy the whole local day only.
let start = london.startOfDay(for: fallBack.date(calendar: london))
let allDay = ExternalCalendarEvent(id: "allday", calendarID: "c", calendarTitle: "School", title: "Trip", day: fallBack, startMinutes: 0, endMinutes: 1440, isAllDay: true,
                                   startInstant: start, endInstant: london.date(byAdding: .day, value: 1, to: start), timeZoneIdentifier: "Europe/London")
require(SchedulingEngine.externalSegment(allDay, on: fallBack, calendar: london).map { [$0.start, $0.end] } == [0, 1440], "an all-day event on the 25-hour day covers the day")
require(SchedulingEngine.externalSegment(allDay, on: fallBack.adding(days: 1, calendar: london), calendar: london) == nil, "and does not spill into the next day")
print("PASS: calendar and time-zone behaviour")
