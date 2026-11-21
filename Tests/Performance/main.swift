import Foundation
import Dispatch

struct Measurement: Codable {
    let engine: String
    let operation: String
    let nominalRecords: Int
    let actualCalendarRecords: Int
    let samples: Int
    let minimumMS: Double
    let medianMS: Double
    let p95MS: Double
    let budgetMS: Double
    let budgetPassed: Bool
    let checksum: Int
}
let reference = LocalDay(year: 2026, month: 10, day: 3)
let fixedNow = ISO8601DateFormatter().date(from: "2026-10-03T15:00:00Z")!
let repetitions = 5
var measurements: [Measurement] = []
func measure(_ operation: String, records: Int, actual: Int, budget: Double, work: () throws -> Int) rethrows {
    _ = try work()
    var timings: [Double] = [], checksum = 0
    for _ in 0..<repetitions {
        let start = DispatchTime.now().uptimeNanoseconds
        checksum += try work()
        timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    timings.sort()
    measurements.append(.init(engine: "Swift -O", operation: operation, nominalRecords: records, actualCalendarRecords: actual, samples: repetitions, minimumMS: timings.first!, medianMS: timings[timings.count / 2], p95MS: timings.last!, budgetMS: budget, budgetPassed: timings.last! <= budget, checksum: checksum))
}
func fixture(_ count: Int) -> LifeBoardData {
    var data = LifeBoardData()
    data.tasks = (0..<count).map { index in
        var task = TaskItem(title: "Synthetic revision task \(index)")
        task.estimatedMinutes = [30, 45, 60, 90][index % 4]
        task.priority = [.none, .low, .medium, .high][index % 4]
        task.dueDay = reference.adding(days: index % 9 - 2)
        task.isCompleted = index % 11 == 0; task.isArchived = index % 23 == 0
        if index % 5 != 0 { task.scheduledDay = reference.adding(days: index % 7 - 2); task.scheduledStartMinutes = 390 + (index % 60) * 15 }
        return task
    }
    data.events = (0..<max(1, count / 10)).map { index in CalendarEvent(title: "Synthetic lesson \(index)", day: reference.adding(days: index % 7 - 2), startMinutes: 480 + (index % 40) * 15, endMinutes: 540 + (index % 40) * 15) }
    data.externalEvents = (0..<max(1, count / 20)).map { index in
        let day = reference.adding(days: index % 7 - 2)
        return ExternalCalendarEvent(id: "synthetic-\(index)", calendarID: "synthetic", calendarTitle: "Synthetic calendar", title: "Synthetic meeting \(index)", day: day, startMinutes: 600 + (index % 30) * 15, endMinutes: 630 + (index % 30) * 15, isAllDay: index % 29 == 0)
    }
    return data
}
for count in [100, 1_000, 5_000] {
    let data = fixture(count), actual = data.tasks.count + data.events.count + data.externalEvents.count
    let readBudget = count == 100 ? 16.0 : count == 1_000 ? 50.0 : 250.0
    let bulkBudget = count == 100 ? 50.0 : count == 1_000 ? 300.0 : 1_500.0
    let days = (0..<7).map { reference.adding(days: $0) }
    let requests = (0..<count).map { _ in ScheduleRequest(id: UUID(), duration: 30) }
    measure("classification", records: count, actual: actual, budget: readBudget) {
        data.tasks.reduce(0) { result, task in let value = TaskClassification(task, day: reference); return result + (value.today ? 1 : 0) + (value.carryOver ? 2 : 0) + (value.upcoming ? 4 : 0) }
    }
    measure("schedule_full_candidates", records: count, actual: actual, budget: bulkBudget) {
        let plan = SchedulingEngine.suggest(requests, data: data, day: reference, now: fixedNow)
        precondition(plan.count == count)
        return plan.filter { $0.start == nil }.count
    }
    measure("calendar_week_busy_and_lanes", records: count, actual: actual, budget: readBudget) {
        days.reduce(0) { result, day in let lanes = SchedulingEngine.lanes(SchedulingEngine.busyIntervals(data: data, day: day)); return result + lanes.reduce(0) { $0 + $1.laneCount + $1.end - $1.start } }
    }
    let text = (0..<count).map { "\($0 + 1). Synthetic syllabus topic \($0)" }.joined(separator: "\n")
    try measure("topic_parse_and_accept", records: count, actual: actual, budget: bulkBudget) {
        let draft = try TopicImportParser.parse(text, existing: ["Synthetic syllabus topic 0"])
        let accepted = TopicImportParser.accepted(draft, existing: ["Synthetic syllabus topic 0"])
        precondition(accepted.count == count - 1)
        return accepted.count
    }
}
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
print(String(data: try encoder.encode(measurements), encoding: .utf8)!)
