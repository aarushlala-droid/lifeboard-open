import Foundation

struct Fixture: Decodable { var input: String; var title: String; var day: String?; var duration: Int; var priority: String; var subject: String?; var review: Bool }
var data = LifeBoardData()
data.subjects = [Subject(title: "Geography"), Subject(title: "Mathematics"), Subject(title: "Chemistry")]
let reference = LocalDay(year: 2026, month: 10, day: 3)
let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
for fixture in fixtures {
    let draft = NaturalLanguageTaskParser.parse(fixture.input, referenceDay: reference, data: data)[0]
    precondition(draft.title == fixture.title, "Title: \(draft.title) != \(fixture.title)")
    precondition(draft.targetDay?.id == fixture.day)
    precondition(draft.estimatedMinutes == fixture.duration && draft.priority.rawValue == fixture.priority)
    precondition(data.subjects.first { $0.id == draft.subjectID }?.title == fixture.subject)
    precondition(draft.needsReview == fixture.review)
}
precondition(LocalDay(iso: "2026-02-31") == nil)
let ids = (0..<3).map { _ in UUID() }
let plan = SchedulingEngine.suggest([.init(id: ids[0], duration: 90), .init(id: ids[1], duration: 30), .init(id: ids[2], duration: 90)], busy: [.init(start: 1080, end: 1140)], windowStart: 1020, hardStop: 1320, breakMinutes: 10, notBefore: 1035)
precondition(plan.map(\.start) == [1150, 1035, nil])
let lanes = SchedulingEngine.lanes([.init(id: "a", start: 1140, end: 1200), .init(id: "b", start: 1170, end: 1260), .init(id: "c", start: 1185, end: 1215), .init(id: "d", start: 1410, end: 1440)])
precondition(lanes.map(\.laneCount) == [3, 3, 3, 1])
var task = TaskItem(title: "Overnight")
task.scheduledDay = reference; task.scheduledStartMinutes = 1410; task.estimatedMinutes = 90; task.dueDay = reference.adding(days: 5)
precondition(SchedulingEngine.taskSegment(task, on: reference.adding(days: 1))?.end == 60)
precondition(TaskClassification(task, day: reference.adding(days: 1)).carryOver)
precondition(!TaskClassification(task, day: reference.adding(days: 1)).upcoming)
print("Planning shared corpus, scheduling, lanes, classification and overnight tests passed")
var london = Calendar(identifier: .gregorian)
london.timeZone = TimeZone(identifier: "Europe/London")!
let formatter = ISO8601DateFormatter()
let overnight = ExternalCalendarEvent(id: "overnight", calendarID: "one", calendarTitle: "Production", title: "Night shoot", day: reference, startMinutes: 1410, endMinutes: 1440, isAllDay: false, startInstant: formatter.date(from: "2026-10-03T22:30:00Z"), endInstant: formatter.date(from: "2026-10-05T08:00:00Z"), timeZoneIdentifier: "Europe/London")
precondition(SchedulingEngine.externalSegment(overnight, on: reference.adding(days: 1), calendar: london)?.end == 1440)
let autumn = ExternalCalendarEvent(id: "dst", calendarID: "one", calendarTitle: "Work", title: "Repeated hour", day: LocalDay(year: 2026, month: 10, day: 25), startMinutes: 90, endMinutes: 135, isAllDay: false, startInstant: formatter.date(from: "2026-10-25T00:30:00Z"), endInstant: formatter.date(from: "2026-10-25T01:45:00Z"), timeZoneIdentifier: "Europe/London")
let segment = SchedulingEngine.externalSegment(autumn, on: autumn.day, calendar: london)!
precondition(segment.start == 90 && segment.end >= 165)
let full = SchedulingEngine.suggest([ScheduleRequest(id: UUID(), duration: 30)], busy: [.init(start: 0, end: 1440)], windowStart: 1020, hardStop: 1320, breakMinutes: 10)
precondition(full[0].start == nil)
print("All-day/multi-day/DST/full-calendar occupancy passed")
