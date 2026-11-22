import AppKit
import SwiftUI
import LifeBoardCore

/// The actions every task offers, used by context menus and the Task menu.
struct TaskActionsMenu: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let ids: [UUID]
    var onReschedule: ((UUID) -> Void)? = nil

    private var tasks: [TaskItem] { ids.compactMap { store.index.tasksByID[$0] } }

    var body: some View {
        let tasks = self.tasks
        let single = tasks.count == 1 ? tasks.first : nil
        let allDone = !tasks.isEmpty && tasks.allSatisfy(\.isCompleted)
        Button(allDone ? "Mark as Not Done" : "Mark as Done", systemImage: allDone ? "circle" : "checkmark.circle") {
            for task in tasks { store.toggleCompletion(task.id, reduceMotion: reduceMotion) }
        }
        Divider()
        Menu("Do", systemImage: "calendar") {
            Button("Today") { tasks.forEach { store.setWhen($0.id, day: .today) } }
            Button("Tomorrow") { tasks.forEach { store.setWhen($0.id, day: .today.adding(days: 1)) } }
            Button("This Weekend") { tasks.forEach { store.setWhen($0.id, day: store.weekendDay()) } }
            Button("Next Week") { tasks.forEach { store.setWhen($0.id, day: store.nextWeekDay()) } }
            if let single, let onReschedule { Divider(); Button("Choose Date…") { onReschedule(single.id) } }
            Divider()
            Button("Anytime (No Date)") { tasks.forEach { store.setWhen($0.id, day: nil) } }
            if tasks.contains(where: { $0.scheduledStartMinutes != nil }) { Button("Remove Exact Time") { tasks.forEach { store.unscheduleTime($0.id) } } }
        }
        Menu("Due", systemImage: "flag") {
            Button("Today") { tasks.forEach { store.setDueDay($0.id, day: .today) } }
            Button("Tomorrow") { tasks.forEach { store.setDueDay($0.id, day: .today.adding(days: 1)) } }
            Button("Next Week") { tasks.forEach { store.setDueDay($0.id, day: store.nextWeekDay()) } }
            Divider()
            Button("Clear Due Date") { tasks.forEach { store.setDueDay($0.id, day: nil) } }.disabled(tasks.allSatisfy { $0.dueDay == nil })
        }
        Menu("Subject", systemImage: "books.vertical") {
            Button("None") { tasks.forEach { store.setSubject($0.id, subjectID: nil) } }
            ForEach(store.data.subjects.filter { !$0.archived }) { subject in Button(subject.title) { tasks.forEach { store.setSubject($0.id, subjectID: subject.id) } } }
        }
        Menu("Project", systemImage: "folder") {
            Button("None") { tasks.forEach { store.setProject($0.id, projectID: nil) } }
            ForEach(store.data.projects.filter { $0.status != .archived }) { project in Button(project.title) { tasks.forEach { store.setProject($0.id, projectID: project.id) } } }
        }
        if let single {
            Button("Start Focus…", systemImage: "timer") { store.requestFocus(single.id) }
            Divider()
            Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicateTask(single.id) }
        }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) { tasks.forEach { store.deleteTask($0.id) } }
    }
}

// MARK: - Row

struct TaskRow: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: TaskItem
    var compact = false
    var showsDay = true
    var lingering = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CompletionToggle(task: task) { store.toggleCompletion(task.id, reduceMotion: reduceMotion) }
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if task.priority == .high && !task.isCompleted {
                            Image(systemName: "exclamationmark").font(.caption.weight(.heavy)).foregroundStyle(LB.signal).accessibilityLabel("High priority")
                        }
                        Text(task.title)
                            .strikethrough(task.isCompleted, color: .secondary)
                            .foregroundStyle(task.isCompleted ? .secondary : .primary)
                            .lineLimit(2)
                    }
                    metadata
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .accessibilityAction(named: task.isCompleted ? "Mark as not done" : "Mark as done") { store.toggleCompletion(task.id, reduceMotion: reduceMotion) }
            if hovering && !task.isCompleted { hoverActions.transition(.opacity) }
            // The progress slider stays on every open row, as in LifeBoard 4.
            if !task.isCompleted { TaskProgressControl(task: task).frame(width: compact ? 95 : 110) }
        }
        .padding(.vertical, compact ? 1 : 3)
        .contentShape(Rectangle())
        // Lists select natively; this also selects rows shown outside a List.
        .simultaneousGesture(TapGesture().onEnded { store.selectedTaskID = task.id })
        .onHover { value in withMotion(Motion.quick(reduceMotion)) { hovering = value } }
        .onDrag { store.calendarDragProvider(for: .task(task.id)) }
    }

    @ViewBuilder private var metadata: some View {
        let parts = metadataParts
        if !parts.isEmpty {
            HStack(spacing: 10) {
                ForEach(parts.indices, id: \.self) { index in parts[index] }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var metadataParts: [AnyView] {
        var parts: [AnyView] = []
        let today = store.index.today
        if let association = store.index.association(for: task) {
            parts.append(AnyView(HStack(spacing: 4) { Circle().fill(association.colour).frame(width: 6, height: 6); Text(association.title) }))
        }
        if showsDay, let day = task.scheduledDay, day != today || task.scheduledStartMinutes != nil {
            let overdue = day < today && !task.isCompleted
            let label = task.scheduledStartMinutes.map { start in
                let end = start + (task.scheduledDurationMinutes ?? task.estimatedMinutes)
                return (day == today ? "" : relativeDayText(day, today: today) + " ") + "\(timeString(start))–\(timeString(end % 1440))"
            } ?? relativeDayText(day, today: today)
            parts.append(AnyView(Label(label, systemImage: task.scheduledStartMinutes == nil ? "calendar" : "clock").labelStyle(.titleAndIcon).foregroundStyle(overdue ? LB.signal : .secondary)))
        } else if !showsDay, let start = task.scheduledStartMinutes {
            let end = start + (task.scheduledDurationMinutes ?? task.estimatedMinutes)
            parts.append(AnyView(Label("\(timeString(start))–\(timeString(end % 1440))", systemImage: "clock")))
        }
        if let due = task.dueDay {
            let overdue = due < today && !task.isCompleted
            parts.append(AnyView(Label(due == today ? "Due today" : "Due \(relativeDayText(due, today: today))", systemImage: "flag").foregroundStyle(overdue ? LB.signal : .secondary)))
        }
        if task.scheduledStartMinutes == nil { parts.append(AnyView(Text(durationText(task.estimatedMinutes)).monospacedDigit())) }
        if let subtasks = task.subtasks, !subtasks.isEmpty {
            parts.append(AnyView(Label("\(subtasks.filter(\.isCompleted).count)/\(subtasks.count)", systemImage: "checklist").monospacedDigit()))
        }
        if task.recurrence != nil { parts.append(AnyView(Image(systemName: "repeat").accessibilityLabel("Repeats"))) }
        if !task.notes.isEmpty { parts.append(AnyView(Image(systemName: "note.text").accessibilityLabel("Has notes"))) }
        return parts
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            Menu {
                Button("Today") { store.setWhen(task.id, day: .today) }
                Button("Tomorrow") { store.setWhen(task.id, day: .today.adding(days: 1)) }
                Button("This Weekend") { store.setWhen(task.id, day: store.weekendDay()) }
                Button("Next Week") { store.setWhen(task.id, day: store.nextWeekDay()) }
                Divider()
                Button("Anytime (No Date)") { store.setWhen(task.id, day: nil) }
            } label: { Image(systemName: "calendar.badge.clock") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Choose when to do this")
            Button { store.requestFocus(task.id) } label: { Image(systemName: "timer") }
                .buttonStyle(.borderless).help("Start Focus")
        }
        .foregroundStyle(.secondary)
    }

    private var accessibilityText: String {
        var text = task.title
        if task.isCompleted { text += ", done" }
        if let association = store.index.association(for: task) { text += ", \(association.title)" }
        if let due = task.dueDay { text += ", due \(relativeDayText(due, today: store.index.today))" }
        if let start = task.scheduledStartMinutes { text += ", at \(timeString(start))" }
        return text
    }
}

/// A circle that fills on completion. Partial progress draws as an arc, which
/// replaces the old per-row slider (the inspector still edits it exactly).
struct CompletionToggle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: TaskItem
    let action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button {
            action()
            guard !reduceMotion, !task.isCompleted else { return }
            withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) { pulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { withAnimation(.easeOut(duration: 0.12)) { pulse = false } }
        } label: {
            ZStack {
                Circle().strokeBorder(task.isCompleted ? LB.accent : Color.secondary.opacity(0.7), lineWidth: 1.4)
                if task.isCompleted {
                    Circle().fill(LB.accent)
                    Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 16, height: 16)
            .scaleEffect(pulse ? 1.18 : 1)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(task.isCompleted ? "Mark \(task.title) as not done" : "Mark \(task.title) as done")
        .help(task.isCompleted ? "Mark as not done" : "Mark as done")
    }
}

/// LifeBoard's progress slider: drag to set how far along a To Do is, in steps
/// of 5%. It saves once on release (one Undo step); 100% completes the To Do.
struct TaskProgressControl: View {
    @EnvironmentObject private var store: AppStore
    let task: TaskItem
    @State private var amount = 0.0

    var body: some View {
        VStack(spacing: 0) {
            // A smooth slider (no tick marks under every row) that settles on
            // the nearest 5% when released.
            Slider(value: $amount, in: 0...100) { Text("Progress for \(task.title)") } onEditingChanged: { editing in
                guard !editing else { return }
                amount = (amount / 5).rounded() * 5
                if amount != stored { store.setTaskProgress(task.id, percent: amount) }
            }
            .labelsHidden()
            .controlSize(.small)
            Text("\(Int((amount / 5).rounded() * 5))% done").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
        .help("Drag to set progress")
        .accessibilityValue("\(Int(amount)) percent")
        .onAppear { amount = stored }
        .onChange(of: task.completionPercent) { _, _ in amount = stored }
    }

    private var stored: Double { task.completionPercent ?? (task.isCompleted ? 100 : 0) }
}

// MARK: - Inline entry

/// One line, parsed live by the on-device parser. The chips show exactly what
/// will be saved before Return; anything ambiguous must be clarified first.
struct QuickEntryField: View {
    @EnvironmentObject private var store: AppStore
    let context: NewTaskContext
    var placeholder = "New To Do"
    @Binding var focusRequest: Int
    @State private var text = ""
    @State private var confirmation: String?
    @FocusState private var focused: Bool

    private var draft: CapturedTaskDraft? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.contains("\n") else { return nil }
        return NaturalLanguageTaskParser.parse(line, referenceDay: store.index.today, data: store.data).first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").foregroundStyle(LB.accent).font(.system(size: 15)).frame(width: 24)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { add(asTyped: false) }
                    .onKeyPress(.escape) { if text.isEmpty { focused = false } else { text = "" }; return .handled }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.option) else { return .ignored }
                        add(asTyped: true); return .handled
                    }
                    .accessibilityLabel("New To Do")
                    .accessibilityHint("Type a task, optionally with a day, time, duration or subject, then press Return")
            }
            if let draft { chips(for: draft).padding(.leading, 32).transition(.opacity) }
            else if let confirmation { Text(confirmation).font(.caption).foregroundStyle(.secondary).padding(.leading, 32) }
        }
        .padding(.vertical, 4)
        .onChange(of: focusRequest) { _, _ in focused = true }
        .onChange(of: text) { _, value in if !value.isEmpty { confirmation = nil } }
    }

    @ViewBuilder private func chips(for draft: CapturedTaskDraft) -> some View {
        let plan = plan(for: draft)
        HStack(spacing: 6) {
            if let problem = plan.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(LB.signal)
                Text("Option-Return adds it as typed").foregroundStyle(.secondary)
            } else {
                ForEach(plan.chips, id: \.self) { chip in
                    Text(chip).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(LB.accent.opacity(0.12), in: Capsule())
                }
                Text("Return to add").foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func plan(for draft: CapturedTaskDraft) -> QuickEntryPlan {
        QuickEntryPlanner.plan(draft, context: context, index: store.index)
    }

    private func add(asTyped: Bool) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        if asTyped {
            var task = TaskItem(title: line)
            task.estimatedMinutes = store.data.settings.defaultTaskMinutes
            task.scheduledDay = context.day
            if store.commit(actionName: "Add To Do", { $0.tasks.append(task) }) { finish("Added “\(task.title)”") }
            return
        }
        guard let draft else { return }
        let plan = plan(for: draft)
        guard plan.problem == nil else { NSSound.beep(); return }
        if let event = plan.event {
            if store.commit(actionName: "Add Event", { $0.events.append(event) }) { finish("Added event “\(event.title)”") }
        } else if let task = plan.task {
            if store.commit(actionName: "Add To Do", { $0.tasks.append(task) }) {
                let lands = task.scheduledDay == context.day && context != .none ? "" : plan.chips.first.map { ", " + $0.lowercased() } ?? ""
                finish("Added “\(task.title)”\(lands)")
            }
        }
    }

    private func finish(_ message: String) {
        text = ""
        confirmation = message
        focused = true
    }
}

// MARK: - List

/// A keyboard-first task list: arrows select, Space completes, Return or a
/// double-click opens details, Delete moves to Trash, Command-Z undoes.
struct TaskListView<Header: View>: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let groups: [TaskGroup]
    var entry: NewTaskContext? = nil
    var showsDay = true
    var emptyTitle = "Nothing here"
    var emptyDetail = "Add a To Do above, or press Command-N to capture several at once."
    @Binding var focusEntry: Int
    var openDetails: () -> Void = {}
    var onReschedule: (UUID) -> Void = { _ in }
    @ViewBuilder var footer: () -> Header
    @AppStorage("collapsedTaskGroups") private var collapsedRaw = "done"
    @FocusState private var listFocused: Bool

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }

    var body: some View {
        let visible = groups.filter { !$0.tasks.isEmpty }
        List(selection: Binding(get: { store.selectedTaskID }, set: { store.selectedTaskID = $0 })) {
            if let entry {
                QuickEntryField(context: entry, focusRequest: $focusEntry).selectionDisabled()
            }
            if visible.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "checkmark.circle", description: Text(emptyDetail))
                    .frame(maxWidth: .infinity).padding(.vertical, 30).selectionDisabled()
            }
            ForEach(visible) { group in
                Section {
                    if !collapsed.contains(group.id) {
                        ForEach(group.tasks) { task in
                            TaskRow(task: task, showsDay: showsDay, lingering: store.lingeringCompletions.contains(task.id)).tag(task.id)
                        }
                    }
                } header: {
                    groupHeader(group)
                }
            }
            footer().selectionDisabled()
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        // The list holds keyboard focus when a screen opens, so arrows, Space
        // and Return work at once and the inspector never takes focus by itself.
        .focused($listFocused)
        .onAppear { DispatchQueue.main.async { listFocused = true } }
        .animation(Motion.move(reduceMotion), value: groups.map { $0.tasks.map(\.id) })
        .contextMenu(forSelectionType: UUID.self) { ids in
            TaskActionsMenu(ids: Array(ids), onReschedule: onReschedule)
        } primaryAction: { ids in
            if let id = ids.first { store.selectedTaskID = id; openDetails() }
        }
        .onKeyPress(.space) {
            guard let id = store.selectedTaskID else { return .ignored }
            store.toggleCompletion(id, reduceMotion: reduceMotion); return .handled
        }
        .onDeleteCommand { if let id = store.selectedTaskID { store.deleteTask(id) } }
    }

    /// Lower groups fold away so Today can list everything without crowding it.
    private func isCollapsible(_ group: TaskGroup) -> Bool {
        switch group.kind { case .done, .anytime, .upcoming: true; default: false }
    }

    @ViewBuilder private func groupHeader(_ group: TaskGroup) -> some View {
        let tint: Color = { if case .overdue = group.kind { return LB.signal }; if case .today = group.kind { return LB.accent }; return .secondary }()
        HStack {
            if isCollapsible(group) {
                Button {
                    var set = collapsed
                    if set.contains(group.id) { set.remove(group.id) } else { set.insert(group.id) }
                    collapsedRaw = set.sorted().joined(separator: ",")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: collapsed.contains(group.id) ? "chevron.right" : "chevron.down").font(.caption2.weight(.semibold))
                        SectionHeading(title: group.title, count: group.tasks.count, tint: tint)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.title), \(group.tasks.count)")
                .accessibilityValue(collapsed.contains(group.id) ? "Collapsed" : "Expanded")
            } else {
                SectionHeading(title: group.title, count: group.tasks.count, tint: tint)
            }
            Spacer()
        }
    }
}

extension TaskListView where Header == EmptyView {
    init(groups: [TaskGroup], entry: NewTaskContext? = nil, showsDay: Bool = true, emptyTitle: String = "Nothing here", emptyDetail: String = "Add a To Do above, or press Command-N to capture several at once.", focusEntry: Binding<Int>, openDetails: @escaping () -> Void = {}, onReschedule: @escaping (UUID) -> Void = { _ in }) {
        self.init(groups: groups, entry: entry, showsDay: showsDay, emptyTitle: emptyTitle, emptyDetail: emptyDetail, focusEntry: focusEntry, openDetails: openDetails, onReschedule: onReschedule, footer: { EmptyView() })
    }
}
