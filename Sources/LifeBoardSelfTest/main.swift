import Foundation
import LifeBoardCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
}

let day = LocalDay(year: 2026, month: 9, day: 21)
require(day.id == "2026-09-21", "LocalDay ISO output")
require(LocalDay(iso: day.id) == day, "LocalDay ISO round trip")
require(day.adding(days: 1) == LocalDay(year: 2026, month: 9, day: 22), "LocalDay arithmetic")

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LifeBoardSelfTest-\(UUID().uuidString)")
let repository = LifeBoardRepository(fileURL: folder.appendingPathComponent("data.json"), iCloudBackupDirectory: folder.appendingPathComponent("iCloud"))
var data = LifeBoardData.seeded()
require(data.tasks.isEmpty && data.events.isEmpty && data.yearMarkers.isEmpty, "fresh workspace contains no personal work")
require(data.externalEvents.isEmpty && data.focusSessions.isEmpty && data.activity.isEmpty, "fresh workspace contains no personal history")
require(!data.settings.hasCompletedOnboarding && data.settings.selectedExternalCalendarIDs.isEmpty, "fresh install asks for onboarding and calendar selection")
if let chemistry = data.subjects.firstIndex(where: { $0.title == "Chemistry" }) { data.subjects[chemistry].topics.append(Topic(title: "Moles")) }
var task = TaskItem(title: "Chemistry worksheet")
task.estimatedMinutes = 30
task.dueDay = LocalDay.today.adding(days: 1)
task.subjectID = data.subjects.first(where: { $0.title == "Chemistry" })?.id
task.completionPercent = 35
data.tasks.append(task)
try repository.save(data)
let restored = repository.load()
require(restored.tasks.first?.title == "Chemistry worksheet", "persistence title round trip")
require(restored.tasks.first?.scheduledDay == nil, "unscheduled state persists")
require(restored.tasks.first?.dueDay == LocalDay.today.adding(days: 1), "due date persists")
require(restored.tasks.first?.completionPercent == 35, "task completion progress persists")

let json = #"{"title":"Chemistry moles worksheet","estimatedMinutes":35,"dueDate":"2026-09-22","scheduledDate":"2026-09-21","scheduledStart":null,"priority":"high","subject":"Chemistry","topic":"Moles","project":null}"#
let imported = try repository.makeTask(from: repository.decodePayload(json), in: data)
require(imported.dueDay == LocalDay(year: 2026, month: 9, day: 22), "import due date")
require(imported.scheduledDay == LocalDay(year: 2026, month: 9, day: 21), "import scheduled day")
require(imported.scheduledStartMinutes == nil, "import untimed schedule")
require(imported.subjectID != nil, "import subject link")
require(imported.topicID != nil, "import topic link")

let batchJSON = #"[{"title":"Physics questions","scheduledDate":"2026-09-23"},{"title":"Quotation review","scheduledDate":"2026-09-23","scheduledStart":"18:15"}]"#
let batch = try repository.decodePayloads(batchJSON)
require(batch.count == 2, "batch import decoding")
let untimedBatchTask = try repository.makeTask(from: batch[0], in: data)
let timedBatchTask = try repository.makeTask(from: batch[1], in: data)
require(untimedBatchTask.scheduledStartMinutes == nil, "batch preserves untimed scheduling")
require(timedBatchTask.scheduledStartMinutes == 18 * 60 + 15, "batch timed scheduling")

let captureText = """
chem worksheet tomorrow 30m
english essay friday 45m
research project intro tonight
history revision sometime this week
"""
let captured = NaturalLanguageTaskParser.parse(captureText, referenceDay: day, data: data)
require(captured.count == 4, "multiline natural-language capture")
require(captured[0].estimatedMinutes == 30 && captured[0].targetDay == day.adding(days: 1), "capture duration and tomorrow")
require(captured[0].subjectID == data.subjects.first(where: { $0.title == "Chemistry" })?.id, "capture subject alias")
require(captured[1].estimatedMinutes == 45 && captured[1].subjectID == data.subjects.first(where: { $0.title == "English Language" })?.id, "capture English association")
require(captured.allSatisfy { $0.startMinutes == nil }, "capture never invents exact times")
let nextWeek = NaturalLanguageTaskParser.parse("Plan coursework next week", referenceDay: day, data: data)
require(nextWeek.first?.targetDay == day.adding(days: 7), "capture resolves next week")
let suggested = NaturalLanguageTaskParser.suggestedSchedule(for: captured, data: data, referenceDay: day, now: day.date())
require(suggested.count == captured.count && suggested.allSatisfy { $0.startMinutes != nil }, "schedule preview supplies optional times")

var active = ActiveFocusSession(kind: .focus, taskID: task.id, taskTitle: task.title, subjectID: task.subjectID, plannedMinutes: 25)
active.startedAt = Date.now.addingTimeInterval(-10 * 60)
let focusRecord = FocusSessionRecord(from: active, completedTimer: false)
require(focusRecord.focusedSeconds >= 599, "focus session records elapsed work")
data.focusSessions = [focusRecord]

let widgetNow = day.date()
var widgetTask = TaskItem(title: "Widget next item")
widgetTask.scheduledDay = day
widgetTask.scheduledStartMinutes = 17 * 60 + 30
data.tasks.append(widgetTask)
let widget = LifeBoardWidgetSnapshot(data: data, now: widgetNow)
require(widget.agenda.first?.title == "Widget next item", "widget shows next scheduled item")
require(widget.remainingToDos == data.tasks.filter { !$0.isCompleted && !$0.isArchived }.count, "widget To Do count")
require(widget.toDos.contains { $0.id == task.id && $0.completionPercent == 35 }, "widget shows real To Dos and progress")

let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
let currentBytes = try encoder.encode(data)
var legacyObject = try JSONSerialization.jsonObject(with: currentBytes) as! [String: Any]
legacyObject.removeValue(forKey: "schemaVersion")
legacyObject.removeValue(forKey: "focusSessions")
legacyObject.removeValue(forKey: "activeFocus")
legacyObject.removeValue(forKey: "externalEvents")
if var tasks = legacyObject["tasks"] as? [[String: Any]] {
    for index in tasks.indices { tasks[index].removeValue(forKey: "completionPercent") }
    legacyObject["tasks"] = tasks
}
let legacyBytes = try JSONSerialization.data(withJSONObject: legacyObject)
let migrated = try decoder.decode(LifeBoardData.self, from: legacyBytes)
require(migrated.tasks.count == data.tasks.count, "v1 data migrates without loss")
require(migrated.focusSessions.isEmpty && migrated.activeFocus == nil, "v1 focus defaults migrate")
require(migrated.schemaVersion == 3 && migrated.externalEvents.isEmpty, "legacy data upgrades safely to schema 3")
require(migrated.tasks.first?.completionPercent == nil, "old tasks decode without progress")

var macEdit = data
macEdit.tasks[0].scheduledDay = day
var phoneEdit = data
phoneEdit.tasks[1].isCompleted = true
let disjointMerge = try LifeBoardSyncMerge.merge(base: data, local: macEdit, remote: phoneEdit)
require(disjointMerge.conflicts.isEmpty, "independent edits merge")
require(disjointMerge.data?.tasks.first(where: { $0.id == task.id })?.scheduledDay == day, "Mac schedule survives merge")
require(disjointMerge.data?.tasks.first(where: { $0.id == widgetTask.id })?.isCompleted == true, "phone completion survives merge")
phoneEdit = data
phoneEdit.tasks[0].title = "Changed on phone"
let conflictMerge = try LifeBoardSyncMerge.merge(base: data, local: macEdit, remote: phoneEdit)
require(conflictMerge.data?.tasks.first?.title == "Changed on phone" && conflictMerge.data?.tasks.first?.scheduledDay == day, "independent fields on one task merge")
macEdit.tasks[0].title = "Changed on Mac"
let sameFieldConflict = try LifeBoardSyncMerge.merge(base: data, local: macEdit, remote: phoneEdit)
require(sameFieldConflict.data == nil && sameFieldConflict.conflicts.count == 1, "same-field edits stop without data loss")

let backupURL = folder.appendingPathComponent("backup.json")
try repository.export(data, to: backupURL)
let restoredBackup = try repository.importBackup(from: backupURL)
require(restoredBackup.subjects.count == 9, "backup round trip")
let cloudBackup = try repository.exportToICloud(data, retain: 3)
require(FileManager.default.fileExists(atPath: cloudBackup.path), "automatic iCloud backup export")

try? FileManager.default.removeItem(at: folder)
print("LifeBoard core self-test passed")
