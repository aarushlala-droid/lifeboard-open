import AppKit
import SwiftUI
import LifeBoardCore

/// Task details. Typing is saved after a short pause as one Undo step; every
/// other control saves at once. Drafts merge with changes made elsewhere and
/// never overwrite a newer value of the same field.
struct TaskInspector: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let taskID: UUID
    @State private var task = TaskItem(title: "")
    @State private var newSubtask = ""
    @FocusState private var checklistEntryFocused: Bool
    @FocusState private var titleFocused: Bool
    @State private var baseline: TaskItem?
    @State private var draftWarning: String?
    @State private var hasDueDate = false
    @State private var hasScheduledDay = false
    @State private var pendingCommit: Task<Void, Never>?
    @State private var progressDraft: Double?

    var body: some View {
        Form {
            if let draftWarning {
                Section { Label(draftWarning, systemImage: "exclamationmark.triangle").foregroundStyle(LB.signal); Button("Reload Latest Version") { refresh() } }
            }
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    CompletionToggle(task: task) { flushDraft(); store.toggleCompletion(taskID, reduceMotion: reduceMotion) }
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                    // Single-line on purpose: a vertically growing field inside a
                    // grouped Form can trigger an AppKit constraint-update loop.
                    TextField("Title", text: $task.title)
                        .font(.title3.weight(.semibold))
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .focused($titleFocused)
                        .onSubmit { flushDraft() }
                        .accessibilityLabel("Title")
                }
                ZStack(alignment: .topLeading) {
                    if task.notes.isEmpty { Text("Notes").foregroundStyle(.tertiary).padding(.top, 1).padding(.leading, 5).allowsHitTesting(false) }
                    TextEditor(text: $task.notes).scrollContentBackground(.hidden).frame(minHeight: 70).accessibilityLabel("Notes")
                }
            }
            let files = CalendarFileLink.urls(in: task.notes)
            if !files.isEmpty {
                Section("Linked Files") {
                    ForEach(Array(files.enumerated()), id: \.offset) { _, url in
                        Button(url.lastPathComponent, systemImage: "arrow.up.forward.app") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .help("Reveal the original file in Finder")
                    }
                }
            }
            Section("When") {
                // Equal-width buttons that shrink with the inspector, so this
                // row can never demand more width than the column has.
                HStack(spacing: 4) {
                    quickDay("Today", .today)
                    quickDay("Tomorrow", .today.adding(days: 1))
                    quickDay("Weekend", store.weekendDay())
                    Button { hasScheduledDay = false } label: { Text("Anytime").lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity) }
                        .disabled(!hasScheduledDay)
                }
                .controlSize(.small).buttonStyle(.bordered)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Plan for")
                Toggle("Planned day", isOn: $hasScheduledDay)
                if hasScheduledDay {
                    DatePicker("Day", selection: Binding(get: { (task.scheduledDay ?? store.index.today).date() }, set: { task.scheduledDay = LocalDay($0) }), displayedComponents: .date)
                    Toggle("Exact time", isOn: Binding(get: { task.scheduledStartMinutes != nil }, set: { on in
                        task.scheduledStartMinutes = on ? (CalendarViewport.currentMinute() + 15) / 15 * 15 % 1440 : nil
                        task.scheduledDurationMinutes = on ? task.estimatedMinutes : nil
                    }))
                    if task.scheduledStartMinutes != nil {
                        DatePicker("Starts", selection: Binding(get: {
                            let minute = task.scheduledStartMinutes ?? 0
                            return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: (task.scheduledDay ?? store.index.today).date()) ?? .now
                        }, set: { task.scheduledStartMinutes = Calendar.current.component(.hour, from: $0) * 60 + Calendar.current.component(.minute, from: $0) }), displayedComponents: .hourAndMinute)
                        Stepper("Lasts \(durationText(task.scheduledDurationMinutes ?? task.estimatedMinutes))", value: Binding(get: { task.scheduledDurationMinutes ?? task.estimatedMinutes }, set: { task.scheduledDurationMinutes = $0 }), in: 5...480, step: 5)
                    }
                }
                Toggle("Due date", isOn: $hasDueDate)
                if hasDueDate { DatePicker("Due", selection: Binding(get: { (task.dueDay ?? store.index.today).date() }, set: { task.dueDay = LocalDay($0) }), displayedComponents: .date) }
                Text("The planned day is when you intend to do it. A due date never schedules it.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Details") {
                Stepper("Estimate \(durationText(task.estimatedMinutes))", value: $task.estimatedMinutes, in: 5...480, step: 5)
                Picker("Priority", selection: $task.priority) { ForEach(TaskPriority.allCases) { Text($0.title).tag($0) } }
                LabeledContent("Progress") {
                    HStack {
                        Slider(value: Binding(get: { progressDraft ?? task.completionPercent ?? (task.isCompleted ? 100 : 0) }, set: { progressDraft = $0 }), in: 0...100, step: 5) { Text("Progress") } onEditingChanged: { editing in
                            guard !editing, let value = progressDraft else { return }
                            progressDraft = nil
                            task.completionPercent = value
                        }
                        .labelsHidden()
                        .accessibilityValue("\(Int(progressDraft ?? task.completionPercent ?? 0)) percent")
                        Text("\(Int(progressDraft ?? task.completionPercent ?? (task.isCompleted ? 100 : 0)))%").monospacedDigit().frame(width: 38, alignment: .trailing)
                    }
                }
            }
            Section("Checklist") {
                ForEach(Array((task.subtasks ?? []).enumerated()), id: \.element.id) { index, subtask in
                    HStack {
                        Toggle(subtask.title, isOn: Binding(get: { task.subtasks?[index].isCompleted ?? false }, set: { task.subtasks?[index].isCompleted = $0 }))
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { task.subtasks?.removeAll { $0.id == subtask.id } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).accessibilityLabel("Remove \(subtask.title)")
                    }
                }
                TextField("New checklist item", text: $newSubtask, prompt: Text("Add a step, then press Return"))
                    .labelsHidden()
                    .accessibilityLabel("New checklist item")
                    .focused($checklistEntryFocused)
                    .onSubmit(addSubtask)
            }
            Section("Repeat") {
                Picker("Repeats", selection: Binding(get: { task.recurrence?.frequency ?? "none" }, set: { task.recurrence = $0 == "none" ? nil : TaskRecurrence(frequency: $0, nextDay: task.scheduledDay ?? task.dueDay) })) {
                    Text("Never").tag("none"); Text("Daily").tag("daily"); Text("Weekly").tag("weekly"); Text("Monthly").tag("monthly")
                }
                if let recurrence = task.recurrence {
                    Stepper("Every \(recurrence.interval) \(unit(recurrence))", value: Binding(get: { task.recurrence?.interval ?? 1 }, set: { task.recurrence?.interval = $0 }), in: 1...365)
                    Text("Completing it creates the next one once.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Belongs to") {
                Picker("Subject", selection: $task.subjectID) { Text("None").tag(UUID?.none); ForEach(store.data.subjects.filter { !$0.archived || $0.id == task.subjectID }) { Text($0.title).tag(UUID?.some($0.id)) } }
                if let subjectID = task.subjectID, let subject = store.index.subjectsByID[subjectID], !subject.topics.isEmpty {
                    Picker("Topic", selection: $task.topicID) { Text("None").tag(UUID?.none); ForEach(subject.topics) { Text($0.title).tag(UUID?.some($0.id)) } }
                }
                Picker("Project", selection: $task.projectID) { Text("None").tag(UUID?.none); ForEach(store.data.projects.filter { $0.status != .archived || $0.id == task.projectID }) { Text($0.title).tag(UUID?.some($0.id)) } }
            }
            Section {
                Button("Start Focus…", systemImage: "timer") { flushDraft(); store.requestFocus(taskID) }
                Button("Duplicate", systemImage: "plus.square.on.square") { flushDraft(); store.duplicateTask(taskID) }
                Button("Move to Trash", systemImage: "trash", role: .destructive) { pendingCommit?.cancel(); flushDraft(); store.deleteTask(taskID) }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh(); consumeFocusRequest() }
        .onDisappear { flushDraft() }
        .onChange(of: store.inspectorFocusRequest) { _, _ in consumeFocusRequest() }
        .onChange(of: titleFocused) { _, focused in if !focused { flushDraft() } }
        .onChange(of: store.index.tasksByID[taskID]) { _, incoming in
            guard let incoming, !incoming.isArchived else { baseline = nil; if store.selectedTaskID == taskID { store.selectedTaskID = nil }; return }
            guard let baseline, task != baseline else { refresh(); return }
            // An unsaved draft: carry it onto the newer stored version.
            do {
                var before = LifeBoardData(); before.tasks = [baseline]
                var after = LifeBoardData(); after.tasks = [task]
                let merged = try LifeBoardDataPatch(before: before, after: after).applying(to: store.data)
                if let current = merged.tasks.first(where: { $0.id == taskID }) { self.baseline = incoming; task = current }
            } catch { draftWarning = "This To Do changed elsewhere. Your draft is shown; reload to see the latest version." }
        }
        .onChange(of: task) { _, edited in
            guard let baseline, edited.id == taskID, edited != baseline else { return }
            var textOnly = baseline; textOnly.title = edited.title; textOnly.notes = edited.notes
            if textOnly == edited {
                pendingCommit?.cancel()
                store.pendingDraftFlush = { flushDraft() }
                pendingCommit = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(650))
                    guard !Task.isCancelled else { return }
                    flushDraft()
                }
            } else {
                flushDraft()
            }
        }
        .onChange(of: hasDueDate) { _, value in if !value { task.dueDay = nil } else if task.dueDay == nil { task.dueDay = store.index.today } }
        .onChange(of: hasScheduledDay) { _, value in
            if !value { task.scheduledDay = nil; task.scheduledStartMinutes = nil; task.scheduledDurationMinutes = nil }
            else if task.scheduledDay == nil { task.scheduledDay = store.index.today }
        }
    }

    private func quickDay(_ label: String, _ day: LocalDay) -> some View {
        Button { task.scheduledDay = day; hasScheduledDay = true } label: { Text(label).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity) }
            .disabled(hasScheduledDay && task.scheduledDay == day)
    }

    private func unit(_ recurrence: TaskRecurrence) -> String {
        let base = ["daily": "day", "weekly": "week", "monthly": "month"][recurrence.frequency] ?? "interval"
        return recurrence.interval == 1 ? base : base + "s"
    }

    private func consumeFocusRequest() {
        guard store.inspectorFocusPending else { return }
        store.inspectorFocusPending = false
        DispatchQueue.main.async { titleFocused = true }
    }

    /// Saves the current draft now (if it differs from what is stored).
    private func flushDraft() {
        pendingCommit?.cancel(); pendingCommit = nil
        store.pendingDraftFlush = nil
        guard let baseline, task.id == taskID, task != baseline else { return }
        guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            draftWarning = "A To Do needs a title. The previous title is kept until you type one."; return
        }
        if store.updateTask(task, basedOn: baseline) { refresh() }
        else { draftWarning = "This change wasn't saved because a field is invalid or changed elsewhere." }
    }

    private func addSubtask() {
        checklistEntryFocused = true
        let title = newSubtask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if task.subtasks == nil { task.subtasks = [] }
        task.subtasks?.append(TaskSubtask(title: title))
        newSubtask = ""
    }

    private func refresh() {
        guard let current = store.data.tasks.first(where: { $0.id == taskID && !$0.isArchived }) else {
            baseline = nil; if store.selectedTaskID == taskID { store.selectedTaskID = nil }; return
        }
        baseline = current; task = current; draftWarning = nil
        hasDueDate = current.dueDay != nil; hasScheduledDay = current.scheduledDay != nil
    }
}
