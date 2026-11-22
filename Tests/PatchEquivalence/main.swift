@_spi(Testing) import LifeBoardCore
import Foundation

// The pruned diff and record-scoped apply must be indistinguishable from the
// original whole-document algorithms. Randomised, seeded and synthetic only.
func require(_ condition: Bool, _ message: String) {
    guard condition else { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
}

struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state &+= 0x9E3779B97F4A7C15; var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
}

let encoder = LifeBoardJSON.encoder(); encoder.outputFormatting = [.sortedKeys]
func canonical(_ data: LifeBoardData) -> Data { (try? encoder.encode(data)) ?? Data() }
/// Undo re-appends a deleted record at the end (original behaviour), so the
/// Undo round trip is compared without record order.
func unordered(_ data: LifeBoardData) -> Data {
    var d = data
    d.tasks.sort { $0.id.uuidString < $1.id.uuidString }; d.events.sort { $0.id.uuidString < $1.id.uuidString }
    d.activity.sort { $0.id.uuidString < $1.id.uuidString }; d.externalEvents.sort { $0.id < $1.id }
    for i in d.subjects.indices { d.subjects[i].topics.sort { $0.id.uuidString < $1.id.uuidString } }
    return canonical(d)
}

func base() -> LifeBoardData {
    var d = LifeBoardData.seeded()
    let day = LocalDay(year: 2026, month: 3, day: 29) // a daylight-saving change in the UK
    d.subjects[0].topics = [Topic(title: "Algebra"), Topic(title: "Geometry")]
    d.projects[0].milestones = [ProjectMilestone(title: "Draft", targetDay: day)]
    d.tasks = (0..<40).map { i in
        var t = TaskItem(title: "Task \(i)")
        t.isCompleted = i % 3 == 0; t.dueDay = i % 4 == 0 ? day.adding(days: i % 7) : nil
        if i % 5 == 0 { t.scheduledDay = day; t.scheduledStartMinutes = 600 + i; t.scheduledDurationMinutes = 30 }
        if i % 6 == 0 { t.subtasks = [TaskSubtask(title: "Step A"), TaskSubtask(title: "Step B")] }
        t.subjectID = i % 2 == 0 ? d.subjects[0].id : nil
        t.tags = i % 7 == 0 ? ["workflow:next"] : []
        return t
    }
    d.events = (0..<6).map { CalendarEvent(title: "Event \($0)", day: day.adding(days: $0), startMinutes: 540, endMinutes: 600) }
    d.externalEvents = (0..<12).map { ExternalCalendarEvent(id: String(format: "%064x", $0), calendarID: "c", calendarTitle: "School", title: "Lesson \($0)", day: day, startMinutes: 480, endMinutes: 540, isAllDay: $0 == 0) }
    d.activity = (0..<10).map { ActivityRecord(kind: .taskCompleted, title: "Completed \($0)") }
    return d
}

func mutate(_ data: inout LifeBoardData, _ rng: inout SeededRandom) {
    switch Int.random(in: 0..<12, using: &rng) {
    case 0: if !data.tasks.isEmpty { data.tasks[Int.random(in: 0..<data.tasks.count, using: &rng)].title = "Edited \(rng.next() % 1000)" }
    case 1: if !data.tasks.isEmpty { let i = Int.random(in: 0..<data.tasks.count, using: &rng); data.tasks[i].isCompleted.toggle(); data.tasks[i].completionPercent = data.tasks[i].isCompleted ? 100 : 0 }
    case 2: data.tasks.append(TaskItem(title: "New \(rng.next() % 1000)"))
    case 3: if data.tasks.count > 1 { data.tasks.remove(at: Int.random(in: 0..<data.tasks.count, using: &rng)) }
    case 4: data.settings.defaultTaskMinutes = [15, 30, 45][Int.random(in: 0..<3, using: &rng)]
    case 5: data.subjects[0].topics.append(Topic(title: "Topic \(rng.next() % 100)"))
    case 6: data.activity.insert(ActivityRecord(kind: .progressAdded, title: "Note"), at: 0)
    case 7: if !data.externalEvents.isEmpty { data.externalEvents[Int.random(in: 0..<data.externalEvents.count, using: &rng)].title = "Moved lesson" }
    case 8: data.activeFocus = data.activeFocus == nil ? ActiveFocusSession(kind: .focus, taskID: nil, taskTitle: "Focus", plannedMinutes: 25) : nil
    case 9: if let i = data.tasks.indices.randomElement(using: &rng) { data.tasks[i].subtasks = (data.tasks[i].subtasks ?? []) + [TaskSubtask(title: "Added step")] }
    case 10: if let i = data.tasks.indices.randomElement(using: &rng) { data.tasks[i].tags = ["workflow:inProgress"] }
    default: if let i = data.events.indices.randomElement(using: &rng) { data.events[i].startMinutes = 480; data.events[i].endMinutes = 545 }
    }
}

var rng = SeededRandom(state: 20261121)
let template = base()
var checks = 0
for round in 0..<400 {
    let before = template
    var after = before
    for _ in 0..<Int.random(in: 1...4, using: &rng) { mutate(&after, &rng) }
    let pruned = try LifeBoardDataPatch(before: before, after: after)
    let original = try LifeBoardDataPatch(unprunedBefore: before, after: after)
    require(pruned.canonicalOperations == original.canonicalOperations, "round \(round): pruned diff equals the original diff")

    // Apply forward, onto an independently edited copy, and in reverse (Undo).
    var concurrent = before
    concurrent.tasks.append(TaskItem(title: "Concurrent helper import"))
    if !concurrent.events.isEmpty { concurrent.events[0].notes = "Concurrent note" }
    for (label, patch, target) in [("forward", pruned, before), ("concurrent", pruned, concurrent), ("undo", pruned.reversed(), after)] {
        let fast = Result { try patch.applying(to: target) }
        let reference = Result { try patch.applyingToWholeDocument(target) }
        switch (fast, reference) {
        case (.success(let a), .success(let b)): require(canonical(a) == canonical(b), "round \(round) \(label): record-scoped apply equals whole-document apply")
        case (.failure, .failure): break
        default: require(false, "round \(round) \(label): both algorithms agree on success or conflict")
        }
        checks += 1
    }
    if case .success(let undone) = Result(catching: { try pruned.reversed().applying(to: after) }) {
        require(unordered(undone) == unordered(before), "round \(round): Undo restores the original document")
    }
}

// A stale draft must still conflict rather than overwrite.
var stale = template; stale.tasks[1].title = "Changed elsewhere"
var draftBefore = LifeBoardData(); draftBefore.tasks = [template.tasks[1]]
var draftAfter = draftBefore; draftAfter.tasks[0].title = "Local draft"
let draft = try LifeBoardDataPatch(before: draftBefore, after: draftAfter)
require((try? draft.applying(to: stale)) == nil, "stale same-field draft is rejected")
print("PASS: patch equivalence (\(checks) applications, 400 randomised edits)")
