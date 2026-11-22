import AppKit
import Foundation
import LifeBoardCore
import Darwin

#if APPSTORE_SAFETY
// Test doubles isolate production AppStore from live credentials, calendars,
// notifications and network. Its persistence/mutation/backup code is unchanged.
struct ExternalCalendarChoice: Identifiable { let id: String; let title: String; let account: String }
@MainActor final class CalendarIntegrationService {
    static var requestCount = 0
    static var granted = false
    static var choices: [ExternalCalendarChoice] = []
    static var fetched: [ExternalCalendarEvent] = []
    static var queryCount = 0
    static var accountRefreshCount = 0
    static weak var latest: CalendarIntegrationService?
    var onChange: (@MainActor () -> Void)?
    init() { Self.latest = self }
    var hasFullAccess: Bool { Self.granted }
    var accessGuidance: String { "Saved calendar events are kept. Use Settings › Integrations › Connect Calendars." }
    func requestAccess() async -> Bool { Self.requestCount += 1; return false }
    func refreshAccountSources() { Self.accountRefreshCount += 1 }
    func refreshLocalStore() {}
    func colour(forCalendarID id: String) -> NSColor? { nil }
    func availableCalendars() -> [ExternalCalendarChoice] { Self.choices }
    func events(calendarIDs: [String], from start: Date, to end: Date) -> [ExternalCalendarEvent] { Self.queryCount += 1; return Self.fetched.filter { calendarIDs.contains($0.calendarID) } }
    func openInternetAccounts() {}
}
@MainActor final class NotificationCoordinator {
    static let shared = NotificationCoordinator()
    func refresh(_ data: LifeBoardData) {}
    func requestAndRefresh(_ data: LifeBoardData) {}
    func scheduleFocus(_ session: ActiveFocusSession, enabled: Bool) {}
    func cancelFocus() {}
}
enum KanbanStage: String { case backlog, next, inProgress, waiting, done; var tag: String { "workflow:" + rawValue } }
struct SyncBaseline { let revision: Int; let data: LifeBoardData }
struct SyncEnvelope { let revision: Int; let data: LifeBoardData? }
@MainActor enum SyncService {
    struct ConnectedDevice: Identifiable { let id: String; let name: String; let createdAt: String; let expiresAt: String; let managesDevices: Bool }
    struct PairingChallenge { let code: String; let expiresAt: String }
    struct InvitationFile: Decodable { let endpoint: URL; let workspaceID: String; let deviceToken: String }
    static let workspaceIdentityURL = FileManager.default.temporaryDirectory.appendingPathComponent("LifeBoardSafetyUnusedIdentity")
    static var enabled = false
    static var remote = SyncEnvelope(revision: 0, data: nil)
    static var base: SyncBaseline?
    static var writeCount = 0
    static func endpoint() -> URL? { enabled ? URL(string: "https://synthetic.invalid/api/snapshot") : nil }
    static func secret(_ account: String) -> String? { enabled ? "synthetic-never-sent" : nil }
    nonisolated static func requestCredentialAccess() throws {}
    static func baseline() -> SyncBaseline? { base }
    static func saveBaseline(_ baseline: SyncBaseline) throws { base = baseline }
    static func fetch(from endpoint: URL, token: String) async throws -> SyncEnvelope { remote }
    static func save(_ data: LifeBoardData, revision: Int, to endpoint: URL, token: String) async throws -> Int? {
        guard revision == remote.revision else { return nil }
        writeCount += 1; remote = SyncEnvelope(revision: revision + 1, data: data); return remote.revision
    }
    static func listDevices(from endpoint: URL, token: String) async throws -> [ConnectedDevice] { [] }
    static func revokeDevice(id: String, from endpoint: URL, token: String) async throws {}
    static func createChallenge(from endpoint: URL, token: String, deviceName: String = "Phone") async throws -> PairingChallenge { PairingChallenge(code: "synthetic", expiresAt: "synthetic") }
    static func disconnect() throws {}
    static func verifyInvitation(_ invitation: InvitationFile) async throws {}
    static func configureWorkspace(endpoint: URL, deviceToken: String) throws {}
}
#endif

func require(_ condition: Bool, _ message: String) {
    guard condition else { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
    print("PASS: \(message)")
}

// The same binary is also a child-process writer. Barriers ensure every writer
// reads one baseline before any writer commits, making lost updates observable.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--worker" {
    let args = CommandLine.arguments
    let file = URL(fileURLWithPath: args[2]), ready = URL(fileURLWithPath: args[3]), release = URL(fileURLWithPath: args[4])
    let workerRepository = LifeBoardRepository(fileURL: file)
    var workspace = try workerRepository.loadThrowing()
    let token = args[5], operation = args[6]
    if operation == "import" { workspace.tasks.append(TaskItem(title: "Process import " + token)) }
    else if operation == "edit" { workspace.tasks[0].notes = "Process edit " + token }
    else if operation == "same-field" { workspace.tasks[0].title = "Process conflict " + token }
    try Data(token.utf8).write(to: ready)
    let deadline = Date.now.addingTimeInterval(15)
    while !FileManager.default.fileExists(atPath: release.path) && Date.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
    guard FileManager.default.fileExists(atPath: release.path) else { exit(3) }
    do { try workerRepository.save(workspace); exit(0) }
    catch LifeBoardError.concurrentChange { exit(2) }
    catch { FileHandle.standardError.write(Data(error.localizedDescription.utf8)); exit(4) }
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--crash-worker" {
    let file = URL(fileURLWithPath: CommandLine.arguments[2])
    let ready = URL(fileURLWithPath: CommandLine.arguments[3])
    let workerRepository = LifeBoardRepository(fileURL: file)
    var workspace = try workerRepository.loadThrowing()
    try Data("ready".utf8).write(to: ready)
    while true {
        workspace.tasks[0].title = workspace.tasks[0].title == "Crash version A" ? "Crash version B" : "Crash version A"
        workspace = try workerRepository.saveReturning(workspace)
    }
}

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LifeBoardSafetyTest-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: folder) }
let repository = LifeBoardRepository(fileURL: folder.appendingPathComponent("fixture.json"), iCloudBackupDirectory: folder.appendingPathComponent("cloud"))
var data = LifeBoardData.seeded()
var task = TaskItem(title: "Chemistry worksheet")
task.subjectID = data.subjects.first(where: { $0.title == "Chemistry" })?.id
task.completionPercent = 35
data.tasks.append(task)
try repository.save(data)
var active = ActiveFocusSession(kind: .focus, taskID: task.id, taskTitle: task.title, subjectID: task.subjectID, plannedMinutes: 25)
active.startedAt = Date(timeIntervalSince1970: 1_800_000_000)
let focusRecord = FocusSessionRecord(from: active, endedAt: active.startedAt.addingTimeInterval(600), completedTimer: false)
data.focusSessions = [focusRecord]
let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
let currentBytes = try encoder.encode(data)
var legacy = try JSONSerialization.jsonObject(with: currentBytes) as! [String: Any]
legacy.removeValue(forKey: "schemaVersion"); legacy.removeValue(forKey: "focusSessions"); legacy.removeValue(forKey: "activeFocus"); legacy.removeValue(forKey: "externalEvents")
let legacyBytes = try JSONSerialization.data(withJSONObject: legacy)
let backupURL = try repository.export(data, to: folder.appendingPathComponent("backup.json"))

func expectFailure(_ message: String, _ operation: () throws -> Void) {
    do { try operation(); require(false, message) } catch { print("PASS: " + message) }
}

// Every source boundary shares schema, validation and future-version protection.
var future = try JSONSerialization.jsonObject(with: currentBytes) as! [String: Any]
future["schemaVersion"] = 999; future["unknownFutureField"] = ["keep": true]
let futureBytes = try JSONSerialization.data(withJSONObject: future, options: [.sortedKeys])
let safetyFolder = folder.appendingPathComponent("safety")
let safety = LifeBoardRepository(fileURL: safetyFolder.appendingPathComponent("planner.json"), iCloudBackupDirectory: safetyFolder.appendingPathComponent("cloud"))
try safety.save(data)
try futureBytes.write(to: safety.fileURL)
expectFailure("future file is rejected") { _ = try safety.loadThrowing() }
expectFailure("future file cannot be saved over") { try safety.save(data) }
expectFailure("future file cannot be backed up as a decoded snapshot") { _ = try safety.durableSnapshot() }
require(try Data(contentsOf: safety.fileURL) == futureBytes, "future source remains byte-identical")
let originalCopy = try safety.exportOriginal()
require(try Data(contentsOf: originalCopy) == futureBytes, "future source can be exported intact")
expectFailure("empty object is not a backup") { _ = try LifeBoardValidation.decode(Data("{}".utf8)) }
var unknown = try JSONSerialization.jsonObject(with: currentBytes) as! [String: Any]
unknown["unexpected"] = true
expectFailure("unknown schema3 fields fail before lossy decode") { _ = try LifeBoardValidation.decode(JSONSerialization.data(withJSONObject: unknown)) }
unknown.removeValue(forKey: "unexpected")
var invalidTasks = unknown["tasks"] as! [[String: Any]]
invalidTasks[0]["title"] = 123; unknown["tasks"] = invalidTasks
expectFailure("numeric title rejected") { _ = try LifeBoardValidation.decode(JSONSerialization.data(withJSONObject: unknown)) }
var invalid = data; invalid.tasks[0].dueDay = LocalDay(year: 2026, month: 2, day: 30)
expectFailure("impossible date rejected") { try LifeBoardValidation.validate(invalid) }
invalid = data; invalid.tasks[0].estimatedMinutes = -3
expectFailure("negative duration rejected") { try LifeBoardValidation.validate(invalid) }
invalid = data; invalid.tasks[0].subjectID = UUID()
expectFailure("missing live relationship rejected") { try LifeBoardValidation.validate(invalid) }
invalid = data; invalid.tasks.append(invalid.tasks[0])
expectFailure("duplicate ID rejected") { try LifeBoardValidation.validate(invalid) }
invalid = data; invalid.tasks[0].sortOrder = .infinity
expectFailure("non-finite numbers rejected") { try LifeBoardValidation.validate(invalid) }
expectFailure("helper refuses invalid date") { _ = try safety.makeTask(from: safety.decodePayload(#"{"title":"Invalid","dueDate":"2026-99-99"}"#), in: data) }
expectFailure("helper refuses invalid enum") { _ = try safety.makeTask(from: safety.decodePayload(#"{"title":"Invalid","priority":"urgent"}"#), in: data) }
expectFailure("helper refuses oversized duration") { _ = try safety.makeTask(from: safety.decodePayload(#"{"title":"Invalid","estimatedMinutes":99999}"#), in: data) }
require(try LifeBoardValidation.decode(legacyBytes).tasks.count == data.tasks.count, "legacy backup validates and migrates")

// Recovery is explicit, validates before replacing, and preserves corrupt bytes.
let corrupt = Data("{broken".utf8)
try corrupt.write(to: safety.fileURL)
expectFailure("corrupt current snapshot blocks all ordinary writes") { try safety.save(data) }
let recovered = try safety.replaceFromBackup(from: backupURL)
require(recovered.tasks.count == data.tasks.count, "verified restore succeeds")
let recoveryCopies = try FileManager.default.contentsOfDirectory(at: safety.backupDirectory, includingPropertiesForKeys: nil)
require(recoveryCopies.contains { (try? Data(contentsOf: $0)) == corrupt }, "restore preserves original corrupt bytes")
let restoredBytes = try Data(contentsOf: safety.fileURL)
let invalidBackup = safetyFolder.appendingPathComponent("invalid-backup.json")
try Data("{}".utf8).write(to: invalidBackup)
expectFailure("invalid restore cannot replace current file") { _ = try safety.replaceFromBackup(from: invalidBackup) }
require(try Data(contentsOf: safety.fileURL) == restoredBytes, "invalid restore leaves source untouched")

// File modes cover new and upgraded data plus backups. No live data is used.
let manager = FileManager.default
func mode(_ url: URL) throws -> Int { (try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
require(try mode(safety.fileURL) == 0o600, "planner is owner-only")
require(try mode(safetyFolder) == 0o700, "planner folder is owner-only")
require(try mode(originalCopy) == 0o600, "recovery backup is owner-only")
try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: safety.fileURL.path)
_ = try safety.loadThrowing()
require(try mode(safety.fileURL) == 0o600, "existing planner permissions upgrade")

// Read permission loss must not be mistaken for a fresh workspace. Restore
// permission only after attempted operations, then compare exact original bytes.
let permissionBytes = try Data(contentsOf: safety.fileURL)
try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: safety.fileURL.path)
expectFailure("read-denied current file blocks mutation") { try safety.save(data) }
expectFailure("read-denied durable source blocks automatic backup snapshot") { _ = try safety.durableSnapshot() }
try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: safety.fileURL.path)
require(try Data(contentsOf: safety.fileURL) == permissionBytes, "permission denial leaves original bytes untouched")
let missingRepository = LifeBoardRepository(fileURL: folder.appendingPathComponent("missing/planner.json"))
try missingRepository.save(data); _ = try missingRepository.loadThrowing()
try manager.removeItem(at: missingRepository.fileURL)
expectFailure("disappeared file is not interpreted as a new workspace") { _ = try missingRepository.loadThrowing() }
expectFailure("disappeared file cannot be recreated from stale data") { try missingRepository.save(data) }
require(!manager.fileExists(atPath: missingRepository.fileURL.path), "missing source stays missing until explicit recovery")

// Independent processes/repositories must preserve edits or return a conflict.
let writerA = LifeBoardRepository(fileURL: safety.fileURL)
let writerB = LifeBoardRepository(fileURL: safety.fileURL)
var a = try writerA.loadThrowing(), b = try writerB.loadThrowing()
a.tasks[0].title = "Writer A title"; b.tasks[0].notes = "Writer B notes"
try writerA.save(a)
let concurrencyMerged = try writerB.saveReturning(b)
require(concurrencyMerged.tasks[0].title == "Writer A title" && concurrencyMerged.tasks[0].notes == "Writer B notes", "same task independent fields merge in repository transaction")
a = try writerA.loadThrowing(); b = try writerB.loadThrowing()
a.tasks[0].title = "Different A"; b.tasks[0].title = "Different B"
try writerA.save(a)
let bytesBeforeConflict = try Data(contentsOf: safety.fileURL)
expectFailure("concurrent same field explicitly conflicts") { try writerB.save(b) }
require(try Data(contentsOf: safety.fileURL) == bytesBeforeConflict, "conflicting writer preserves winner bytes")
a = try writerA.loadThrowing(); b = try writerB.loadThrowing()
a.tasks.append(TaskItem(title: "Writer A addition")); b.tasks.append(TaskItem(title: "Writer B addition"))
try writerA.save(a); try writerB.save(b)
let bothAdditions = try writerA.loadThrowing()
require(bothAdditions.tasks.contains { $0.title == "Writer A addition" } && bothAdditions.tasks.contains { $0.title == "Writer B addition" }, "concurrent imports retain both records")

// Inverse fields preserve newer remote additions/settings/untouched task fields.
var before = data, after = data
before.tasks[0].title = "Before"; after.tasks[0].title = "After"
let inverse = try LifeBoardDataPatch(before: before, after: after).reversed()
var now = after; now.tasks.append(TaskItem(title: "Remote B")); now.tasks[0].notes = "Remote notes"; now.settings.defaultTaskMinutes = 45
let undone = try inverse.applying(to: now)
require(undone.tasks[0].title == "Before" && undone.tasks[0].notes == "Remote notes" && undone.tasks.contains { $0.title == "Remote B" } && undone.settings.defaultTaskMinutes == 45, "Undo preserves unrelated remote work")
now.tasks[0].title = "Remote conflicting title"
expectFailure("Undo never overwrites changed field") { _ = try inverse.applying(to: now) }
var deleted = before; deleted.tasks[0].isArchived = true
let trashUndo = try LifeBoardDataPatch(before: before, after: deleted).reversed()
var remoteAfterDelete = deleted; remoteAfterDelete.tasks[0].notes = "Edited after deletion"
let restoredTrash = try trashUndo.applying(to: remoteAfterDelete)
require(!restoredTrash.tasks[0].isArchived && restoredTrash.tasks[0].notes == "Edited after deletion", "Trash Undo preserves remote task edit")
try writerA.saveReturning({ var value = bothAdditions; value.tasks[0].isArchived = true; return value }())
require(try LifeBoardRepository(fileURL: safety.fileURL).loadThrowing().tasks[0].isArchived, "Trash persists across repository relaunch")

var settingsLocal = data, settingsRemote = data
settingsLocal.settings.defaultTaskMinutes = 45; settingsRemote.settings.breakMinutes = 0
settingsRemote.settings.lastICloudBackup = .now
let settingsMerged = try LifeBoardSyncMerge.merge(base: data, local: settingsLocal, remote: settingsRemote)
require(settingsMerged.data?.settings.defaultTaskMinutes == 45 && settingsMerged.data?.settings.breakMinutes == 0, "settings fields merge independently")
settingsRemote.settings.defaultTaskMinutes = 90
let settingsConflict = try LifeBoardSyncMerge.merge(base: data, local: settingsLocal, remote: settingsRemote)
require(settingsConflict.conflicts == ["settings/defaultTaskMinutes"], "same setting conflict names the field")

// Same session completion is deterministic even at different tick times.
require(focusRecord.id == active.id, "focus history reuses active session ID")
let completeA = FocusSessionRecord(from: active, endedAt: active.startedAt.addingTimeInterval(1600), completedTimer: true)
let completeB = FocusSessionRecord(from: active, endedAt: active.startedAt.addingTimeInterval(1700), completedTimer: true)
require(completeA == completeB && completeA.focusedSeconds == 1500, "completed focus time and ID are canonical")
var focusBase = data; focusBase.activeFocus = active; focusBase.focusSessions = []
var focusA = focusBase, focusB = focusBase
focusA.focusSessions = [completeA]; focusA.activeFocus = nil
focusB.focusSessions = [completeB]; focusB.activeFocus = nil
let focusMerged = try LifeBoardSyncMerge.merge(base: focusBase, local: focusA, remote: focusB)
require(focusMerged.data?.focusSessions.count == 1 && focusMerged.data?.activeFocus == nil, "offline double focus completion converges once")
focusB = focusBase; focusB.activeFocus?.pausedAt = active.startedAt.addingTimeInterval(300)
let pauseComplete = try LifeBoardSyncMerge.merge(base: focusBase, local: focusA, remote: focusB)
require(pauseComplete.data?.focusSessions.count == 1 && pauseComplete.data?.activeFocus == nil, "completed session wins stale pause without duplicate work")

// Additive recurrence/checklists retain old schema3 decoding.
var recurring = TaskItem(title: "Weekly revision")
recurring.scheduledDay = LocalDay(year: 2026, month: 1, day: 31)
recurring.dueDay = recurring.scheduledDay
recurring.recurrence = TaskRecurrence(frequency: "monthly")
recurring.subtasks = [TaskSubtask(title: "Review notes")]; recurring.subtasks?[0].isCompleted = true
let nextOccurrence = RecurrenceEngine.nextTask(after: recurring)!
require(nextOccurrence.scheduledDay == LocalDay(year: 2026, month: 2, day: 28), "monthly recurrence clamps to actual month")
require(nextOccurrence.recurrenceSeriesID == recurring.id && nextOccurrence.subtasks?.first?.isCompleted == false, "recurrence preserves series and resets checklist")
var recurrenceData = data
RecurrenceEngine.appendNextOccurrence(after: recurring, in: &recurrenceData)
RecurrenceEngine.appendNextOccurrence(after: recurring, in: &recurrenceData)
require(recurrenceData.tasks.filter { $0.id == nextOccurrence.id }.count == 1, "recurrence finalisation is idempotent")
let fixtureID = RecurrenceEngine.occurrenceID(seriesID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, day: LocalDay(year: 2026, month: 2, day: 28))
require(fixtureID.uuidString.lowercased() == "00000000-0000-5000-8000-0000000b8042", "shared JavaScript recurrence ID fixture")

func runWriters(_ specifications: [(String, String)], file: URL, barrierName: String) throws -> [Int32] {
    let barrierFolder = folder.appendingPathComponent(barrierName)
    try FileManager.default.createDirectory(at: barrierFolder, withIntermediateDirectories: true)
    let release = barrierFolder.appendingPathComponent("release")
    var processes: [Process] = []
    for (token, operation) in specifications {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--worker", file.path, barrierFolder.appendingPathComponent("ready-" + token).path, release.path, token, operation]
        try process.run(); processes.append(process)
    }
    let deadline = Date.now.addingTimeInterval(15)
    while Date.now < deadline {
        if specifications.allSatisfy({ FileManager.default.fileExists(atPath: barrierFolder.appendingPathComponent("ready-" + $0.0).path) }) { break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    require(specifications.allSatisfy({ FileManager.default.fileExists(atPath: barrierFolder.appendingPathComponent("ready-" + $0.0).path) }), "all concurrent writers loaded the same baseline")
    try Data("release".utf8).write(to: release)
    for process in processes { process.waitUntilExit() }
    return processes.map(\.terminationStatus)
}

let processRepository = LifeBoardRepository(fileURL: folder.appendingPathComponent("processes/planner.json"))
try processRepository.save(data)
let statuses = try runWriters((0..<8).map { (String($0), "import") } + [("app", "edit")], file: processRepository.fileURL, barrierName: "distinct")
require(statuses.allSatisfy { $0 == 0 }, "eight process imports and a distinct app edit all commit")
let processMerged = try processRepository.loadThrowing()
require(processMerged.tasks.filter { $0.title.hasPrefix("Process import ") }.count == 8 && processMerged.tasks[0].notes == "Process edit app", "cross-process lock and baseline merge preserve every distinct change")
let collisionStatuses = try runWriters([("a", "same-field"), ("b", "same-field")], file: processRepository.fileURL, barrierName: "collision")
require(collisionStatuses.sorted() == [0, 2], "cross-process same-field collision returns one explicit retryable conflict")
let collisionFinal = try processRepository.loadThrowing()
require(["Process conflict a", "Process conflict b"].contains(collisionFinal.tasks[0].title), "same-field conflict leaves one valid durable winner")

// Optional integration gate against the actual built helper executable.
// The helper receives disposable data paths, preventing widget/live-file writes.
if let flag = CommandLine.arguments.firstIndex(of: "--helper"), CommandLine.arguments.indices.contains(flag + 1) {
    let executable = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    require(FileManager.default.isExecutableFile(atPath: executable.path), "actual helper executable is available")
    let helperRepository = LifeBoardRepository(fileURL: folder.appendingPathComponent("actual-helper/planner.json"))
    try helperRepository.save(data)
    var appEdit = try helperRepository.loadThrowing()
    appEdit.tasks[0].notes = "App edit concurrent with real helper imports"
    var children: [Process] = []
    for index in 0..<8 {
        let process = Process(); process.executableURL = executable
        let payload = "[{\"title\":\"Actual helper \(index) A\"},{\"title\":\"Actual helper \(index) B\"}]"
        process.arguments = ["import", payload]
        var environment = ProcessInfo.processInfo.environment
        environment["LIFEBOARD_DATA_PATH"] = helperRepository.fileURL.path
        environment["LIFEBOARD_ICLOUD_BACKUP_PATH"] = folder.appendingPathComponent("actual-helper/cloud").path
        process.environment = environment; process.standardOutput = FileHandle.nullDevice
        try process.run(); children.append(process)
    }
    _ = try helperRepository.saveReturning(appEdit)
    for child in children { child.waitUntilExit() }
    let actualHelperData = try helperRepository.loadThrowing()
    require(children.allSatisfy({ $0.terminationStatus == 0 }) && actualHelperData.tasks.filter({ $0.title.hasPrefix("Actual helper ") }).count == 16 && actualHelperData.tasks[0].notes == "App edit concurrent with real helper imports", "eight actual helper batches and app edit preserve all sixteen imports and the edit")
}

// Simulate a process dying inside private atomic-file construction: unpublished
// temporary bytes do not replace the last valid planner. Recovery can ignore them.
let oldProcessBytes = try Data(contentsOf: processRepository.fileURL)
let interruptedTemp = processRepository.fileURL.deletingLastPathComponent().appendingPathComponent(".LifeBoard-interrupted.tmp")
try Data("partial-write".utf8).write(to: interruptedTemp)
let afterInterrupted = try processRepository.loadThrowing()
let afterInterruptedBytes = try Data(contentsOf: processRepository.fileURL)
require(afterInterrupted.tasks.count == collisionFinal.tasks.count && afterInterruptedBytes == oldProcessBytes, "unpublished partial temporary file cannot corrupt durable planner")

// Terminate an actual multi-megabyte writer at several offsets. The lock must
// release on process death and every published JSON must be a complete version.
let crashRepository = LifeBoardRepository(fileURL: folder.appendingPathComponent("crash/planner.json"))
var large = LifeBoardData()
for index in 0..<30 {
    var item = TaskItem(title: "Crash original \(index)"); item.notes = String(repeating: "x", count: 150_000); large.tasks.append(item)
}
try crashRepository.save(large)
for (index, delay) in [0.005, 0.03, 0.08, 0.15].enumerated() {
    let ready = folder.appendingPathComponent("crash-ready-\(index)")
    let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    process.arguments = ["--crash-worker", crashRepository.fileURL.path, ready.path]
    try process.run()
    let deadline = Date.now.addingTimeInterval(15)
    while !FileManager.default.fileExists(atPath: ready.path) && Date.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
    require(FileManager.default.fileExists(atPath: ready.path), "crash worker loaded durable baseline")
    Thread.sleep(forTimeInterval: delay)
    process.terminate(); process.waitUntilExit()
    let snapshot = try crashRepository.loadThrowing()
    require(snapshot.tasks.count == 30 && snapshot.tasks.allSatisfy({ $0.notes.count == 150_000 }) && ["Crash original 0", "Crash version A", "Crash version B"].contains(snapshot.tasks[0].title), "terminated writer leaves previous or complete new document and releases lock")
}

#if APPSTORE_SAFETY
require(SchedulingEngine.calendarDropStart(y: 9 * 60 + 37, hourHeight: 60) == 9 * 60 + 35, "calendar drops snap to the closest five minutes")
require(SchedulingEngine.calendarDropStart(y: (9 * 60 + 38) * 1.2, hourHeight: 72) == 9 * 60 + 40, "calendar drop coordinates scale with the timeline")
require(SchedulingEngine.calendarDropStart(y: -1, hourHeight: 60) == 0, "midnight start clamps to the first minute")
require(SchedulingEngine.calendarDropStart(y: 1439, hourHeight: 60) == 1435, "late task drop stays on the intended day")
require(SchedulingEngine.calendarDropStart(y: 1439, hourHeight: 60, eventDuration: 47) == 1393, "late event preview retains its full duration")
try MainActor.assumeIsolated {
    let calendarFolder = folder.appendingPathComponent("calendar")
    let repository = LifeBoardRepository(fileURL: calendarFolder.appendingPathComponent("planner.json"))
    let monday = LocalDay(iso: "2026-11-02")!
    let tuesday = monday.adding(days: 1)
    var task = TaskItem(title: "Coursework")
    task.estimatedMinutes = 30
    task.scheduledDay = monday
    task.scheduledStartMinutes = 9 * 60 + 10
    task.scheduledDurationMinutes = 47
    task.dueDay = monday.adding(days: 4)
    task.tags = ["keep this"]
    var shortEvent = CalendarEvent(title: "Check-in", day: monday, startMinutes: 600, endMinutes: 607)
    shortEvent.location = "Lab"
    var initial = LifeBoardData()
    task.createdAt = Date(timeIntervalSinceReferenceDate: 765_432_100.1234567)
    initial.tasks = [task]
    initial.events = [shortEvent]
    try repository.save(initial)
    setenv("LIFEBOARD_DATA_PATH", repository.fileURL.path, 1)
    defer { unsetenv("LIFEBOARD_DATA_PATH") }
    let store = AppStore(repository: repository)
    let undo = UndoManager()
    store.undoManager = undo
    let baseline = try repository.durableSnapshot()
    require(baseline.tasks[0].createdAt == task.createdAt, "local storage preserves a fractional creation timestamp")
    let offsetDate = try LifeBoardJSON.decoder().decode(Date.self, from: Data("\"2024-02-29T20:00:00.125+01:00\"".utf8))
    let utcDate = try LifeBoardJSON.decoder().decode(Date.self, from: Data("\"2024-02-29T19:00:00.125Z\"".utf8))
    require(offsetDate == utcDate, "date decoding preserves legacy fractional timestamps with an offset")

    undo.beginUndoGrouping()
    require(store.moveScheduledTask(task.id, day: tuesday, startMinutes: 1435), "task can be dragged across days and midnight")
    undo.endUndoGrouping()
    let moved = try repository.durableSnapshot().tasks[0]
    var expected = baseline.tasks[0]
    expected.scheduledDay = tuesday
    expected.scheduledStartMinutes = 1435
    expected.modifiedAt = moved.modifiedAt
    require(moved == expected, "task move keeps the custom duration and all other fields on disk")
    require(SchedulingEngine.taskSegment(moved, on: tuesday.adding(days: 1))?.end == 42, "overnight task occupies the correct next-day minutes")
    let movedBytes = try Data(contentsOf: repository.fileURL)
    require(store.moveScheduledTask(task.id, day: tuesday, startMinutes: 1435), "same-slot drop succeeds")
    require((try Data(contentsOf: repository.fileURL)) == movedBytes, "same-slot drop leaves the saved document byte-identical")
    undo.undo()
    var restoredTask = try repository.durableSnapshot().tasks[0]
    restoredTask.modifiedAt = baseline.tasks[0].modifiedAt // Undo retains modification metadata.
    require(restoredTask == baseline.tasks[0], "calendar Undo restores the original task fields")
    undo.redo()
    require((try repository.durableSnapshot()).tasks == [moved], "calendar Redo restores the moved task")
    require(store.moveScheduledTask(task.id, day: monday), "date-only drop moves an already timed task")
    let dateOnly = try repository.durableSnapshot().tasks[0]
    require(dateOnly.scheduledDay == monday && dateOnly.scheduledStartMinutes == 1435 && dateOnly.scheduledDurationMinutes == 47, "date-only drop preserves both time and duration")
    var pending = TaskItem(title: "From the Today shelf")
    pending.estimatedMinutes = 65
    require(store.commit { $0.tasks.append(pending) }, "seed an unscheduled task for Today")
    require(store.moveScheduledTask(pending.id, day: .today, startMinutes: 10 * 60 + 25), "untimed task can be placed on Today's timeline")
    let scheduledToday = try repository.durableSnapshot().tasks[1]
    require(scheduledToday.scheduledDay == .today && scheduledToday.scheduledStartMinutes == 625 && scheduledToday.scheduledDurationMinutes == 65, "Today reload keeps the snapped time and full estimate")
    require(store.unscheduleTime(pending.id, day: .today), "drop back on Today's shelf clears the time")
    let untimedToday = try repository.durableSnapshot().tasks[1]
    require(untimedToday.scheduledDay == .today && untimedToday.scheduledStartMinutes == nil && untimedToday.scheduledDurationMinutes == nil, "Today untimed drop keeps the day and clears the saved interval")
    require(store.moveEvent(shortEvent.id, day: tuesday, startMinutes: 1439), "late event move succeeds")
    let movedEvent = try repository.durableSnapshot().events[0]
    require(movedEvent.day == tuesday && movedEvent.startMinutes == 1433 && movedEvent.endMinutes == 1440 && movedEvent.location == "Lab", "seven-minute event still lasts seven minutes at midnight")

    let first = calendarFolder.appendingPathComponent("Worksheet #1 – maths.pdf")
    let second = calendarFolder.appendingPathComponent("Reference.txt")
    let sourceBytes = Data("synthetic source".utf8)
    try sourceBytes.write(to: first)
    try sourceBytes.write(to: second)
    undo.beginUndoGrouping()
    require(store.addCalendarFiles([first, second], day: tuesday, startMinutes: 9 * 60 + 35), "multiple file URLs save as one scheduled task")
    undo.endUndoGrouping()
    let reopened = AppStore(repository: LifeBoardRepository(fileURL: repository.fileURL))
    let imported = try repository.durableSnapshot().tasks[2]
    require(reopened.data.tasks[2] == imported, "relaunch restores the full file task and its timing")
    require(imported.scheduledDay == tuesday && imported.scheduledStartMinutes == 575 && CalendarFileLink.urls(in: imported.notes) == [first, second], "file links, Unicode, order and exact start survive reload")
    let originalBytes = try [first, second].map { try Data(contentsOf: $0) }
    require(originalBytes == [sourceBytes, sourceBytes], "scheduling files leaves original bytes unchanged")
    let snapshot = try repository.durableSnapshot()
    let backup = try repository.export(snapshot)
    require((try repository.importBackup(from: backup)).tasks == snapshot.tasks, "backup preserves the scheduled file links and task fields")
    undo.undo()
    require((try repository.durableSnapshot()).tasks.count == 2, "one Undo removes the whole file drop")
    let unchanged = try Data(contentsOf: repository.fileURL)
    require(!store.addCalendarFiles([first, URL(string: "https://example.com/file")!], day: tuesday, startMinutes: 600), "invalid file batch is rejected")
    require((try Data(contentsOf: repository.fileURL)) == unchanged, "invalid file batch leaves storage unchanged")
}

var deviceData = LifeBoardData()
deviceData.settings.automaticICloudBackup = true
deviceData.settings.notificationsDeadlines = true
deviceData.settings.notificationLeadMinutes = 37
deviceData.settings.selectedExternalCalendarIDs = ["synthetic-calendar"]
deviceData.settings.lastICloudBackup = Date(timeIntervalSince1970: 1_800_000_000)
let localPreferences = DevicePreferences(deviceData.settings)
var sharedData = DevicePreferences.sharedProjection(deviceData)
require(!sharedData.settings.automaticICloudBackup && !sharedData.settings.notificationsDeadlines && sharedData.settings.selectedExternalCalendarIDs.isEmpty && sharedData.settings.lastICloudBackup == nil, "shared projection excludes device calendar, notifications and backup metadata")
localPreferences.apply(to: &sharedData.settings)
require(sharedData.settings.automaticICloudBackup && sharedData.settings.notificationsDeadlines && sharedData.settings.notificationLeadMinutes == 37 && sharedData.settings.selectedExternalCalendarIDs == ["synthetic-calendar"], "device preferences reapply local choices after remote snapshot")
try MainActor.assumeIsolated {
    let appFolder = folder.appendingPathComponent("appstore")
    let appRepository = LifeBoardRepository(fileURL: appFolder.appendingPathComponent("planner.json"), iCloudBackupDirectory: appFolder.appendingPathComponent("cloud"))
    var appData = LifeBoardData(); appData.tasks = [TaskItem(title: "App task A")]; appData.settings.automaticICloudBackup = true
    try appRepository.save(appData)
    setenv("LIFEBOARD_DATA_PATH", appRepository.fileURL.path, 1)
    defer { unsetenv("LIFEBOARD_DATA_PATH") }
    let store = AppStore(repository: appRepository)
    let initialFile = try Data(contentsOf: appRepository.fileURL)
    store.handle(url: URL(string: "lifeboard://task/create?title=Review%20external%20task")!)
    let previewBytes = try Data(contentsOf: appRepository.fileURL)
    require(store.pendingExternalImport?.tasks.count == 1 && previewBytes == initialFile, "external deep link opens review without mutation")
    store.cancelExternalImport()
    let cancelledBytes = try Data(contentsOf: appRepository.fileURL)
    require(store.pendingExternalImport == nil && cancelledBytes == initialFile, "cancelled external import leaves durable bytes untouched")
    let undo = UndoManager(); store.undoManager = undo
    undo.beginUndoGrouping()
    require(store.commit(actionName: "Edit A", { $0.tasks[0].title = "Local title A" }), "AppStore commits local edit")
    undo.endUndoGrouping()
    let helper = LifeBoardRepository(fileURL: appRepository.fileURL)
    var helperData = try helper.loadThrowing(); helperData.tasks[0].notes = "Newer remote notes"; helperData.tasks.append(TaskItem(title: "Remote task B")); try helper.save(helperData)
    store.reloadIfChanged(); undo.undo()
    require(store.data.tasks[0].title == "App task A" && store.data.tasks[0].notes == "Newer remote notes" && store.data.tasks.contains(where: { $0.title == "Remote task B" }), "production AppStore Undo preserves remote fields and additions")
    let baseline = store.data.tasks[0]
    helperData = try helper.loadThrowing(); helperData.tasks[0].title = "Remote newer title"; try helper.save(helperData)
    var draft = baseline; draft.notes = "Local changed notes"
    undo.beginUndoGrouping(); require(store.updateTask(draft, basedOn: baseline), "versioned draft commits independent field with helper writer"); undo.endUndoGrouping()
    require(store.data.tasks[0].title == "Remote newer title" && store.data.tasks[0].notes == "Local changed notes", "production draft commit preserves concurrently changed untouched field")
    var conflictDraft = baseline; conflictDraft.title = "Stale local title"
    require(!store.updateTask(conflictDraft, basedOn: baseline) && store.data.tasks[0].title == "Remote newer title", "production draft rejects stale same-field overwrite")
    store.selectedTaskID = baseline.id
    helperData = try helper.loadThrowing(); helperData.tasks[0].isArchived = true; try helper.save(helperData)
    store.reloadIfChanged()
    require(store.selectedTaskID == nil, "remote Trash clears native inspector selection")
    var settings = store.data.settings
    settings.notificationsDeadlines = true; settings.notificationLeadMinutes = 37; settings.selectedExternalCalendarIDs = ["local-fixture-calendar"]
    undo.beginUndoGrouping(); store.updateSettings(settings); undo.endUndoGrouping()
    undo.undo()
    require(!store.data.settings.notificationsDeadlines && store.data.settings.selectedExternalCalendarIDs.isEmpty, "Undo reverses device preferences instead of reapplying stale sidecar values")
    undo.redo()
    require(store.data.settings.notificationsDeadlines && store.data.settings.selectedExternalCalendarIDs == ["local-fixture-calendar"], "Redo restores device preference operation")
    let preferencesURL = appFolder.appendingPathComponent("DevicePreferences.json")
    let preferenceMode = try mode(preferencesURL)
    require(FileManager.default.fileExists(atPath: preferencesURL.path) && preferenceMode == 0o600, "device preference sidecar persists privately")
    let relaunched = AppStore(repository: LifeBoardRepository(fileURL: appRepository.fileURL, iCloudBackupDirectory: appRepository.iCloudBackupDirectory))
    require(relaunched.data.settings.notificationsDeadlines && relaunched.data.settings.notificationLeadMinutes == 37 && relaunched.data.settings.selectedExternalCalendarIDs == ["local-fixture-calendar"], "device preference sidecar restores choices after native relaunch")
    helperData = try helper.loadThrowing(); helperData.settings.notificationsDeadlines = false; helperData.settings.selectedExternalCalendarIDs = ["remote-fixture-calendar"]; helperData.settings.defaultTaskMinutes = 45; try helper.save(helperData)
    store.reloadIfChanged()
    require(store.data.settings.notificationsDeadlines && store.data.settings.selectedExternalCalendarIDs == ["local-fixture-calendar"] && store.data.settings.defaultTaskMinutes == 45, "remote shared edit does not overwrite local calendar or notification preferences")
    // Durable source became corrupt before the UI's one-second refresh.
    try corrupt.write(to: appRepository.fileURL)
    store.performICloudBackup(force: true)
    require((try Data(contentsOf: appRepository.fileURL)) == corrupt && store.message?.title == "iCloud Backup Unavailable", "forced backup before reload rejects corrupt durable source without writing stale data")
    store.reloadIfChanged()
    store.performICloudBackup(force: true); store.performICloudBackup(force: false)
    require((try Data(contentsOf: appRepository.fileURL)) == corrupt && store.message?.title == "Backup Paused", "forced and scheduled backups honour paused-change guard")
    let pausedCommit = store.commit({ $0.tasks.append(TaskItem(title: "Must not overwrite")) })
    let pausedBytes = try Data(contentsOf: appRepository.fileURL)
    require(!pausedCommit && pausedBytes == corrupt, "all ordinary AppStore mutations remain paused after corruption")
    require(!FileManager.default.fileExists(atPath: appRepository.iCloudBackupDirectory.path) && !FileManager.default.fileExists(atPath: appFolder.appendingPathComponent("BackupStatus.json").path), "corrupt-source backup cannot create cloud success or bookkeeping")
}
// Preview overhaul: completion, rescheduling, inline entry and the planner index.
try MainActor.assumeIsolated {
    let folder2 = folder.appendingPathComponent("overhaul")
    let repository = LifeBoardRepository(fileURL: folder2.appendingPathComponent("planner.json"), iCloudBackupDirectory: folder2.appendingPathComponent("cloud"))
    let today = LocalDay.today
    var seed = LifeBoardData.seeded()
    var timed = TaskItem(title: "Timed revision"); timed.scheduledDay = today; timed.scheduledStartMinutes = 17 * 60; timed.scheduledDurationMinutes = 40; timed.dueDay = today.adding(days: 3)
    var untimed = TaskItem(title: "Untimed reading"); untimed.scheduledDay = today
    var overdue = TaskItem(title: "Overdue write-up"); overdue.dueDay = today.adding(days: -1)
    var later = TaskItem(title: "Later essay"); later.dueDay = today.adding(days: 20)
    var archived = TaskItem(title: "Trashed"); archived.scheduledDay = today; archived.isArchived = true
    var lateNight = TaskItem(title: "Late night"); lateNight.scheduledDay = today; lateNight.scheduledStartMinutes = 23 * 60 + 30; lateNight.scheduledDurationMinutes = 60
    seed.tasks = [timed, untimed, overdue, later, archived, lateNight]
    let tripStart = Calendar.current.startOfDay(for: today.adding(days: 2).date())
    seed.externalEvents = [ExternalCalendarEvent(id: "multi", calendarID: "c", calendarTitle: "School", title: "Residential trip", day: today.adding(days: 2), startMinutes: 0, endMinutes: 1440, isAllDay: true, startInstant: tripStart, endInstant: Calendar.current.date(byAdding: .day, value: 3, to: tripStart), timeZoneIdentifier: TimeZone.current.identifier)]
    seed.settings.hasCompletedOnboarding = true
    try repository.save(seed)
    setenv("LIFEBOARD_DATA_PATH", repository.fileURL.path, 1)
    defer { unsetenv("LIFEBOARD_DATA_PATH") }
    let store = AppStore(repository: repository)
    let undo = UndoManager(); undo.groupsByEvent = false; store.undoManager = undo

    // Completion is saved at once; the row lingers briefly in its group.
    undo.beginUndoGrouping(); store.toggleCompletion(untimed.id, reduceMotion: true); undo.endUndoGrouping()
    require(try repository.durableSnapshot().tasks.first { $0.id == untimed.id }?.isCompleted == true, "completing a task is durable immediately")
    require(store.lingeringCompletions.contains(untimed.id), "a just-completed task lingers so the list does not jump")
    require(store.index.todayGroups(lingering: store.lingeringCompletions, search: "").first { $0.id == "today" }?.tasks.contains { $0.id == untimed.id } == true, "a lingering task stays in its Today group")
    require(store.index.todayGroups(lingering: [], search: "").first { $0.id == "done" }?.tasks.contains { $0.id == untimed.id } == true, "once settled it appears under Done today")
    undo.undo()
    require(try repository.durableSnapshot().tasks.first { $0.id == untimed.id }?.isCompleted == false, "Undo reopens the completed task on disk")
    store.undoManager = nil // the remaining checks do not exercise Undo
    store.toggleCompletion(untimed.id, reduceMotion: true); store.toggleCompletion(untimed.id, reduceMotion: true)
    require(!store.lingeringCompletions.contains(untimed.id) && store.data.tasks.first { $0.id == untimed.id }?.isCompleted == false, "reopening at once cancels the linger")

    // Rescheduling keeps an exact time, keeps an untimed task untimed and never touches the due date.
    store.setWhen(timed.id, day: today.adding(days: 1))
    let moved = try repository.durableSnapshot().tasks.first { $0.id == timed.id }!
    require(moved.scheduledDay == today.adding(days: 1) && moved.scheduledStartMinutes == 17 * 60 && moved.scheduledDurationMinutes == 40 && moved.dueDay == today.adding(days: 3), "Do Tomorrow keeps the exact time, duration and due date")
    store.setWhen(untimed.id, day: today.adding(days: 2))
    let untimedMoved = try repository.durableSnapshot().tasks.first { $0.id == untimed.id }!
    require(untimedMoved.scheduledDay == today.adding(days: 2) && untimedMoved.scheduledStartMinutes == nil, "an untimed task stays untimed when rescheduled")
    store.setWhen(timed.id, day: nil)
    let anytime = try repository.durableSnapshot().tasks.first { $0.id == timed.id }!
    require(anytime.scheduledDay == nil && anytime.scheduledStartMinutes == nil && anytime.dueDay == today.adding(days: 3), "Anytime clears the plan but keeps the due date")
    let weds = LocalDay(year: 2026, month: 11, day: 18)
    require(store.weekendDay(from: weds) == LocalDay(year: 2026, month: 11, day: 21) && store.weekendDay(from: LocalDay(year: 2026, month: 11, day: 22)) == LocalDay(year: 2026, month: 11, day: 22), "This Weekend is the coming Saturday, or today at the weekend")
    require(store.nextWeekDay(from: weds) == LocalDay(year: 2026, month: 11, day: 23) && store.nextWeekDay(from: LocalDay(year: 2026, month: 11, day: 23)) == LocalDay(year: 2026, month: 11, day: 30), "Next Week is the next week start, never today")

    // A no-op change writes nothing.
    let bytes = try Data(contentsOf: repository.fileURL)
    let committedNothing = store.commit { _ in }
    let bytesAfter = try Data(contentsOf: repository.fileURL)
    require(committedNothing && bytesAfter == bytes, "a commit that changes nothing leaves the file byte-identical")

    // Inline entry: exactly what the chips show is what is saved.
    @MainActor func plan(_ line: String, _ context: NewTaskContext) -> QuickEntryPlan {
        QuickEntryPlanner.plan(NaturalLanguageTaskParser.parse(line, referenceDay: today, data: store.data).first!, context: context, index: store.index)
    }
    let due = plan("chem worksheet tomorrow 30m", .today)
    require(due.task?.dueDay == today.adding(days: 1) && due.task?.scheduledDay == nil && due.task?.estimatedMinutes == 30 && due.task?.subjectID == store.data.subjects.first { $0.title == "Chemistry" }?.id, "a typed date becomes a due date with its duration and subject, not a plan")
    let timedEntry = plan("revise vectors at 5pm", .today)
    require(timedEntry.task?.scheduledDay == today && timedEntry.task?.scheduledStartMinutes == 17 * 60 && timedEntry.problem == nil, "a time in Today is planned today at that time")
    require(plan("revise vectors at 5pm", .none).problem != nil && plan("revise vectors at 5pm", .none).task == nil, "a time without any day must be clarified before saving")
    require(plan("biology notes", .day(today.adding(days: 4))).task?.scheduledDay == today.adding(days: 4), "a calendar day plans the To Do for that day")
    require(plan("tidy folder", .none).task?.scheduledDay == nil && plan("tidy folder", .none).chips.first == "Anytime", "To Do adds Anytime tasks")
    require(plan("tidy folder", .today).task?.scheduledDay == today, "Today's field plans a To Do for today")
    require(plan("tidy folder anytime", .today).task?.scheduledDay == nil && plan("tidy folder anytime", .today).chips.first == "Anytime" && plan("tidy folder anytime", .today).task?.title == "Tidy folder", "typing anytime in Today keeps a To Do undated")
    require(plan("essay due 31/02", .today).problem != nil, "an impossible date is never saved")
    let event = plan("drama rehearsal tomorrow at 4pm 90m", .today)
    require(event.event?.day == today.adding(days: 1) && event.event?.startMinutes == 16 * 60 && event.event?.endMinutes == 17 * 60 + 30, "an event-like line with a time becomes an event")
    require(plan("drama rehearsal tomorrow at 11pm 2h", .today).problem == "Events can't cross midnight", "an event may not cross midnight")

    // Planner index: grouping, day buckets and overnight items.
    let index = store.index
    require(index.todayGroups(lingering: [], search: "").first { $0.id == "overdue" }?.tasks.map(\.id) == [overdue.id], "Overdue holds the past-due task")
    let hub = index.todayGroups(lingering: [], search: "")
    require(Set(hub.filter { $0.id != "done" }.flatMap(\.tasks).map(\.id)) == Set(index.activeTasks.map(\.id)), "Today lists every active To Do, Anytime and later ones included")
    require(hub.first { $0.id == "upcoming" }?.tasks.contains { $0.id == later.id } == true && hub.map(\.id) == ["overdue", "today", "anytime", "upcoming", "done"], "Today orders its groups: overdue, today, Anytime, Upcoming, done")
    require(!index.agenda(for: today).untimedTasks.contains { $0.id == archived.id }, "trashed tasks never appear on the calendar")
    require((0...2).allSatisfy { index.agenda(for: today.adding(days: 2 + $0)).allDay.contains { $0.id == "multi" } } && !index.agenda(for: today.adding(days: 5)).allDay.contains { $0.id == "multi" }, "a three-day connected event appears on each of its days only")
    require(index.agenda(for: today.adding(days: 1)).lanes.contains { $0.id == lateNight.id.uuidString && $0.start == 0 && $0.end == 30 }, "a task crossing midnight continues on the next day")
    require(index.allGroups(lingering: [], search: "").first { $0.id == "upcoming" }?.tasks.contains { $0.id == later.id } == true, "dated To Dos beyond today are grouped under Upcoming in To Do")
    require(index.allGroups(lingering: [], search: "essay").flatMap(\.tasks).map(\.id) == [later.id], "search filters every group")
}

// Run production async conflict resolution on the main actor, pumping the
// runloop to avoid blocking its executor. The transport above is entirely local.
final class AsyncTestState: @unchecked Sendable { var finished = false; var error: Error? }
let asyncState = AsyncTestState()
Task { @MainActor in
    defer { SyncService.enabled = false; unsetenv("LIFEBOARD_DATA_PATH"); asyncState.finished = true }
    do {
        let calendarRepository = LifeBoardRepository(fileURL: folder.appendingPathComponent("calendar-permission/planner.json"))
        var calendarData = LifeBoardData()
        calendarData.settings.selectedExternalCalendarIDs = ["synthetic-selected-calendar"]
        calendarData.settings.lastExternalCalendarRefresh = Date(timeIntervalSince1970: 1_800_000_000)
        calendarData.externalEvents = [ExternalCalendarEvent(id: "synthetic-cached-event", calendarID: "synthetic-selected-calendar", calendarTitle: "Synthetic calendar", title: "Cached commitment", day: .today, startMinutes: 540, endMinutes: 600, isAllDay: false)]
        try calendarRepository.save(calendarData)
        setenv("LIFEBOARD_DATA_PATH", calendarRepository.fileURL.path, 1)
        CalendarIntegrationService.requestCount = 0
        let calendarStore = AppStore(repository: calendarRepository)
        let calendarBytes = try Data(contentsOf: calendarRepository.fileURL)
        await Task.yield()
        require(CalendarIntegrationService.requestCount == 0, "native launch with selected calendars never requests calendar permission")
        let deniedStatus = await calendarStore.refreshSelectedCalendarsNow()
        let refreshedCalendarBytes = try Data(contentsOf: calendarRepository.fileURL)
        require(CalendarIntegrationService.requestCount == 0 && calendarStore.data.externalEvents == calendarData.externalEvents && calendarStore.data.settings.selectedExternalCalendarIDs == calendarData.settings.selectedExternalCalendarIDs && refreshedCalendarBytes == calendarBytes, "refresh without full calendar access preserves cached events, selections and durable bytes without prompting")
        require(CalendarIntegrationService.accountRefreshCount == 0 && deniedStatus.contains("Connect Calendars"), "manual sync reports how to connect without attempting an account pull when access is denied")
        await calendarStore.connectGoogleCalendar()
        let deniedCalendarBytes = try Data(contentsOf: calendarRepository.fileURL)
        require(CalendarIntegrationService.requestCount == 1 && calendarStore.data.externalEvents == calendarData.externalEvents && deniedCalendarBytes == calendarBytes, "only explicit Connect Calendars requests permission and denial keeps cached planner intact")

        CalendarIntegrationService.granted = true
        let calendarUndo = UndoManager(); calendarUndo.groupsByEvent = false
        calendarStore.undoManager = calendarUndo
        calendarUndo.beginUndoGrouping()
        let manualTask = calendarStore.addTask(title: "Manual task before calendar delivery")!
        calendarUndo.endUndoGrouping()
        CalendarIntegrationService.choices = [ExternalCalendarChoice(id: "synthetic-selected-calendar", title: "Synthetic calendar", account: "Synthetic")]
        let addedEvent = ExternalCalendarEvent(id: "synthetic-new-event", calendarID: "synthetic-selected-calendar", calendarTitle: "Synthetic calendar", title: "Newly delivered event", day: LocalDay(year: 2026, month: 10, day: 7), startMinutes: 975, endMinutes: 1230, isAllDay: false)
        CalendarIntegrationService.fetched = calendarData.externalEvents + [addedEvent]
        CalendarIntegrationService.latest?.onChange?()
        try await Task.sleep(for: .milliseconds(20))
        require(calendarStore.data.externalEvents.contains(addedEvent) && CalendarIntegrationService.requestCount == 1, "calendar-store change automatically imports newly delivered events without requesting permission")
        require(try calendarRepository.loadThrowing().externalEvents.contains(addedEvent), "automatically refreshed calendar event is durable")
        require(calendarStore.data.settings.lastExternalCalendarRefresh != calendarData.settings.lastExternalCalendarRefresh, "calendar cache and device-local refresh timestamp advance together")
        require(CalendarIntegrationService.accountRefreshCount == 0, "automatic calendar updates only read the local EventKit store")
        let manualStatus = await calendarStore.refreshSelectedCalendarsNow()
        require(CalendarIntegrationService.accountRefreshCount == 1 && manualStatus.hasPrefix("Refreshed at") && CalendarIntegrationService.requestCount == 1, "manual calendar sync requests a source pull and reports the local refresh result without prompting")
        calendarUndo.undo()
        require(!calendarStore.data.tasks.contains(where: { $0.id == manualTask }) && calendarStore.data.externalEvents.contains(addedEvent), "automatic calendar refresh leaves task Undo intact and keeps newly delivered events")
        let queries = CalendarIntegrationService.queryCount
        calendarStore.refreshConnectedCalendarsIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        require(CalendarIntegrationService.queryCount == queries, "background calendar polling is throttled between refreshes")
        calendarStore.refreshConnectedCalendarsIfNeeded(force: true)
        try await Task.sleep(for: .milliseconds(20))
        require(CalendarIntegrationService.queryCount == queries + 1, "returning to the app can force a permission-free calendar refresh")
        calendarStore.refreshConnectedCalendarsIfNeeded(now: Date.now.addingTimeInterval(301))
        try await Task.sleep(for: .milliseconds(20))
        require(CalendarIntegrationService.queryCount == queries + 2, "calendar polling refreshes after the five-minute fallback interval")
        CalendarIntegrationService.choices = []
        let availableBytes = try Data(contentsOf: calendarRepository.fileURL)
        await calendarStore.refreshGoogleCalendar()
        let unavailableBytes = try Data(contentsOf: calendarRepository.fileURL)
        require(calendarStore.data.externalEvents.contains(addedEvent) && unavailableBytes == availableBytes, "temporarily unavailable selected calendars preserve durable cached events")
        CalendarIntegrationService.granted = false
        CalendarIntegrationService.choices = []
        CalendarIntegrationService.fetched = []

        let syncRepository = LifeBoardRepository(fileURL: folder.appendingPathComponent("sync/planner.json"))
        var baseline = LifeBoardData(); baseline.tasks = [TaskItem(title: "Baseline sync title")]
        try syncRepository.save(baseline)
        setenv("LIFEBOARD_DATA_PATH", syncRepository.fileURL.path, 1)
        let store = AppStore(repository: syncRepository)
        require(store.commit({ $0.tasks[0].title = "Local sync title" }), "production sync fixture commits local edit")
        var remote = baseline; remote.tasks[0].title = "Remote sync title"
        SyncService.enabled = true; SyncService.base = SyncBaseline(revision: 0, data: baseline); SyncService.remote = SyncEnvelope(revision: 1, data: remote)
        await store.syncNow()
        require(store.syncConflicts.count == 1 && store.syncConflicts[0].path.hasSuffix("/title"), "production sync presents the exact conflicting field")
        let path = store.syncConflicts[0].path
        await store.resolveSyncConflicts(choices: [path: false])
        require(store.syncConflicts.isEmpty && store.data.tasks[0].title == "Remote sync title" && SyncService.remote.data?.tasks[0].title == "Remote sync title", "keep remote resolves and converges without dropping other work")
        let copies = try FileManager.default.contentsOfDirectory(at: syncRepository.backupDirectory, includingPropertiesForKeys: nil)
        require(copies.filter { $0.lastPathComponent.hasPrefix("LifeBoard-sync-") }.count == 2, "both conflict versions are privately recoverable before resolution")
        require(store.commit({ $0.tasks[0].title = "Second local title" }), "second conflict fixture commits local edit")
        remote = store.data; remote.tasks[0].title = "Second remote title"
        SyncService.remote = SyncEnvelope(revision: 2, data: remote)
        await store.syncNow()
        let secondPath = store.syncConflicts[0].path
        remote.tasks[0].title = "Newest remote title"; remote.tasks[0].notes = "Independent remote note"; remote.tasks.append(TaskItem(title: "Independent remote task B"))
        SyncService.remote = SyncEnvelope(revision: 3, data: remote)
        await store.resolveSyncConflicts(choices: [secondPath: true])
        require(store.data.tasks[0].title == "Second local title" && SyncService.remote.data?.tasks[0].title == "Newest remote title" && store.syncConflicts.first?.remoteValue == "Newest remote title", "resolution detects a changed server revision and refreshes review before writing")
        await store.resolveSyncConflicts(choices: [secondPath: true])
        require(store.syncConflicts.isEmpty && store.data.tasks[0].title == "Second local title" && SyncService.remote.data?.tasks[0].title == "Second local title", "reviewed keep local choice converges through conditional revision write")
        require(store.data.tasks[0].notes == "Independent remote note" && store.data.tasks.contains(where: { $0.title == "Independent remote task B" }), "conflict resolution preserves independent remote fields and added records")
        let writesBefore = SyncService.writeCount
        await store.syncNow()
        require(SyncService.writeCount == writesBefore && store.syncConflicts.isEmpty && store.data.tasks[0].title == "Second local title", "an unchanged workspace syncs without rewriting the server copy")
    } catch { asyncState.error = error }
}
let asyncDeadline = Date.now.addingTimeInterval(20)
while !asyncState.finished && Date.now < asyncDeadline { RunLoop.current.run(until: Date.now.addingTimeInterval(0.01)) }
require(asyncState.finished && asyncState.error == nil, "async conflict safety checks completed without live services")
#endif

print("LifeBoard native safety suite passed")
