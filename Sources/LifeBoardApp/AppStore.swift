import AppKit
import Combine
import Foundation
import LifeBoardCore
import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

enum CalendarDragItem: Equatable {
    case task(UUID)
    case event(UUID)

    var payload: String {
        switch self {
        case .task(let id): id.uuidString
        case .event(let id): "event:\(id.uuidString)"
        }
    }
}

enum CalendarFileLink {
    static func isLocal(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && (url.host?.isEmpty != false || url.host == "localhost") && !url.lastPathComponent.isEmpty
    }

    static func urls(in notes: String) -> [URL] {
        notes.split(whereSeparator: \.isNewline).compactMap { line in
            guard let url = URL(string: String(line)), isLocal(url) else { return nil }
            return url
        }
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var data: LifeBoardData {
        didSet { index = PlannerIndex(data: data); scheduleFocusCompletion() }
    }
    /// Derived lookups for the views; rebuilt with every data change.
    private(set) var index: PlannerIndex
    /// Tasks completed a moment ago keep their place briefly (see PlannerIndex).
    @Published private(set) var lingeringCompletions: Set<UUID> = []
    /// The inspector registers its unsaved text here so quitting or switching
    /// tasks never loses a debounced edit.
    var pendingDraftFlush: (() -> Void)?
    /// UI requests raised by menu commands and observed by the window.
    @Published var rescheduleRequest: UUID?
    @Published var newTaskFocusRequest = 0
    @Published var inspectorFocusRequest = 0
    var revealInspectorOnSelect = false
    var inspectorFocusPending = false
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var housekeepingTimer: Timer?
    private var syncTimer: Timer?
    private var focusTimer: Timer?
    private var scheduledFocusID: UUID?
    private var observers: [NSObjectProtocol] = []
    @Published var selectedTaskID: UUID? { didSet { if selectedTaskID != nil { selectedEventID = nil } } }
    @Published var selectedEventID: UUID? { didSet { if selectedEventID != nil { selectedTaskID = nil } } }
    @Published var message: UserMessage?
    @Published var focusRequestTaskID: UUID?
    @Published var focusCompletion: FocusCompletion?
    @Published var requestedSectionRaw: String?
    @Published var pendingExternalImport: ExternalImportPreview?
    @Published private(set) var syncConflicts: [SyncConflictItem] = []
    @Published private(set) var lastSuccessfulSync: Date?
    @Published private(set) var connectedDevices: [SyncService.ConnectedDevice] = []
    @Published private(set) var pairingChallenge: SyncService.PairingChallenge?
    private var conflictContext: SyncConflictContext?
    @Published var externalCalendars: [ExternalCalendarChoice] = []
    @Published var calendarConnectionStatus = "Not connected"
    @Published private(set) var syncStatus = "Mobile sync is not set up"
    let repository: LifeBoardRepository
    private let calendarIntegration = CalendarIntegrationService()
    weak var undoManager: UndoManager?
    var calendarDrag: CalendarDragItem?
    var calendarScrollOffsets: [String: CGFloat] = [:]
    private var fileModificationDate: Date?
    private var lastICloudAttempt: Date?
    private var persistenceReadOnly = false
    private var syncInProgress = false
    private var syncEpoch = 0
    private var devicePreferences: DevicePreferences?
    private var lastSyncAttempt: Date = .distantPast
    private var lastCalendarAttempt: Date = .distantPast

    var mobileURL: URL? { SyncService.endpoint()?.deletingLastPathComponent().deletingLastPathComponent() }
    @Published private(set) var lastAutomaticBackup: Date?
    struct AvailableBackup: Identifiable { var id: String { url.path }; let url: URL; let date: Date? }
    func availableBackups() -> [AvailableBackup] {
        [repository.backupDirectory, repository.iCloudBackupDirectory].flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.pathExtension == "json" }.map { AvailableBackup(url: $0, date: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) }
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    init(repository: LifeBoardRepository = LifeBoardRepository()) {
        self.repository = repository
        var loaded = LifeBoardData()
        var loadError: Error?
        do {
            loaded = try repository.loadThrowing()
        } catch {
            // A damaged or temporarily unreadable file must never be replaced
            // with a freshly seeded workspace on the next user action.
            loadError = error
        }
        self.data = loaded
        self.index = PlannerIndex(data: loaded)
        if let loadError {
            self.persistenceReadOnly = true
            self.message = UserMessage(title: "LifeBoard Data Unavailable", detail: "Your existing data could not be read. LifeBoard has paused changes to protect it. " + loadError.localizedDescription)
        }
        if !persistenceReadOnly {
            let preferencesURL = repository.fileURL.deletingLastPathComponent().appendingPathComponent("DevicePreferences.json")
            devicePreferences = (try? Data(contentsOf: preferencesURL)).flatMap { try? LifeBoardJSON.decoder().decode(DevicePreferences.self, from: $0) } ?? DevicePreferences(data.settings)
            devicePreferences?.apply(to: &data.settings)
        }
        let backupStatusURL = repository.fileURL.deletingLastPathComponent().appendingPathComponent("BackupStatus.json")
        lastAutomaticBackup = (try? Data(contentsOf: backupStatusURL)).flatMap { try? JSONDecoder().decode(Date.self, from: $0) } ?? data.settings.lastICloudBackup
        self.fileModificationDate = Self.modificationDate(for: repository.fileURL)
        if !persistenceReadOnly && ProcessInfo.processInfo.environment["LIFEBOARD_DATA_PATH"] == nil {
            _ = try? LifeBoardSharedStore.writeSnapshot(data)
            WidgetCenter.shared.reloadAllTimelines()
        }
        calendarIntegration.onChange = { [weak self] in self?.refreshConnectedCalendarsIfNeeded(force: true) }
        refreshConnectedCalendarsIfNeeded(force: true)
        if SyncService.endpoint() != nil { syncStatus = "Connecting mobile…" }
        if LifeBoardEnvironment.isPreview { syncStatus = "Mobile sync is off in LifeBoard Preview" }
        index = PlannerIndex(data: data)
    }

    // MARK: Background work (event-driven; no per-second polling)

    /// Starts file watching and low-frequency housekeeping. Called once by the
    /// app; tests drive the same methods directly.
    func startBackgroundWork() {
        guard directoryWatcher == nil else { return }
        watchDataDirectory()
        housekeepingTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A slow fallback in case a file event is ever missed.
                self.reloadIfChanged()
                self.performICloudBackup()
                self.refreshConnectedCalendarsIfNeeded()
            }
        }
        housekeepingTimer?.tolerance = 10
        if SyncService.endpoint() != nil {
            syncTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.syncTick() } }
            syncTimer?.tolerance = 3
            syncTick()
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.temporalContextChanged() } })
        observers.append(center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { NSTimeZone.resetSystemTimeZone(); self?.temporalContextChanged() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.temporalContextChanged(); self?.reloadIfChanged(); self?.tickFocus() }
        })
        performICloudBackup()
        scheduleFocusCompletion()
    }

    /// The date or time zone changed: rebuild "today" and every derived view.
    func temporalContextChanged() {
        index = PlannerIndex(data: data)
        temporalRevision += 1
        objectWillChange.send()
    }
    @Published private(set) var temporalRevision = 0

    private func watchDataDirectory() {
        let directory = repository.fileURL.deletingLastPathComponent()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // Atomic writes by the helper or another app replace the file
                // inside this folder; our own writes are recognised by mtime.
                self?.reloadIfChanged()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        directoryWatcher = source
    }

    /// One-shot timer at the moment the active focus or break ends.
    private func scheduleFocusCompletion() {
        let active = data.activeFocus
        let key = active.flatMap { $0.pausedAt == nil ? $0.id : nil }
        guard key != scheduledFocusID else { return }
        focusTimer?.invalidate(); focusTimer = nil; scheduledFocusID = key
        guard let active, active.pausedAt == nil else { return }
        let remaining = max(0.5, Double(active.plannedMinutes * 60) - active.elapsedSeconds())
        focusTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.tickFocus() } }
        focusTimer?.tolerance = 0.2
    }

    /// Flushes any debounced inspector edit. Called before quitting.
    func flushPendingDrafts() {
        let flush = pendingDraftFlush
        pendingDraftFlush = nil
        flush?()
    }

    // MARK: Completion

    /// Completes or reopens a task. A newly completed task lingers in place for
    /// a moment (still saved immediately) so the list never jumps under the pointer.
    func toggleCompletion(_ id: UUID, reduceMotion: Bool = false) {
        guard let task = data.tasks.first(where: { $0.id == id }) else { return }
        let completing = !task.isCompleted
        toggleTask(id)
        guard completing, data.tasks.first(where: { $0.id == id })?.isCompleted == true else {
            lingeringCompletions.remove(id); return
        }
        lingeringCompletions.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.6 : 0.9)) { [weak self] in
            guard let self, self.lingeringCompletions.contains(id) else { return }
            withMotion(Motion.move(reduceMotion)) { _ = self.lingeringCompletions.remove(id) }
        }
    }

    struct ExternalImportPreview: Identifiable { let id = UUID(); let source: String; let tasks: [TaskItem] }
    struct SyncConflictItem: Identifiable { var id: String { path }; let path: String; let localValue: String; let remoteValue: String }
    private struct SyncConflictContext { let revision: Int; let base: LifeBoardData; let local: LifeBoardData; let remote: LifeBoardData; let paths: [String] }

    struct UserMessage: Identifiable { let id = UUID(); let title: String; let detail: String }
    struct FocusCompletion: Identifiable {
        let id = UUID()
        let taskID: UUID?
        let taskTitle: String
        let plannedMinutes: Int
    }
    struct BackupSummary: Identifiable {
        let id = UUID(); let url: URL; let schemaVersion: Int; let tasks: Int; let projects: Int; let subjects: Int; let focusSessions: Int
    }

    @discardableResult func commit(actionName: String = "Change", _ change: (inout LifeBoardData) -> Void) -> Bool {
        let previous = data
        var next = data; change(&next)
        guard next != previous else { return true }
        do {
            let patch = try LifeBoardDataPatch(before: previous, after: next)
            guard !patch.isEmpty else { return true }
            guard persist(next) else { return false }
            registerUndo(patch.reversed(), actionName: actionName)
            return true
        } catch { message = UserMessage(title: "Couldn't Save", detail: error.localizedDescription); return false }
    }

    private func registerUndo(_ patch: LifeBoardDataPatch, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.applyUndo(patch, actionName: actionName) }
        }
        undoManager?.setActionName(actionName)
    }

    private func applyUndo(_ patch: LifeBoardDataPatch, actionName: String) {
        do {
            // Refresh first: even a helper edit between polls must survive Undo.
            reloadIfChanged()
            let next = try patch.applying(to: data)
            let previousPreferences = devicePreferences
            devicePreferences = DevicePreferences(next.settings)
            guard persist(next) else { devicePreferences = previousPreferences; return }
            registerUndo(patch.reversed(), actionName: actionName)
        } catch { message = UserMessage(title: "Undo Needs Review", detail: "A field changed since this action. Your newer work has been preserved. " + error.localizedDescription) }
    }

    @discardableResult private func persist(_ next: LifeBoardData) -> Bool {
        guard !persistenceReadOnly else {
            message = UserMessage(title: "Changes Paused", detail: "LifeBoard cannot read your existing data, so it will not replace it. Restore a backup or reopen the app after the file is available.")
            return false
        }
        do {
            var local = next
            devicePreferences?.apply(to: &local.settings)
            let durable = try repository.saveReturning(local)
            data = durable
            saveDevicePreferences()
            reconcileSelections()
            fileModificationDate = Self.modificationDate(for: repository.fileURL)
            if ProcessInfo.processInfo.environment["LIFEBOARD_DATA_PATH"] == nil {
                let changed = (try? LifeBoardSharedStore.writeSnapshot(durable)) ?? false
                #if canImport(WidgetKit)
                if changed { WidgetCenter.shared.reloadAllTimelines() }
                #endif
            }
            NotificationCoordinator.shared.refresh(durable)
            return true
        } catch {
            message = UserMessage(title: "Couldn't Save", detail: error.localizedDescription)
            return false
        }
    }

    private func reconcileSelections() {
        if let id = selectedTaskID, !data.tasks.contains(where: { $0.id == id && !$0.isArchived }) { selectedTaskID = nil }
        if let id = selectedEventID, !data.events.contains(where: { $0.id == id }) { selectedEventID = nil }
    }

    @discardableResult func addTask(title: String, scheduledDay: LocalDay? = nil) -> UUID? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        var task = TaskItem(title: clean); task.estimatedMinutes = data.settings.defaultTaskMinutes; task.scheduledDay = scheduledDay
        guard commit(actionName: "Create Task", { $0.tasks.append(task) }) else { return nil }; selectedTaskID = task.id; return task.id
    }

    @discardableResult func addTask(_ task: TaskItem) -> UUID {
        if commit(actionName: "Create Task", { $0.tasks.append(task) }) { selectedTaskID = task.id }; return task.id
    }

    func addTasks(_ tasks: [TaskItem]) {
        guard !tasks.isEmpty else { return }
        commit(actionName: "Import Tasks") { $0.tasks.append(contentsOf: tasks) }
    }

    @discardableResult func addCapturedItems(tasks: [TaskItem], events: [CalendarEvent]) -> Bool {
        var candidate = data
        for task in tasks {
            if let day = task.scheduledDay, let start = task.scheduledStartMinutes {
                let end = start + (task.scheduledDurationMinutes ?? task.estimatedMinutes)
                let busy = SchedulingEngine.busyIntervals(data: candidate, day: day)
                let tomorrowBusy = end > 1440 ? SchedulingEngine.busyIntervals(data: candidate, day: day.adding(days: 1)) : []
                if busy.contains(where: { start < $0.end && min(1440, end) > $0.start }) || tomorrowBusy.contains(where: { 0 < $0.end && end - 1440 > $0.start }) {
                    message = UserMessage(title: "Capture Time Conflicts", detail: "\(task.title) overlaps another calendar item. Choose another time or remove its exact time."); return false
                }
            }
            candidate.tasks.append(task)
        }
        for event in events {
            if SchedulingEngine.busyIntervals(data: candidate, day: event.day).contains(where: { event.startMinutes < $0.end && event.endMinutes > $0.start }) {
                message = UserMessage(title: "Capture Time Conflicts", detail: "\(event.title) overlaps another calendar item. Choose another time."); return false
            }
            candidate.events.append(event)
        }
        return commit(actionName: "Accept Capture") { $0 = candidate }
    }

    func updateTask(_ task: TaskItem) {
        guard let current = data.tasks.first(where: { $0.id == task.id }) else { return }
        _ = updateTask(task, basedOn: current)
    }

    /// Draft writes include only changed fields and compare their original values.
    @discardableResult func updateTask(_ draft: TaskItem, basedOn baseline: TaskItem) -> Bool {
        guard draft.id == baseline.id, let current = data.tasks.first(where: { $0.id == draft.id && !$0.isArchived }) else { selectedTaskID = nil; return false }
        do {
            var before = LifeBoardData(); before.tasks = [baseline]
            var after = LifeBoardData(); after.tasks = [draft]
            // Apply against the full workspace to preserve incoming associations.
            let patch = try LifeBoardDataPatch(before: before, after: after)
            var next = try patch.applying(to: data)
            guard let index = next.tasks.firstIndex(where: { $0.id == current.id }) else { return false }
            if let progress = next.tasks[index].completionPercent {
                next.tasks[index].isCompleted = progress >= 100
                next.tasks[index].completedAt = progress >= 100 ? (current.completedAt ?? .now) : nil
            }
            next.tasks[index].modifiedAt = .now
            if !current.isCompleted && next.tasks[index].isCompleted { RecurrenceEngine.appendNextOccurrence(after: next.tasks[index], in: &next) }
            return commit(actionName: "Edit Task") { $0 = next }
        } catch { message = UserMessage(title: "Task Changed Elsewhere", detail: "Your draft has not overwritten the newer value. " + error.localizedDescription); return false }
    }

    /// Connected events use their calendar's own colour, as in Calendar.
    func connectedColour(_ calendarID: String) -> Color {
        calendarIntegration.colour(forCalendarID: calendarID).map { Color(nsColor: $0) } ?? LB.connected
    }

    func setTaskProgress(_ id: UUID, percent: Double) {
        commit(actionName: "Change Task Progress") { value in
            guard let i = value.tasks.firstIndex(where: { $0.id == id }) else { return }
            let wasCompleted = value.tasks[i].isCompleted
            let amount = min(100, max(0, percent))
            value.tasks[i].completionPercent = amount
            value.tasks[i].isCompleted = amount >= 100
            value.tasks[i].completedAt = amount >= 100 ? (value.tasks[i].completedAt ?? .now) : nil
            value.tasks[i].modifiedAt = .now
            if !wasCompleted && amount >= 100 {
                let task = value.tasks[i]
                RecurrenceEngine.appendNextOccurrence(after: task, in: &value)
                value.activity.insert(ActivityRecord(kind: .taskCompleted, title: "Completed \"\(task.title)\"", subjectID: task.subjectID, topicID: task.topicID, projectID: task.projectID), at: 0)
            }
        }
    }

    func toggleTask(_ id: UUID) {
        commit(actionName: "Complete Task") { value in
            guard let i = value.tasks.firstIndex(where: { $0.id == id }) else { return }
            value.tasks[i].isCompleted.toggle(); value.tasks[i].completedAt = value.tasks[i].isCompleted ? .now : nil; value.tasks[i].modifiedAt = .now
            value.tasks[i].completionPercent = value.tasks[i].isCompleted ? 100 : 0
            guard value.tasks[i].isCompleted else { return }
            let task = value.tasks[i]
            RecurrenceEngine.appendNextOccurrence(after: task, in: &value)
            value.activity.insert(ActivityRecord(kind: .taskCompleted, title: "Completed \"\(task.title)\"", subjectID: task.subjectID, topicID: task.topicID, projectID: task.projectID), at: 0)
            if let sid = task.subjectID, let s = value.subjects.firstIndex(where: { $0.id == sid }) {
                value.subjects[s].lastActivity = .now
                if let tid = task.topicID, let t = value.subjects[s].topics.firstIndex(where: { $0.id == tid }) { value.subjects[s].topics[t].lastActivity = .now }
            }
            if let pid = task.projectID, let p = value.projects.firstIndex(where: { $0.id == pid }) { value.projects[p].lastActivity = .now }
        }
    }

    func schedule(_ id: UUID, day: LocalDay, startMinutes: Int? = nil) {
        commit(actionName: "Schedule Task") { value in guard let i = value.tasks.firstIndex(where: { $0.id == id }) else { return }; value.tasks[i].scheduledDay = day; value.tasks[i].scheduledStartMinutes = startMinutes; value.tasks[i].scheduledDurationMinutes = startMinutes == nil ? nil : value.tasks[i].estimatedMinutes; value.tasks[i].modifiedAt = .now }
    }

    @discardableResult func moveScheduledTask(_ id: UUID, day: LocalDay, startMinutes: Int? = nil) -> Bool {
        guard let index = data.tasks.firstIndex(where: { $0.id == id && !$0.isCompleted && !$0.isArchived }) else { return false }
        let task = data.tasks[index]
        let start = startMinutes ?? task.scheduledStartMinutes
        guard task.scheduledDay != day || task.scheduledStartMinutes != start else { return true }
        return commit(actionName: "Move Scheduled Task") { value in
            value.tasks[index].scheduledDay = day
            value.tasks[index].scheduledStartMinutes = start
            if task.scheduledStartMinutes == nil, start != nil {
                value.tasks[index].scheduledDurationMinutes = task.estimatedMinutes
            }
            value.tasks[index].modifiedAt = .now
        }
    }

    @discardableResult func addCalendarFiles(_ urls: [URL], day: LocalDay, startMinutes: Int?) -> Bool {
        guard let first = urls.first, urls.allSatisfy({ CalendarFileLink.isLocal($0) }) else { return false }
        let title = urls.count == 1 ? first.lastPathComponent : "Review \(urls.count) files"
        var task = TaskItem(title: title)
        task.notes = urls.map(\.absoluteString).joined(separator: "\n")
        task.estimatedMinutes = data.settings.defaultTaskMinutes
        task.scheduledDay = day
        task.scheduledStartMinutes = startMinutes
        task.scheduledDurationMinutes = startMinutes.map { _ in task.estimatedMinutes }
        return commit(actionName: "Schedule Files") { $0.tasks.append(task) }
    }

    @discardableResult func unscheduleTime(_ id: UUID, day: LocalDay? = nil) -> Bool {
        guard let index = data.tasks.firstIndex(where: { $0.id == id }) else { return false }
        return commit(actionName: "Unschedule Task") { value in
            value.tasks[index].scheduledDay = day ?? value.tasks[index].scheduledDay
            value.tasks[index].scheduledStartMinutes = nil
            value.tasks[index].scheduledDurationMinutes = nil
        }
    }

    func resizeTask(_ id: UUID, durationMinutes: Int) {
        commit { value in
            guard let i = value.tasks.firstIndex(where: { $0.id == id }) else { return }
            value.tasks[i].scheduledDurationMinutes = min(8 * 60, max(15, durationMinutes))
            value.tasks[i].modifiedAt = .now
        }
    }

    func moveToInbox(_ id: UUID) { commit(actionName: "Remove from Calendar") { value in guard let i = value.tasks.firstIndex(where: { $0.id == id }) else { return }; value.tasks[i].scheduledDay = nil; value.tasks[i].scheduledStartMinutes = nil } }
    func archiveTask(_ id: UUID) { commit { value in guard let i = value.tasks.firstIndex(where: { $0.id == id }) else { return }; value.tasks[i].isArchived = true; value.tasks[i].archivedAt = .now; value.tasks[i].modifiedAt = .now } }
    func deleteTask(_ id: UUID) { commit(actionName: "Move Task to Trash") { value in if let i = value.tasks.firstIndex(where: { $0.id == id }) { value.tasks[i].isArchived = true; value.tasks[i].archivedAt = .now; value.tasks[i].modifiedAt = .now } }; if selectedTaskID == id { selectedTaskID = nil } }
    func restoreTask(_ id: UUID) { commit(actionName: "Restore Task") { value in if let i = value.tasks.firstIndex(where: { $0.id == id }) { value.tasks[i].isArchived = false; value.tasks[i].archivedAt = nil; value.tasks[i].modifiedAt = .now } } }
    func duplicateTask(_ id: UUID) { guard var task = data.tasks.first(where: { $0.id == id }) else { return }; task.id = UUID(); task.title += " Copy"; task.createdAt = .now; task.modifiedAt = .now; task.isCompleted = false; task.completedAt = nil; task.completionPercent = 0; commit { $0.tasks.append(task) } }
    func setDueDay(_ id: UUID, day: LocalDay?) { commit(actionName: "Change Due Date") { value in guard let i = value.tasks.firstIndex(where: { $0.id == id }) else { return }; value.tasks[i].dueDay = day; value.tasks[i].modifiedAt = .now } }
    func setSubject(_ id: UUID, subjectID: UUID?) { commit { value in guard let i = value.tasks.firstIndex(where: { $0.id == id }) else { return }; value.tasks[i].subjectID = subjectID; value.tasks[i].topicID = nil; value.tasks[i].modifiedAt = .now } }
    func setProject(_ id: UUID, projectID: UUID?) { commit { value in guard let i = value.tasks.firstIndex(where: { $0.id == id }) else { return }; value.tasks[i].projectID = projectID; value.tasks[i].modifiedAt = .now } }
    func setEstimatedMinutes(_ id: UUID, minutes: Int) { commit { value in guard let i = value.tasks.firstIndex(where: { $0.id == id }) else { return }; value.tasks[i].estimatedMinutes = min(480, max(5, minutes)); value.tasks[i].modifiedAt = .now } }
    func setKanbanStage(_ id: UUID, stage: KanbanStage) {
        commit(actionName: "Move Kanban Card") { value in
            guard let i = value.tasks.firstIndex(where: { $0.id == id }) else { return }
            value.tasks[i].tags.removeAll { $0.hasPrefix("workflow:") }
            value.tasks[i].isCompleted = stage == .done
            value.tasks[i].completedAt = stage == .done ? .now : nil
            value.tasks[i].completionPercent = stage == .done ? 100 : 0
            if stage != .backlog && stage != .done { value.tasks[i].tags.append(stage.tag) }
            value.tasks[i].modifiedAt = .now
        }
    }

    func requestFocus(_ taskID: UUID) { focusRequestTaskID = taskID }

    func startFocus(taskID: UUID, minutes: Int) {
        guard let task = data.tasks.first(where: { $0.id == taskID }) else { return }
        let active = ActiveFocusSession(kind: .focus, taskID: task.id, taskTitle: task.title, subjectID: task.subjectID, projectID: task.projectID, plannedMinutes: min(240, max(1, minutes)))
        commit { $0.activeFocus = active }
        NotificationCoordinator.shared.scheduleFocus(active, enabled: data.settings.notificationsFocus)
        focusRequestTaskID = nil
    }

    func startFocus(minutes: Int, taskID: UUID? = nil, subjectID: UUID? = nil, projectID: UUID? = nil) {
        if let taskID { startFocus(taskID: taskID, minutes: minutes); return }
        let subjectTitle = subjectID.flatMap { id in data.subjects.first(where: { $0.id == id })?.title }
        let projectTitle = projectID.flatMap { id in data.projects.first(where: { $0.id == id })?.title }
        let title = subjectTitle ?? projectTitle ?? "Focus session"
        let active = ActiveFocusSession(kind: .focus, taskID: nil, taskTitle: title, subjectID: subjectID, projectID: projectID, plannedMinutes: min(240, max(1, minutes)))
        commit { $0.activeFocus = active }
        NotificationCoordinator.shared.scheduleFocus(active, enabled: data.settings.notificationsFocus)
    }

    func startBreak(minutes: Int? = nil) {
        let active = ActiveFocusSession(kind: .shortBreak, taskID: nil, taskTitle: "Short break", plannedMinutes: min(60, max(1, minutes ?? data.settings.breakMinutes)))
        commit { $0.activeFocus = active }
        NotificationCoordinator.shared.scheduleFocus(active, enabled: data.settings.notificationsFocus)
        focusCompletion = nil
    }

    func pauseFocus() {
        guard data.activeFocus?.pausedAt == nil else { return }
        commit { $0.activeFocus?.pausedAt = .now }
        NotificationCoordinator.shared.cancelFocus()
    }

    func resumeFocus() {
        guard let pausedAt = data.activeFocus?.pausedAt else { return }
        commit { value in
            value.activeFocus?.pausedSeconds += Date.now.timeIntervalSince(pausedAt)
            value.activeFocus?.pausedAt = nil
        }
        if let active = data.activeFocus { NotificationCoordinator.shared.scheduleFocus(active, enabled: data.settings.notificationsFocus) }
    }

    func stopFocus(completedTimer: Bool = false, showCompletion: Bool = false) {
        guard let active = data.activeFocus else { return }
        if !completedTimer { NotificationCoordinator.shared.cancelFocus() }
        let record = FocusSessionRecord(from: active, completedTimer: completedTimer)
        commit { value in
            if record.focusedSeconds > 0 && !value.focusSessions.contains(where: { $0.id == active.id }) { value.focusSessions.insert(record, at: 0) }
            value.activeFocus = nil
        }
        if showCompletion, active.kind == .focus {
            focusCompletion = FocusCompletion(taskID: active.taskID, taskTitle: active.taskTitle, plannedMinutes: active.plannedMinutes)
        }
    }

    func resetFocus() { NotificationCoordinator.shared.cancelFocus(); commit { $0.activeFocus = nil }; focusCompletion = nil }

    func tickFocus(now: Date = .now) {
        guard let active = data.activeFocus, active.pausedAt == nil,
              active.elapsedSeconds(at: now) >= Double(active.plannedMinutes * 60) else { return }
        stopFocus(completedTimer: true, showCompletion: true)
    }

    func focusedSeconds(subjectID: UUID? = nil, projectID: UUID? = nil, since: Date? = nil) -> Int {
        data.focusSessions.filter { record in
            record.kind == .focus && (subjectID.map { record.subjectID == $0 } ?? true) && (projectID.map { record.projectID == $0 } ?? true) && (since.map { record.endedAt >= $0 } ?? true)
        }.reduce(0) { $0 + $1.focusedSeconds }
    }

    func addEvent(title: String, day: LocalDay) { commit { $0.events.append(CalendarEvent(title: title, day: day, startMinutes: 18 * 60, endMinutes: 19 * 60)) } }
    func addEvent(_ event: CalendarEvent) { commit { $0.events.append(event) }; selectedEventID = event.id }
    func updateEvent(_ event: CalendarEvent) { commit { value in if let i = value.events.firstIndex(where: { $0.id == event.id }) { value.events[i] = event } } }
    @discardableResult func moveEvent(_ id: UUID, day: LocalDay, startMinutes: Int) -> Bool {
        guard let index = data.events.firstIndex(where: { $0.id == id }) else { return false }
        let event = data.events[index]
        let duration = event.endMinutes - event.startMinutes
        let start = min(1440 - duration, max(0, startMinutes))
        return commit(actionName: "Move Event") { value in
            value.events[index].day = day
            value.events[index].startMinutes = start
            value.events[index].endMinutes = start + duration
        }
    }
    func duplicateEvent(_ id: UUID) { guard var event = data.events.first(where: { $0.id == id }) else { return }; event.id = UUID(); event.title += " Copy"; commit { $0.events.append(event) }; selectedEventID = event.id }
    func deleteEvent(_ id: UUID) { commit { $0.events.removeAll { $0.id == id } }; if selectedEventID == id { selectedEventID = nil } }
    func addSubject(title: String) { guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }; commit { $0.subjects.append(LifeBoardCore.Subject(title: title)) } }
    func updateSubject(_ subject: LifeBoardCore.Subject) { commit { value in if let i = value.subjects.firstIndex(where: { $0.id == subject.id }) { let old = value.subjects[i]; value.subjects[i] = subject; if old.confidence != subject.confidence { value.subjects[i].confidenceHistory.append(MetricRecord(value: subject.confidence)); value.activity.insert(ActivityRecord(kind: .confidenceChanged, title: "Confidence updated for \(subject.title)", subjectID: subject.id), at: 0) } } } }
    func addTopic(_ title: String, subjectID: UUID) { commit { value in if let i = value.subjects.firstIndex(where: { $0.id == subjectID }), !title.isEmpty { value.subjects[i].topics.append(Topic(title: title)) } } }

    @discardableResult func importTopics(_ drafts: [TopicImportDraft], subjectID: UUID) -> Bool {
        guard data.subjects.contains(where: { $0.id == subjectID && !$0.archived }) else { message = UserMessage(title: "Subject Unavailable", detail: "The subject changed or was archived. Review the import again."); return false }
        return commit(actionName: "Import Topics") { value in
            guard let index = value.subjects.firstIndex(where: { $0.id == subjectID && !$0.archived }) else { return }
            let accepted = TopicImportParser.accepted(drafts, existing: value.subjects[index].topics.map(\.title))
            for proposal in accepted { var topic = Topic(title: proposal.title); topic.notes = proposal.originalLine; value.subjects[index].topics.append(topic) }
        }
    }

    func addProject(title: String) { guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }; commit { $0.projects.append(Project(title: title)) } }
    func updateProject(_ project: Project) { commit { value in if let i = value.projects.firstIndex(where: { $0.id == project.id }) { let old = value.projects[i]; value.projects[i] = project; if old.progress != project.progress { value.projects[i].progressHistory.append(MetricRecord(value: project.progress)) } } } }
    func addMilestone(title: String, projectID: UUID, day: LocalDay) { commit { value in if let i = value.projects.firstIndex(where: { $0.id == projectID }), !title.isEmpty { value.projects[i].milestones.append(ProjectMilestone(title: title, targetDay: day)) } } }
    func toggleMilestone(_ milestoneID: UUID, projectID: UUID) {
        commit { value in
            guard let p = value.projects.firstIndex(where: { $0.id == projectID }), let m = value.projects[p].milestones.firstIndex(where: { $0.id == milestoneID }) else { return }
            value.projects[p].milestones[m].isCompleted.toggle()
            value.projects[p].lastActivity = .now
            if value.projects[p].milestones[m].isCompleted {
                value.activity.insert(ActivityRecord(kind: .milestoneCompleted, title: "Completed milestone \"\(value.projects[p].milestones[m].title)\"", projectID: projectID), at: 0)
            }
        }
    }
    func addProgress(_ text: String, projectID: UUID) { commit { value in guard let i = value.projects.firstIndex(where: { $0.id == projectID }), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; value.projects[i].updates.insert(ProgressUpdate(text: text), at: 0); value.projects[i].lastActivity = .now; value.activity.insert(ActivityRecord(kind: .progressAdded, title: "Progress note added", projectID: projectID), at: 0) } }
    func addYearMarker(title: String, day: LocalDay, category: String = "Important Date", notes: String = "", subjectID: UUID? = nil) {
        guard !title.isEmpty else { return }
        commit(actionName: "Add Important Date") { value in
            var marker = YearMarker(title: title, startDay: day)
            marker.category = category
            marker.notes = notes
            marker.subjectID = subjectID
            value.yearMarkers.append(marker)
        }
    }
    func updateYearMarker(_ marker: YearMarker) { commit(actionName: "Edit Important Date") { value in if let i = value.yearMarkers.firstIndex(where: { $0.id == marker.id }) { value.yearMarkers[i] = marker } } }
    func deleteYearMarker(_ id: UUID) { commit(actionName: "Delete Important Date") { $0.yearMarkers.removeAll { $0.id == id } } }
    func updateSettings(_ settings: AppSettings) {
        let previousAutomaticICloudBackup = data.settings.automaticICloudBackup
        let enablingNotifications = (!data.settings.notificationsScheduledItems && settings.notificationsScheduledItems) || (!data.settings.notificationsDeadlines && settings.notificationsDeadlines) || (!data.settings.notificationsFocus && settings.notificationsFocus)
        let previousPreferences = devicePreferences
        devicePreferences = DevicePreferences(settings)
        guard commit(actionName: "Settings", { $0.settings = settings }) else { devicePreferences = previousPreferences; return }
        if enablingNotifications { NotificationCoordinator.shared.requestAndRefresh(data) }
        if settings.automaticICloudBackup && !previousAutomaticICloudBackup { performICloudBackup(force: true) }
    }

    private func saveDevicePreferences() {
        guard let preferences = devicePreferences else { return }
        do {
            let encoder = LifeBoardJSON.encoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(preferences)
            let url = repository.fileURL.deletingLastPathComponent().appendingPathComponent("DevicePreferences.json")
            if (try? Data(contentsOf: url)) != bytes { try LifeBoardPrivateFiles.write(bytes, to: url) }
        } catch { message = UserMessage(title: "Device Preferences", detail: "Settings are saved in your planner, but the separate device copy could not be written. " + error.localizedDescription) }
    }

    func connectGoogleCalendar() async {
        calendarConnectionStatus = "Connecting…"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            if self?.calendarConnectionStatus == "Connecting…" {
                self?.calendarConnectionStatus = "Calendar permission has not responded. Your previously synced calendar events remain available."
            }
        }
        guard await calendarIntegration.requestAccess() else { calendarConnectionStatus = calendarIntegration.accessGuidance; return }
        externalCalendars = calendarIntegration.availableCalendars()
        guard !externalCalendars.isEmpty else { calendarConnectionStatus = "No connected calendars are available in macOS"; return }
        calendarConnectionStatus = "Connected through macOS Internet Accounts"
        if data.settings.selectedExternalCalendarIDs.isEmpty && data.settings.lastExternalCalendarRefresh == nil {
            var settings = data.settings; settings.selectedExternalCalendarIDs = externalCalendars.map(\.id); updateSettings(settings)
        }
        await refreshGoogleCalendar()
    }

    func refreshSelectedCalendarsNow() async -> String {
        guard !data.settings.selectedExternalCalendarIDs.isEmpty else {
            return "No calendars are selected. Choose calendars in Settings › Integrations."
        }
        await refreshGoogleCalendar(pullFromAccounts: true)
        return calendarConnectionStatus
    }

    func refreshGoogleCalendar(pullFromAccounts: Bool = false) async {
        lastCalendarAttempt = .now
        guard calendarIntegration.hasFullAccess else {
            calendarConnectionStatus = calendarIntegration.accessGuidance
            return
        }
        if pullFromAccounts { calendarIntegration.refreshAccountSources() }
        calendarIntegration.refreshLocalStore()
        externalCalendars = calendarIntegration.availableCalendars()
        let selected = data.settings.selectedExternalCalendarIDs
        let availableIDs = Set(externalCalendars.map(\.id))
        guard selected.isEmpty || selected.contains(where: availableIDs.contains) else {
            calendarConnectionStatus = "Selected calendars are temporarily unavailable. Saved events are kept."
            return
        }
        let start = Calendar.current.date(byAdding: .month, value: -2, to: .now) ?? .now
        let end = Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now
        let events = calendarIntegration.events(calendarIDs: selected, from: start, to: end)
        // A temporarily unavailable account must not erase its saved events.
        let retained = data.externalEvents.filter { selected.contains($0.calendarID) && !availableIDs.contains($0.calendarID) }
        guard calendarIntegration.hasFullAccess else {
            calendarConnectionStatus = calendarIntegration.accessGuidance
            return
        }
        let refreshedAt = Date.now
        let previousPreferences = devicePreferences
        devicePreferences?.lastExternalCalendarRefresh = refreshedAt
        var refreshed = data
        refreshed.externalEvents = (events + retained).sorted { $0.id < $1.id }
        refreshed.settings.lastExternalCalendarRefresh = refreshedAt
        // Derived calendar updates must not take the place of the person's
        // most recent task edit in Undo. Save cache and refresh date together.
        guard persist(refreshed) else {
            devicePreferences = previousPreferences
            calendarConnectionStatus = "Calendar refresh could not be saved. Your previous events are kept."
            return
        }
        calendarConnectionStatus = externalCalendars.isEmpty ? "No connected calendars found" : "Refreshed at \(refreshedAt.formatted(date: .omitted, time: .shortened))"
    }

    func refreshConnectedCalendarsIfNeeded(now: Date = .now, force: Bool = false) {
        guard !persistenceReadOnly, !data.settings.selectedExternalCalendarIDs.isEmpty else { return }
        guard force || now.timeIntervalSince(lastCalendarAttempt) >= 300 else { return }
        lastCalendarAttempt = now
        Task { [weak self] in await self?.refreshGoogleCalendar() }
    }

    func setExternalCalendar(_ id: String, enabled: Bool) {
        setExternalCalendars([id], enabled: enabled)
    }

    func setExternalCalendars(_ ids: [String], enabled: Bool) {
        var settings = data.settings
        if enabled {
            for id in ids where !settings.selectedExternalCalendarIDs.contains(id) { settings.selectedExternalCalendarIDs.append(id) }
        } else {
            settings.selectedExternalCalendarIDs.removeAll { ids.contains($0) }
        }
        updateSettings(settings)
        Task { await refreshGoogleCalendar() }
    }

    func openInternetAccounts() { calendarIntegration.openInternetAccounts() }
    func showExternalEvent(_ event: ExternalCalendarEvent) {
        let time = event.isAllDay ? "All day" : "\(String(format: "%02d:%02d", event.startMinutes / 60, event.startMinutes % 60))–\(String(format: "%02d:%02d", event.endMinutes / 60, event.endMinutes % 60))"
        message = UserMessage(title: event.title, detail: "\(time) · \(event.calendarTitle)\(event.location.isEmpty ? "" : "\n\(event.location)")")
    }

    func importTask(json: String) {
        do { let payload = try repository.decodePayload(json); let task = try repository.makeTask(from: payload, in: data); if commit({ $0.tasks.append(task) }) { message = UserMessage(title: "Task Added", detail: "\"\(task.title)\" is now in LifeBoard.") } }
        catch { message = UserMessage(title: "Couldn't Import", detail: error.localizedDescription) }
    }

    func acceptExternalImport() {
        guard let preview = pendingExternalImport else { return }
        if commit(actionName: "Import Reviewed Tasks", { $0.tasks.append(contentsOf: preview.tasks) }) { pendingExternalImport = nil; requestedSectionRaw = "today" }
    }
    func cancelExternalImport() { pendingExternalImport = nil }
    private func previewExternalImport(_ json: String, source: String) {
        do {
            let payloads = try repository.decodePayloads(json)
            let tasks = try payloads.map { try repository.makeTask(from: $0, in: data) }
            var next = data; next.tasks.append(contentsOf: tasks); try LifeBoardValidation.validate(next)
            pendingExternalImport = ExternalImportPreview(source: source, tasks: tasks)
        } catch { message = UserMessage(title: "Couldn't Review Import", detail: error.localizedDescription) }
    }

    func handle(url: URL) {
        guard url.scheme == LifeBoardEnvironment.urlScheme else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if url.host == "task", url.path == "/create" {
            if let json = items.first(where: { $0.name == "payload" })?.value { previewExternalImport(json, source: "External LifeBoard link") }
            else if let title = items.first(where: { $0.name == "title" })?.value { if let bytes = try? JSONEncoder().encode(TaskImportPayload(title: title)) { previewExternalImport(String(decoding: bytes, as: UTF8.self), source: "External LifeBoard link") } }
            else { message = UserMessage(title: "Couldn't Import", detail: "The link didn't include a task title or payload.") }
        } else if url.host == "import", let json = items.first(where: { $0.name == "payload" })?.value {
            previewExternalImport(json, source: "External batch import link")
        } else if url.host == "todo" {
            requestedSectionRaw = "inbox"
        } else if let host = url.host, let section = ["today": "today", "upcoming": "inbox", "subjects": "subjects", "projects": "projects", "dates": "year", "completed": "completed"][host], url.path.isEmpty || url.path == "/" {
            // Plain section links, for Shortcuts, Raycast and the widget.
            requestedSectionRaw = section
        } else if url.host == "calendar" {
            requestedSectionRaw = "calendar"
            if let view = items.first(where: { $0.name == "view" })?.value, ["day", "week", "month", "today"].contains(view) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(name: Notification.Name("LifeBoardCalendarCommand"), object: view)
                }
            }
        } else if url.host == "focus", url.path.isEmpty || url.path == "/" {
            requestedSectionRaw = "focus"
        } else if url.host == "task", let id = UUID(uuidString: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) {
            selectedTaskID = id; requestedSectionRaw = "today"
        } else if url.host == "focus", let id = UUID(uuidString: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) {
            requestFocus(id); requestedSectionRaw = "today"
        } else {
            message = UserMessage(title: "Unsupported Link", detail: "This LifeBoard link isn't recognised.")
        }
    }

    @discardableResult func exportBackup() -> URL? {
        do {
            let url: URL
            if persistenceReadOnly { url = try repository.exportOriginal(); message = UserMessage(title: "Original File Preserved", detail: "This exact-byte recovery copy may require a newer LifeBoard version or repair. " + url.path) }
            else { url = try repository.export(repository.durableSnapshot()); message = UserMessage(title: "Backup Created", detail: "Readable JSON contains your planner data. Store or share it only where intended. " + url.path) }
            return url
        }
        catch { message = UserMessage(title: "Couldn't Export", detail: error.localizedDescription); return nil }
    }

    func inspectBackup(_ url: URL) -> BackupSummary? {
        do { let value = try repository.importBackup(from: url); return BackupSummary(url: url, schemaVersion: value.schemaVersion, tasks: value.tasks.count, projects: value.projects.count, subjects: value.subjects.count, focusSessions: value.focusSessions.count) }
        catch { message = UserMessage(title: "Couldn't Read Backup", detail: error.localizedDescription); return nil }
    }

    func replaceWithBackup(_ url: URL) {
        do {
            data = try repository.replaceFromBackup(from: url)
            devicePreferences = DevicePreferences(data.settings)
            saveDevicePreferences()
            persistenceReadOnly = false; fileModificationDate = Self.modificationDate(for: repository.fileURL)
            undoManager?.removeAllActions(); reconcileSelections()
            if ProcessInfo.processInfo.environment["LIFEBOARD_DATA_PATH"] == nil { _ = try? LifeBoardSharedStore.writeSnapshot(data) }
            WidgetCenter.shared.reloadTimelines(ofKind: LifeBoardEnvironment.widgetKind)
            message = UserMessage(title: "Backup Restored", detail: "Your original workspace bytes were preserved in a private recovery copy before restore.")
        } catch { message = UserMessage(title: "Couldn't Restore", detail: "Nothing was replaced. " + error.localizedDescription) }
    }

    func performICloudBackup(force: Bool = false) {
        guard data.settings.automaticICloudBackup else { return }
        guard !persistenceReadOnly else {
            if force { message = UserMessage(title: "Backup Paused", detail: "The planner file cannot be read. It has not been overwritten. Restore a verified backup or reopen when the file is available.") }
            return
        }
        if !force, let attempt = lastICloudAttempt, Date.now.timeIntervalSince(attempt) < 10 * 60 { return }
        let statusURL = repository.fileURL.deletingLastPathComponent().appendingPathComponent("BackupStatus.json")
        let saved = (try? Data(contentsOf: statusURL)).flatMap { try? JSONDecoder().decode(Date.self, from: $0) }
        if !force, let last = saved ?? data.settings.lastICloudBackup, Date.now.timeIntervalSince(last) < 6 * 60 * 60 { return }
        lastICloudAttempt = .now
        do {
            let durable = try repository.durableSnapshot()
            _ = try repository.exportToICloud(durable)
            // Backup bookkeeping is device-local and never mutates the planner.
            let completed = Date.now
            try LifeBoardPrivateFiles.write(JSONEncoder().encode(completed), to: statusURL)
            lastAutomaticBackup = completed
        } catch { message = UserMessage(title: "iCloud Backup Unavailable", detail: "The planner has not been replaced. " + error.localizedDescription) }
    }

    func reloadIfChanged() {
        guard let modified = Self.modificationDate(for: repository.fileURL) else {
            if fileModificationDate != nil { persistenceReadOnly = true; message = UserMessage(title: "Changes Paused", detail: "The planner file is unavailable. Restore a backup or make the original file available before editing.") }
            return
        }
        guard modified != fileModificationDate || persistenceReadOnly else { return }
        do {
            data = try repository.loadThrowing()
            devicePreferences?.apply(to: &data.settings)
            reconcileSelections()
            persistenceReadOnly = false
            fileModificationDate = modified
            if ProcessInfo.processInfo.environment["LIFEBOARD_DATA_PATH"] == nil { _ = try? LifeBoardSharedStore.writeSnapshot(data); WidgetCenter.shared.reloadTimelines(ofKind: LifeBoardEnvironment.widgetKind) }
        } catch {
            persistenceReadOnly = true
            fileModificationDate = modified
            message = UserMessage(title: "LifeBoard Data Unavailable", detail: "The data file could not be read. Changes are paused to protect your existing information.")
        }
    }

    func syncTick() {
        guard !syncInProgress, !persistenceReadOnly,
              Date.now.timeIntervalSince(lastSyncAttempt) >= 15,
              SyncService.endpoint() != nil else { return }
        lastSyncAttempt = .now
        syncInProgress = true
        Task { await syncNow() }
    }

    func syncNow() async {
        guard !persistenceReadOnly, let endpoint = SyncService.endpoint() else {
            syncInProgress = false
            return
        }
        guard let token = SyncService.secret("device") else {
            syncStatus = "Connection needs Keychain access · retry in Settings"
            syncInProgress = false
            return
        }
        let epoch = syncEpoch
        syncInProgress = true
        syncStatus = "Syncing…"
        defer { syncInProgress = false }
        do {
            for _ in 0..<3 {
                let latest = try await SyncService.fetch(from: endpoint, token: token)
                guard !persistenceReadOnly, epoch == syncEpoch else { return }
                let current = DevicePreferences.sharedProjection(data)
                // Nothing changed on either side since the last acknowledged
                // snapshot: skip the three full-document merge entirely.
                if let rawRemote = latest.data, let baseline = SyncService.baseline(), latest.revision == baseline.revision {
                    let acknowledged = DevicePreferences.sharedProjection(baseline.data)
                    if DevicePreferences.sharedProjection(rawRemote) == acknowledged && current == acknowledged {
                        syncStatus = "Synced just now"; lastSuccessfulSync = .now; syncConflicts = []; conflictContext = nil
                        return
                    }
                }
                let merged: LifeBoardData
                if let rawRemote = latest.data {
                    let remote = DevicePreferences.sharedProjection(rawRemote)
                    guard remote.schemaVersion == 3 else { syncStatus = "Sync paused · newer data format"; return }
                    if let baseline = SyncService.baseline() {
                        let result = try LifeBoardSyncMerge.merge(base: DevicePreferences.sharedProjection(baseline.data), local: current, remote: remote)
                        guard let value = result.data else { presentSyncConflicts(result.conflicts, base: DevicePreferences.sharedProjection(baseline.data), local: current, remote: remote, revision: latest.revision); return }
                        merged = value
                    } else if sameSnapshot(current, remote) || isEmptyMobileWorkspace(remote) {
                        merged = current
                    } else {
                        presentSyncConflicts(["tasks", "events", "subjects", "projects", "yearMarkers", "activity", "focusSessions", "externalEvents", "activeFocus", "settings"], base: LifeBoardData(), local: current, remote: remote, revision: latest.revision)
                        return
                    }
                } else {
                    merged = current
                }
                if let remote = latest.data, sameSnapshot(merged, DevicePreferences.sharedProjection(remote)) {
                    if !sameSnapshot(current, merged) {
                        guard persist(merged) else { syncStatus = "Sync paused · couldn't save locally"; return }
                    }
                    try SyncService.saveBaseline(SyncBaseline(revision: latest.revision, data: merged))
                    syncStatus = "Synced just now"; lastSuccessfulSync = .now; syncConflicts = []; conflictContext = nil
                    return
                }
                guard let revision = try await SyncService.save(merged, revision: latest.revision, to: endpoint, token: token) else { continue }
                guard !persistenceReadOnly, epoch == syncEpoch else { return }
                if !sameSnapshot(DevicePreferences.sharedProjection(data), current) {
                    // Rebase intervening edits onto the acknowledged snapshot.
                    // Advancing the base alone would reverse unseen remote changes.
                    let result = try LifeBoardSyncMerge.merge(base: current, local: DevicePreferences.sharedProjection(data), remote: merged)
                    guard let rebased = result.data else {
                        presentSyncConflicts(result.conflicts, base: current, local: DevicePreferences.sharedProjection(data), remote: merged, revision: revision); return
                    }
                    guard persist(rebased) else { syncStatus = "Sync paused · couldn't save locally"; return }
                    try SyncService.saveBaseline(SyncBaseline(revision: revision, data: merged))
                    syncStatus = "Changes waiting"
                    return
                }
                if !sameSnapshot(current, merged) {
                    guard persist(merged) else { syncStatus = "Sync paused · couldn't save locally"; return }
                }
                try SyncService.saveBaseline(SyncBaseline(revision: revision, data: merged))
                syncStatus = "Synced just now"; lastSuccessfulSync = .now; syncConflicts = []; conflictContext = nil
                return
            }
            syncStatus = "Changes waiting · retrying"
        } catch {
            NSLog("LifeBoard sync failed: %@", String(describing: error))
            syncStatus = "Couldn't sync · local data is safe"
        }
    }

    private func presentSyncConflicts(_ paths: [String], base: LifeBoardData, local: LifeBoardData, remote: LifeBoardData, revision: Int) {
        conflictContext = SyncConflictContext(revision: revision, base: base, local: local, remote: remote, paths: paths)
        syncConflicts = paths.map { SyncConflictItem(path: $0, localValue: LifeBoardDataPatch.displayValue(path: $0, in: local), remoteValue: LifeBoardDataPatch.displayValue(path: $0, in: remote)) }
        syncStatus = "Sync needs review · \(paths.count) conflicts"
    }

    func resolveSyncConflicts(choices: [String: Bool]) async {
        guard !syncInProgress, !persistenceReadOnly, let context = conflictContext,
              context.paths.allSatisfy({ choices[$0] != nil }), let endpoint = SyncService.endpoint(), let token = SyncService.secret("device") else { return }
        do {
            let latest = try await SyncService.fetch(from: endpoint, token: token)
            guard latest.revision == context.revision, let rawRemote = latest.data else {
                syncStatus = "The other device changed again · review refreshed values"
                await syncNow(); return
            }
            let remote = DevicePreferences.sharedProjection(rawRemote)
            reloadIfChanged()
            // A choice applies only to the versions visibly reviewed by the user.
            guard context.paths.allSatisfy({ LifeBoardDataPatch.displayValue(path: $0, in: data) == LifeBoardDataPatch.displayValue(path: $0, in: context.local) }) else {
                syncStatus = "Local fields changed · review refreshed values"; await syncNow(); return
            }
            _ = try repository.export(data, to: repository.backupDirectory.appendingPathComponent("LifeBoard-sync-local-\(UUID().uuidString).json"))
            _ = try repository.export(remote, to: repository.backupDirectory.appendingPathComponent("LifeBoard-sync-remote-\(UUID().uuidString).json"))
            let useRemote = context.paths.filter { choices[$0] == false }
            let resolvedLocal = try LifeBoardDataPatch.copying(paths: useRemote, from: remote, to: DevicePreferences.sharedProjection(data))
            let adjustedBase = try LifeBoardDataPatch.copying(paths: context.paths, from: remote, to: context.base)
            let result = try LifeBoardSyncMerge.merge(base: adjustedBase, local: resolvedLocal, remote: remote)
            guard let merged = result.data else { presentSyncConflicts(result.conflicts, base: adjustedBase, local: resolvedLocal, remote: remote, revision: latest.revision); return }
            guard persist(merged) else { return }
            // The next network PUT is conditional on the reviewed revision;
            // a changed server revision is re-fetched and merged before retry.
            try SyncService.saveBaseline(SyncBaseline(revision: latest.revision, data: adjustedBase))
            syncConflicts = []; conflictContext = nil
            await syncNow()
        } catch { message = UserMessage(title: "Couldn't Resolve Sync", detail: error.localizedDescription) }
    }

    func refreshConnectedDevices() async {
        guard let endpoint = SyncService.endpoint(), let token = SyncService.secret("device") else { return }
        do { connectedDevices = try await SyncService.listDevices(from: endpoint, token: token) }
        catch { message = UserMessage(title: "Couldn't Read Devices", detail: error.localizedDescription) }
    }
    func createPairingChallenge() async {
        guard let endpoint = SyncService.endpoint(), let token = SyncService.secret("device") else { return }
        do { pairingChallenge = try await SyncService.createChallenge(from: endpoint, token: token) }
        catch { message = UserMessage(title: "Couldn't Pair Device", detail: error.localizedDescription) }
    }
    func revokeConnectedDevice(_ id: String) async {
        guard let endpoint = SyncService.endpoint(), let token = SyncService.secret("device") else { return }
        do { try await SyncService.revokeDevice(id: id, from: endpoint, token: token); await refreshConnectedDevices() }
        catch { message = UserMessage(title: "Couldn't Revoke Device", detail: error.localizedDescription) }
    }
    func disconnectSync() {
        syncEpoch += 1
        do { try SyncService.disconnect(); connectedDevices = []; pairingChallenge = nil; syncConflicts = []; conflictContext = nil; syncStatus = "Disconnected · planner remains on this Mac" }
        catch { message = UserMessage(title: "Couldn't Disconnect", detail: error.localizedDescription) }
    }

    func authoriseStoredConnection() async {
        do {
            try await Task.detached { try SyncService.requestCredentialAccess() }.value
            lastSyncAttempt = .distantPast
            await syncNow()
        } catch {
            message = UserMessage(title: "Connection Access Unavailable", detail: "Your planner remains on this Mac. Allow LifeBoard to use its stored connection, then retry.")
        }
    }

    func connectInvitation(_ url: URL) async {
        do {
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 16384 else { throw LifeBoardError.invalidPayload }
            let invitation = try JSONDecoder().decode(SyncService.InvitationFile.self, from: bytes)
            let known = try? String(contentsOf: SyncService.workspaceIdentityURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let seed = LifeBoardData.seeded()
            let hasWork = !data.tasks.isEmpty || !data.events.isEmpty || !data.activity.isEmpty || !data.focusSessions.isEmpty || !data.externalEvents.isEmpty || !data.yearMarkers.isEmpty || data.activeFocus != nil ||
                data.subjects.contains { !seed.subjects.map(\.title).contains($0.title) || !$0.notes.isEmpty || !$0.topics.isEmpty || !$0.confidenceHistory.isEmpty || $0.progress > 0 } ||
                data.projects.contains { !seed.projects.map(\.title).contains($0.title) || !$0.notes.isEmpty || !$0.summary.isEmpty || !$0.milestones.isEmpty || !$0.updates.isEmpty || $0.progress > 0 }
            guard !persistenceReadOnly, !hasWork || known == invitation.workspaceID else {
                message = UserMessage(title: "Workspace Kept Separate", detail: "This Mac already contains work from another workspace. The invitation has not been connected and no data has moved. Use the invitation on the tester's fresh LifeBoard installation."); return
            }
            let beforeVerification = try JSONEncoder().encode(data)
            try await SyncService.verifyInvitation(invitation)
            guard try JSONEncoder().encode(data) == beforeVerification else { throw LifeBoardError.concurrentChange(["workspace changed while verifying invitation; retry"]) }
            try SyncService.configureWorkspace(endpoint: invitation.endpoint, deviceToken: invitation.deviceToken)
            try LifeBoardPrivateFiles.write(Data(invitation.workspaceID.utf8), to: SyncService.workspaceIdentityURL)
            syncStatus = "Connected to private workspace"
            await syncNow(); await refreshConnectedDevices()
        } catch { message = UserMessage(title: "Couldn't Connect Workspace", detail: error.localizedDescription) }
    }

    @discardableResult func acceptSuggestedPlan(_ plan: [UUID: Int], day: LocalDay) -> Bool {
        let requests = plan.compactMap { id, start -> ScheduleRequest? in
            guard let task = data.tasks.first(where: { $0.id == id && !$0.isCompleted && !$0.isArchived }) else { return nil }
            return ScheduleRequest(id: id, duration: task.estimatedMinutes, explicitStart: start)
        }
        guard requests.count == plan.count else { message = UserMessage(title: "Plan Changed", detail: "A task changed or disappeared. Suggest the plan again."); return false }
        var snapshot = data
        for index in snapshot.tasks.indices where plan[snapshot.tasks[index].id] != nil { snapshot.tasks[index].scheduledDay = nil; snapshot.tasks[index].scheduledStartMinutes = nil; snapshot.tasks[index].scheduledDurationMinutes = nil }
        let verified = SchedulingEngine.suggest(requests, data: snapshot, day: day, now: .now)
        guard verified.allSatisfy({ $0.start == plan[$0.id] && $0.reason == nil }) else { message = UserMessage(title: "Plan No Longer Fits", detail: "Calendar availability changed. Suggest the plan again before accepting."); return false }
        return commit(actionName: "Accept Suggested Plan") { value in
            for index in value.tasks.indices {
                if let start = plan[value.tasks[index].id] { value.tasks[index].scheduledDay = day; value.tasks[index].scheduledStartMinutes = start; value.tasks[index].scheduledDurationMinutes = value.tasks[index].estimatedMinutes; value.tasks[index].modifiedAt = .now }
            }
        }
    }

    private func sameSnapshot(_ lhs: LifeBoardData, _ rhs: LifeBoardData) -> Bool {
        let encoder = LifeBoardJSON.encoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
    }

    private func isEmptyMobileWorkspace(_ value: LifeBoardData) -> Bool {
        value.tasks.isEmpty && value.events.isEmpty && value.subjects.isEmpty && value.projects.isEmpty &&
        value.yearMarkers.isEmpty && value.activity.isEmpty && value.focusSessions.isEmpty &&
        value.externalEvents.isEmpty && value.activeFocus == nil
    }

    private static func modificationDate(for url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
}

// MARK: - Store actions shared by rows, menus and keyboard commands

extension AppStore {
    /// "When" is the planned day. A task that already has an exact time keeps
    /// it on the new day; an untimed task stays untimed.
    func setWhen(_ id: UUID, day: LocalDay?) {
        guard let task = data.tasks.first(where: { $0.id == id }) else { return }
        guard let day else { moveToInbox(id); return }
        if task.scheduledStartMinutes != nil, !task.isCompleted { moveScheduledTask(id, day: day) }
        else { unscheduleTime(id, day: day) }
    }

    func weekendDay(from today: LocalDay = .today) -> LocalDay {
        let weekday = Calendar.current.component(.weekday, from: today.date()) // 1 = Sunday, 7 = Saturday
        if weekday == 1 || weekday == 7 { return today }
        return today.adding(days: 7 - weekday)
    }

    func nextWeekDay(from today: LocalDay = .today) -> LocalDay {
        let weekday = Calendar.current.component(.weekday, from: today.date())
        let start = data.settings.weekStartsMonday ? 2 : 1
        let delta = (start - weekday + 7) % 7
        return today.adding(days: delta == 0 ? 7 : delta)
    }
}
