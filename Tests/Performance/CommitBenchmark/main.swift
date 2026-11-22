import Foundation
import LifeBoardCore

// Measures the per-action persistence cost on a synthetic workspace about the
// size of a real student year (roughly 250 KB). No personal data is read.
// BENCH_SCALE=0.3 approximates a 250 KB planner; 1.0 is about 820 KB.
let scale = Double(ProcessInfo.processInfo.environment["BENCH_SCALE"] ?? "1") ?? 1
func scaled(_ count: Int) -> Int { max(1, Int(Double(count) * scale)) }

func synthetic() -> LifeBoardData {
    var d = LifeBoardData.seeded()
    let today = LocalDay.today
    for s in d.subjects.indices { d.subjects[s].topics = (0..<12).map { Topic(title: "Topic \($0) of \(d.subjects[s].title)") } }
    d.tasks = (0..<scaled(420)).map { i in
        var t = TaskItem(title: "Synthetic task \(i) revise chapter \(i % 17)")
        t.notes = i % 3 == 0 ? String(repeating: "note ", count: 30) : ""
        t.estimatedMinutes = [15, 30, 45, 60][i % 4]
        t.isCompleted = i % 2 == 0; t.completedAt = t.isCompleted ? .now : nil
        t.dueDay = i % 4 == 0 ? today.adding(days: i % 20 - 5) : nil
        if i % 3 == 0 { t.scheduledDay = today.adding(days: i % 10 - 3); if i % 6 == 0 { t.scheduledStartMinutes = 900 + (i % 8) * 30; t.scheduledDurationMinutes = 30 } }
        t.subjectID = d.subjects[i % d.subjects.count].id
        if i % 5 == 0 { t.subtasks = (0..<4).map { TaskSubtask(title: "Step \($0)") } }
        return t
    }
    d.externalEvents = (0..<scaled(700)).map { i in
        let day = today.adding(days: i % 300 - 60)
        let start = Calendar.current.date(bySettingHour: 9 + i % 8, minute: 0, second: 0, of: day.date())!
        return ExternalCalendarEvent(id: String(format: "%064x", i), calendarID: "cal-\(i % 3)", calendarTitle: "School", title: "Lesson \(i)", day: day, startMinutes: (9 + i % 8) * 60, endMinutes: (10 + i % 8) * 60, isAllDay: false, location: "Room \(i % 30)", notes: "", startInstant: start, endInstant: start.addingTimeInterval(3600), timeZoneIdentifier: "Europe/London")
    }
    d.activity = (0..<scaled(350)).map { ActivityRecord(kind: .taskCompleted, title: "Completed \"Synthetic task \($0)\"") }
    d.focusSessions = (0..<scaled(80)).map { i in
        var a = ActiveFocusSession(kind: .focus, taskID: nil, taskTitle: "Focus \(i)", plannedMinutes: 25)
        a.startedAt = .now.addingTimeInterval(Double(-i * 4000))
        return FocusSessionRecord(from: a, endedAt: a.startedAt.addingTimeInterval(1500), completedTimer: true)
    }
    d.settings.hasCompletedOnboarding = true
    return d
}

func measure(_ label: String, _ n: Int = 9, _ work: () throws -> Void) rethrows {
    var t: [Double] = []
    for _ in 0..<n { let s = DispatchTime.now().uptimeNanoseconds; try work(); t.append(Double(DispatchTime.now().uptimeNanoseconds - s) / 1e6) }
    t.sort()
    print(label.padding(toLength: 46, withPad: " ", startingAt: 0) + String(format: "median %7.2f ms   max %7.2f ms", t[t.count / 2], t.last!))
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lb-bench-\(UUID().uuidString)")
setenv("LIFEBOARD_DATA_PATH", dir.appendingPathComponent("LifeBoard.json").path, 1)
defer { try? FileManager.default.removeItem(at: dir) }
let repo = LifeBoardRepository(fileURL: dir.appendingPathComponent("LifeBoard.json"), iCloudBackupDirectory: dir.appendingPathComponent("cloud"))
var data = synthetic()
try repo.save(data); data = try repo.loadThrowing()
let bytes = try Data(contentsOf: repo.fileURL)
print("document bytes: \(bytes.count)  tasks: \(data.tasks.count)  external events: \(data.externalEvents.count)")
let encoder = LifeBoardJSON.encoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try measure("encode (pretty, sorted)") { _ = try encoder.encode(data) }
try measure("LifeBoardValidation.decode") { _ = try LifeBoardValidation.decode(bytes) }
try measure("LifeBoardValidation.validate") { try LifeBoardValidation.validate(data) }
try measure("atomic write + fsync") { try LifeBoardPrivateFiles.write(bytes, to: dir.appendingPathComponent("copy.json")) }
var toggled = data; toggled.tasks[1].isCompleted.toggle()
try measure("undo patch diff (one toggle)") { _ = try LifeBoardDataPatch(before: data, after: toggled) }
var flip = false
try measure("repository.saveReturning (one toggle)") { flip.toggle(); var n = data; n.tasks[1].isCompleted = flip; _ = try repo.saveReturning(n) }
try measure("widget snapshot write") { _ = try LifeBoardSharedStore.writeSnapshot(data) }
try measure("whole commit path (patch + save + snapshot)") {
    flip.toggle(); var n = data; n.tasks[1].isCompleted = flip
    _ = try LifeBoardDataPatch(before: data, after: n)
    let durable = try repo.saveReturning(n)
    _ = try LifeBoardSharedStore.writeSnapshot(durable)
}
try measure("three-way merge (sync tick)", 3) { _ = try LifeBoardSyncMerge.merge(base: data, local: toggled, remote: data) }
// The inspector applies a one-task draft to the workspace on each save.
var draftBefore = LifeBoardData(); draftBefore.tasks = [data.tasks[3]]
var draftAfter = draftBefore; draftAfter.tasks[0].title += " edited"
let draft = try LifeBoardDataPatch(before: draftBefore, after: draftAfter)
try measure("inspector draft apply (one task)") { _ = try draft.applying(to: data) }
