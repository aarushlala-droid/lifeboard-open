import AppKit
import SwiftUI
import LifeBoardCore

struct ScreenHeader: View {
    let eyebrow: String; let title: String; var detail: String? = nil
    // The eyebrow is kept for callers but no longer drawn: titles match ScreenTitle.
    var body: some View { ScreenTitle(title: title, subtitle: detail).accessibilityHint(eyebrow) }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.tint).accessibilityHidden(true)
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
    }
}

private func durationLabel(_ minutes: Int) -> String {
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60, remainder = minutes % 60
    return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
}

struct EveningPlanView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var proposed: [UUID: Int] = [:]
    @State private var overflow: [UUID: String] = [:]
    private var candidates: [TaskItem] { store.data.tasks.filter { !$0.isCompleted && !$0.isArchived && ($0.scheduledDay == nil || TaskClassification($0).carryOver || ($0.scheduledDay == .today && $0.scheduledStartMinutes == nil)) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { VStack(alignment: .leading) { Text("Plan Evening").font(.largeTitle.bold()); Text("Suggestions stay provisional until you accept them.").foregroundStyle(.secondary) }; Spacer(); Button("Suggest Plan") { suggest() } }
            List(candidates) { task in HStack { TaskRow(task: task, compact: true); Spacer(); Text(proposed[task.id].map(timeString) ?? overflow[task.id] ?? "Unscheduled").foregroundStyle(.secondary).monospacedDigit() } }
            HStack { Button("Clear Suggested Plan") { proposed.removeAll(); overflow.removeAll() }.disabled(proposed.isEmpty); Spacer(); Button("Cancel") { dismiss() }; Button("Accept Plan") { if store.acceptSuggestedPlan(proposed, day: .today) { dismiss() } else { suggest() } }.keyboardShortcut(.defaultAction).disabled(proposed.isEmpty) }
        }.padding(24).frame(minWidth: 700, minHeight: 520)
    }

    private func suggest() {
        let sorted = candidates.sorted { ($0.dueDay ?? LocalDay.today.adding(days: 365), -priorityRank($0.priority), $0.estimatedMinutes) < ($1.dueDay ?? LocalDay.today.adding(days: 365), -priorityRank($1.priority), $1.estimatedMinutes) }
        let suggestions = SchedulingEngine.suggest(sorted.map { ScheduleRequest(id: $0.id, duration: $0.estimatedMinutes) }, data: store.data, day: .today)
        proposed = Dictionary(uniqueKeysWithValues: suggestions.compactMap { item in item.start.map { (item.id, $0) } })
        overflow = Dictionary(uniqueKeysWithValues: suggestions.compactMap { item in item.reason.map { (item.id, $0) } })
    }

    private func priorityRank(_ p: TaskPriority) -> Int { switch p { case .high: 3; case .medium: 2; case .low: 1; case .none: 0 } }
}

struct SubjectsView: View {
    @EnvironmentObject private var store: AppStore
    let searchText: String
    @State private var selection: UUID?
    var body: some View { HStack(spacing: 0) { List(store.data.subjects.filter { !$0.archived && (searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText)) }, selection: $selection) { subject in VStack(alignment: .leading, spacing: 4) { Text(subject.title); HStack { ProgressView(value: subject.progress, total: 100).frame(width: 70); Text("\(Int(subject.progress))% · \(subject.confidence, specifier: "%.0f")/5").font(.caption).foregroundStyle(.secondary) } }.tag(subject.id).padding(.vertical, 3).acceptsTaskDrop { id in if var task = store.data.tasks.first(where: { $0.id == id }) { task.subjectID = subject.id; store.updateTask(task) } } }.frame(width: 250); Divider(); if let id = selection ?? store.data.subjects.first?.id { SubjectDetail(subjectID: id) } else { QuietEmptyState(title: "No Subjects", detail: "Add a subject to track confidence and progress.", symbol: "books.vertical") } }.navigationTitle("Subjects") }
}

struct SubjectDetail: View {
    @EnvironmentObject private var store: AppStore
    let subjectID: UUID
    @State private var subject = LifeBoardCore.Subject(title: "")
    @State private var newTopic = ""
    @State private var importTopics = false
    @State private var showRevision = false
    private var activeTasks: [TaskItem] { store.data.tasks.filter { !$0.isCompleted && !$0.isArchived && $0.subjectID == subjectID } }
    private var completedTasks: [TaskItem] { store.data.tasks.filter { $0.isCompleted && $0.subjectID == subjectID } }
    private var weekStart: Date { Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start ?? .distantPast }
    @ViewBuilder private var topicActions: some View {
        Button("Import topic list or specification…") { importTopics = true }
        Button("Revision overview…") { showRevision = true }
    }
    private var focusMinutes: Int { store.focusedSeconds(subjectID: subjectID, since: weekStart) / 60 }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 24) {
            ScreenHeader(eyebrow: "Subject", title: subject.title, detail: subject.lastActivity.map { "Last worked on \($0.formatted(.relative(presentation: .named)))" } ?? "No activity yet")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], alignment: .leading, spacing: 10) {
                MetricTile(title: "Confidence", value: "\(Int(subject.confidence))/5", symbol: "gauge.with.dots.needle.50percent")
                MetricTile(title: "Course", value: "\(Int(subject.progress))%", symbol: "chart.bar.fill")
                MetricTile(title: "To Dos", value: "\(activeTasks.count)", symbol: "checklist")
                MetricTile(title: "Focused this week", value: durationLabel(focusMinutes), symbol: "timer")
            }
            ViewThatFits(in: .horizontal) {
                HStack { topicActions }
                VStack(alignment: .leading, spacing: 8) { topicActions }
            }
            DisclosureGroup("Subject details") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) { GridRow { Text("Name"); TextField("Subject name", text: $subject.title).gridCellColumns(2) }; GridRow { Text("Confidence"); Slider(value: $subject.confidence, in: 1...5, step: 1).accessibilityLabel("Self-assessed confidence").accessibilityValue("\(Int(subject.confidence)) out of 5"); Text("\(Int(subject.confidence))/5").monospacedDigit() }; GridRow { Text("Manual course progress"); Slider(value: $subject.progress, in: 0...100, step: 1).accessibilityLabel("Manually maintained course progress").accessibilityValue("\(Int(subject.progress)) percent"); Text("\(Int(subject.progress))%").monospacedDigit() } }.padding(.top, 12)
            }
            VStack(alignment: .leading, spacing: 10) { Text("Topics").font(.headline); if subject.topics.isEmpty { Text("No topics yet.").foregroundStyle(.secondary) }; ForEach(subject.topics) { topic in HStack { TextField("Topic name", text: topicTitleBinding(topic.id)).textFieldStyle(.plain); Spacer(); ProgressView(value: topic.progress, total: 100).frame(width: 90); Text("\(Int(topic.confidence))/5").foregroundStyle(.secondary).monospacedDigit() }.padding(.vertical, 4); Divider() }; HStack { TextField("Add topic", text: $newTopic).onSubmit(addTopic); Button("Add") { addTopic() }.disabled(newTopic.isEmpty) } }
            VStack(alignment: .leading, spacing: 8) { Text("Current To Dos").font(.headline); if activeTasks.isEmpty { Text("No outstanding tasks.").foregroundStyle(.secondary) } else { ForEach(activeTasks) { TaskRow(task: $0, compact: true) } } }
            if !completedTasks.isEmpty { VStack(alignment: .leading, spacing: 8) { Text("Recently completed").font(.headline); ForEach(completedTasks.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }.prefix(4)) { task in Button(task.title) { store.selectedTaskID = task.id }.buttonStyle(.plain).foregroundStyle(.secondary) } } }
            DisclosureGroup("Notes") { TextEditor(text: $subject.notes).frame(minHeight: 130).padding(8).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Subject notes").padding(.top, 8) }
            ActivityList(records: store.data.activity.filter { $0.subjectID == subjectID })
        }.padding(28).frame(maxWidth: 850, alignment: .leading) }
        .sheet(isPresented: $importTopics) { TopicImportPreviewView(subjectID: subjectID).environmentObject(store) }
        .sheet(isPresented: $showRevision) { RevisionOverviewView().environmentObject(store) }
        .onChange(of: store.data.subjects) { _, _ in refresh() }
        .onAppear(perform: refresh).onChange(of: subject) { _, value in
            guard let current = store.data.subjects.first(where: { $0.id == subjectID }), value != current else { return }
            store.updateSubject(value)
        }.onChange(of: subjectID) { _, _ in refresh() }
    }
    private func refresh() { if let current = store.data.subjects.first(where: { $0.id == subjectID }) { subject = current } }
    private func addTopic() { store.addTopic(newTopic, subjectID: subjectID); newTopic = ""; refresh() }
    private func topicTitleBinding(_ id: UUID) -> Binding<String> { Binding(get: { subject.topics.first(where: { $0.id == id })?.title ?? "" }, set: { value in if let i = subject.topics.firstIndex(where: { $0.id == id }) { subject.topics[i].title = value } }) }
}

struct ProjectsView: View {
    @EnvironmentObject private var store: AppStore
    let searchText: String
    @State private var selection: UUID?
    var body: some View { HStack(spacing: 0) { List(store.data.projects.filter { $0.status != .archived && (searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText)) }, selection: $selection) { project in VStack(alignment: .leading, spacing: 4) { Text(project.title); HStack { ProgressView(value: project.progress, total: 100).frame(width: 70); Text("\(Int(project.progress))% · \(project.status.title)").font(.caption).foregroundStyle(.secondary) } }.tag(project.id).padding(.vertical, 3).acceptsTaskDrop { id in if var task = store.data.tasks.first(where: { $0.id == id }) { task.projectID = project.id; store.updateTask(task) } } }.frame(width: 250); Divider(); if let id = selection ?? store.data.projects.first?.id { ProjectDetail(projectID: id) } else { QuietEmptyState(title: "No Projects", detail: "Add a project for longer pieces of work.", symbol: "folder") } }.navigationTitle("Projects") }
}

struct ProjectDetail: View {
    enum Tab: String, CaseIterable, Identifiable { case overview = "Overview", tasks = "Tasks", kanban = "Kanban", notes = "Notes", activity = "Activity"; var id: String { rawValue } }
    @EnvironmentObject private var store: AppStore
    let projectID: UUID
    @State private var project = Project(title: "")
    @State private var newMilestone = ""
    private var progressModeLabel: String { switch project.progressMode ?? "manual" { case "tasks": "Task completion"; case "milestones": "Milestone completion"; default: "Manual overall progress" } }
    private var displayProgress: Double {
        switch project.progressMode ?? "manual" {
        case "tasks": return allTasks.isEmpty ? 0 : Double(allTasks.filter(\.isCompleted).count) / Double(allTasks.count) * 100
        case "milestones": return project.milestones.isEmpty ? 0 : Double(project.milestones.filter(\.isCompleted).count) / Double(project.milestones.count) * 100
        default: return project.progress
        }
    }
    @State private var milestoneDate = Date.now.addingTimeInterval(604800)
    @State private var progressText = ""
    @State private var tab = Tab.overview
    private var activeTasks: [TaskItem] { store.data.tasks.filter { !$0.isCompleted && !$0.isArchived && $0.projectID == projectID } }
    private var allTasks: [TaskItem] { store.data.tasks.filter { !$0.isArchived && $0.projectID == projectID } }
    private var nextMilestone: ProjectMilestone? { project.milestones.filter { !$0.isCompleted }.min { $0.targetDay < $1.targetDay } }
    private var weekStart: Date { Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start ?? .distantPast }
    private var focusMinutes: Int { store.focusedSeconds(projectID: projectID, since: weekStart) / 60 }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(eyebrow: "Project", title: project.title, detail: project.status.title)
                Picker("Project view", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 560)
            }.padding(24)
            Divider()
            switch tab {
            case .overview: overview
            case .tasks: ScrollView { VStack(alignment: .leading, spacing: 8) { if activeTasks.isEmpty { QuietEmptyState(title: "No current To Dos", detail: "Assign a task to this project and it will appear here.", symbol: "checklist") } else { ForEach(activeTasks) { TaskRow(task: $0) } } }.padding(24) }
            case .kanban: ProjectKanbanView(projectID: projectID)
            case .notes: ScrollView { VStack(alignment: .leading, spacing: 14) { Text("Project Notes").font(.title2.bold()); TextEditor(text: $project.notes).frame(minHeight: 300).padding(10).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10)); Text("Progress Journal").font(.headline); HStack { TextField("Add a progress note", text: $progressText); Button("Add") { store.addProgress(progressText, projectID: projectID); progressText = ""; refresh() }.disabled(progressText.isEmpty) }; ForEach(project.updates) { Text($0.text) } }.padding(24) }
            case .activity: ScrollView { ActivityList(records: store.data.activity.filter { $0.projectID == projectID }).padding(24) }
            }
        }
        .onAppear(perform: refresh).onChange(of: project) { _, value in
            guard let current = store.data.projects.first(where: { $0.id == projectID }), value != current else { return }
            store.updateProject(value)
        }.onChange(of: projectID) { _, _ in refresh() }
    }
    private var overview: some View {
        ScrollView { VStack(alignment: .leading, spacing: 24) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], alignment: .leading, spacing: 10) { MetricTile(title: progressModeLabel, value: "\(Int(displayProgress))%", symbol: "chart.bar.fill"); MetricTile(title: "To Dos", value: "\(activeTasks.count)", symbol: "checklist"); MetricTile(title: "Completed", value: "\(allTasks.filter(\.isCompleted).count)/\(allTasks.count)", symbol: "checkmark.circle"); MetricTile(title: "Focused this week", value: durationLabel(focusMinutes), symbol: "timer") }
            if let nextMilestone { HStack { Image(systemName: "diamond.fill").foregroundStyle(.purple); Text(nextMilestone.title).font(.headline); Spacer(); Text(nextMilestone.targetDay.date().formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary) }.padding(14).background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)) }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) { GridRow { Text("Name"); TextField("Project name", text: $project.title).gridCellColumns(2) }; GridRow { Text("Status"); Picker("Status", selection: $project.status) { ForEach(ProjectStatus.allCases) { Text($0.title).tag($0) } }.labelsHidden() }; GridRow { Text("Progress calculation"); Picker("Progress calculation", selection: Binding(get: { project.progressMode ?? "manual" }, set: { project.progressMode = $0 })) { Text("Manual overall progress").tag("manual"); Text("Task completion").tag("tasks"); Text("Milestone completion").tag("milestones") } }
                GridRow { Text("Manual overall progress"); Slider(value: $project.progress, in: 0...100, step: 1).disabled((project.progressMode ?? "manual") != "manual").accessibilityLabel("Manual overall project progress").accessibilityValue("\(Int(project.progress)) percent"); Text("\(Int(project.progress))%") } }
            TextField("What is this project?", text: $project.summary, axis: .vertical).lineLimit(2...5)
            VStack(alignment: .leading, spacing: 10) { Text("Milestones").font(.headline); ForEach(project.milestones.sorted { $0.targetDay < $1.targetDay }) { milestone in HStack { Button { store.toggleMilestone(milestone.id, projectID: projectID); refresh() } label: { Image(systemName: milestone.isCompleted ? "checkmark.circle.fill" : "circle") }.buttonStyle(.plain); TextField("Milestone name", text: milestoneTitleBinding(milestone.id)).textFieldStyle(.plain); Spacer(); Text(milestone.targetDay.date().formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary) } }; HStack { TextField("New milestone", text: $newMilestone); DatePicker("Target", selection: $milestoneDate, displayedComponents: .date).labelsHidden(); Button("Add") { store.addMilestone(title: newMilestone, projectID: projectID, day: LocalDay(milestoneDate)); newMilestone = ""; refresh() }.disabled(newMilestone.isEmpty) } }
        }.padding(24).frame(maxWidth: 850, alignment: .leading) }
    }
    private func refresh() { if let current = store.data.projects.first(where: { $0.id == projectID }) { project = current } }
    private func milestoneTitleBinding(_ id: UUID) -> Binding<String> { Binding(get: { project.milestones.first(where: { $0.id == id })?.title ?? "" }, set: { value in if let i = project.milestones.firstIndex(where: { $0.id == id }) { project.milestones[i].title = value } }) }
}

enum KanbanStage: String, CaseIterable, Identifiable {
    case backlog, next, inProgress, waiting, done
    var id: String { rawValue }
    var title: String { switch self { case .backlog: "Backlog"; case .next: "Next"; case .inProgress: "In Progress"; case .waiting: "Waiting"; case .done: "Done" } }
    var tag: String { "workflow:\(rawValue)" }
    static func stage(for task: TaskItem) -> KanbanStage { if task.isCompleted { return .done }; return allCases.first { task.tags.contains($0.tag) } ?? .backlog }
}

private struct ProjectKanbanView: View {
    @EnvironmentObject private var store: AppStore
    let projectID: UUID
    private var tasks: [TaskItem] { store.data.tasks.filter { !$0.isArchived && $0.projectID == projectID } }
    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(KanbanStage.allCases) { stage in KanbanColumn(stage: stage, tasks: tasks.filter { KanbanStage.stage(for: $0) == stage }) }
            }.padding(20)
        }
    }
}

private struct KanbanColumn: View {
    @EnvironmentObject private var store: AppStore
    let stage: KanbanStage
    let tasks: [TaskItem]
    @State private var targeted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(stage.title).font(.headline); Spacer(); Text("\(tasks.count)").font(.caption).foregroundStyle(.secondary) }
            ScrollView { LazyVStack(spacing: 10) { ForEach(tasks) { task in KanbanCard(task: task) } }.padding(.vertical, 2) }
        }
        .padding(12).frame(width: 250).frame(minHeight: 430, alignment: .top)
        .background(targeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).stroke(targeted ? Color.accentColor : Color.clear, lineWidth: 2) }
        .dropDestination(for: String.self) { values, _ in guard let raw = values.first, let id = UUID(uuidString: raw) else { return false }; store.setKanbanStage(id, stage: stage); return true } isTargeted: { targeted = $0 }
    }
}

private struct KanbanCard: View {
    @EnvironmentObject private var store: AppStore
    let task: TaskItem
    var body: some View {
        Button { store.selectedTaskID = task.id } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(task.title).font(.body.weight(.semibold)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                if !task.notes.isEmpty { Text(task.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading) }
                HStack { if let due = task.dueDay { Label(due.date().formatted(date: .abbreviated, time: .omitted), systemImage: "calendar") }; Spacer(); if task.priority != .none { Circle().fill(task.priority == .high ? Color.orange : Color.accentColor).frame(width: 7, height: 7) } }.font(.caption2).foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 10)).shadow(color: .black.opacity(0.07), radius: 3, y: 1).contentShape(Rectangle())
        }.buttonStyle(.plain).onDrag { store.calendarDragProvider(for: .task(task.id)) }.contextMenu {
            Button("Show Details") { store.selectedTaskID = task.id }
            Button("Start Focus") { store.requestFocus(task.id) }
            Menu("Move to") {
                ForEach(KanbanStage.allCases) { stage in
                    Button(stage.title) { store.setKanbanStage(task.id, stage: stage) }
                }
            }
            Divider()
            Button(task.isCompleted ? "Mark Incomplete" : "Complete") { store.toggleTask(task.id) }
        }
    }
}

struct ActivityList: View {
    let records: [ActivityRecord]
    var body: some View { VStack(alignment: .leading, spacing: 8) { Text("Recent Activity").font(.headline); if records.isEmpty { Text("No activity yet.").foregroundStyle(.secondary) }; ForEach(records.prefix(8)) { item in HStack(alignment: .top) { Text(item.date.formatted(.dateTime.day().month(.abbreviated))).font(.caption).foregroundStyle(.secondary).frame(width: 55, alignment: .leading); Text(item.title) } } } }
}

struct YearView: View {
    @EnvironmentObject private var store: AppStore
    @State private var addingDate = false
    @State private var editingDate: YearMarker?
    private var months: [Date] { let calendar = Calendar.current; let current = Date(); let startMonth = store.data.settings.academicYearStartMonth; let year = calendar.component(.month, from: current) < startMonth ? calendar.component(.year, from: current) - 1 : calendar.component(.year, from: current); let start = calendar.date(from: DateComponents(year: year, month: startMonth, day: 1))!; return (0..<12).compactMap { calendar.date(byAdding: .month, value: $0, to: start) } }
    private var upcoming: [YearMarker] { store.data.yearMarkers.filter { $0.startDay >= .today }.sorted { $0.startDay < $1.startDay } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ScreenHeader(eyebrow: "Big Picture", title: "Important Dates", detail: "Tests, exams and deadlines to prepare for, even when they have no calendar time.")
                Button("Add Test or Date", systemImage: "plus") { addingDate = true }.buttonStyle(.borderedProminent)
            }.padding(24)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Coming up").font(.headline)
                if upcoming.isEmpty { Text("Add a test or important date to keep it in view while you revise.").foregroundStyle(.secondary) }
                else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(upcoming.prefix(8)) { marker in
                                Button { editingDate = marker } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(marker.category.uppercased()).font(.caption2.bold()).foregroundStyle(.orange)
                                        Text(marker.title).font(.headline).lineLimit(2)
                                        Text(marker.startDay.date().formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                                        if let id = marker.subjectID, let subject = store.data.subjects.first(where: { $0.id == id }) { Text(subject.title).font(.caption).foregroundStyle(.secondary) }
                                    }.frame(width: 190, height: 92, alignment: .topLeading).padding(12)
                                        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }.padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            Text("Academic year").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 16)
            ScrollView([.horizontal, .vertical]) { HStack(alignment: .top, spacing: 0) { ForEach(months, id: \.self) { month in YearMonth(month: month) { editingDate = $0 }.frame(width: 230) } }.padding(24) }.defaultScrollAnchor(.topLeading).frame(maxHeight: .infinity)
        }
        .navigationTitle("Important Dates")
        .sheet(isPresented: $addingDate) { ItemCreationView(kind: .yearMarker).environmentObject(store) }
        .sheet(item: $editingDate) { marker in ImportantDateEditor(marker: marker).environmentObject(store) }
    }
}

private struct ImportantDateEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var marker: YearMarker
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Important Date").font(.title2.bold())
            TextField("Title", text: $marker.title)
            DatePicker("Date", selection: Binding(get: { marker.startDay.date() }, set: { marker.startDay = LocalDay($0) }), displayedComponents: .date)
            Picker("Type", selection: $marker.category) { Text("Test or exam").tag("Test"); Text("Deadline").tag("Deadline"); Text("Important date").tag("Important Date") }
            Picker("Subject", selection: $marker.subjectID) { Text("None").tag(UUID?.none); ForEach(store.data.subjects.filter { !$0.archived }) { Text($0.title).tag(UUID?.some($0.id)) } }
            TextField("Revision notes", text: $marker.notes, axis: .vertical).lineLimit(3...6)
            HStack {
                Button("Delete", role: .destructive) { store.deleteYearMarker(marker.id); dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { store.updateYearMarker(marker); dismiss() }.buttonStyle(.borderedProminent).disabled(marker.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 450)
    }
}

private struct YearMonth: View {
    @EnvironmentObject private var store: AppStore
    let month: Date
    let onEditMarker: (YearMarker) -> Void
    private var number: Int { Calendar.current.component(.month, from: month) }
    private var year: Int { Calendar.current.component(.year, from: month) }
    private struct Entry: Identifiable {
        var id: UUID
        var day: LocalDay
        var title: String
        var symbol: String
        var taskID: UUID? = nil
        var markerID: UUID? = nil
        var milestoneID: UUID? = nil
        var projectID: UUID? = nil
    }
    private var entries: [Entry] {
        let markers = store.data.yearMarkers.filter { $0.startDay.month == number && $0.startDay.year == year }.map { Entry(id: $0.id, day: $0.startDay, title: $0.title, symbol: "flag", markerID: $0.id) }
        let milestones = store.data.projects.flatMap { project in project.milestones.filter { !$0.isCompleted && $0.targetDay.month == number && $0.targetDay.year == year }.map { Entry(id: $0.id, day: $0.targetDay, title: $0.title, symbol: "diamond", milestoneID: $0.id, projectID: project.id) } }
        let deadlines = store.data.tasks.filter { !$0.isCompleted && $0.dueDay?.month == number && $0.dueDay?.year == year }.compactMap { task -> Entry? in guard let day = task.dueDay else { return nil }; return Entry(id: task.id, day: day, title: task.title, symbol: "circle", taskID: task.id) }
        return (markers + milestones + deadlines).sorted { $0.day < $1.day }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(month.formatted(.dateTime.month(.wide))).font(.title2.bold()); Divider()
            if entries.isEmpty { Text("Nothing marked").foregroundStyle(.tertiary).padding(.vertical, 12) }
            ForEach(entries) { item in
                Button {
                    if let taskID = item.taskID { store.selectedTaskID = taskID; store.requestedSectionRaw = "today" }
                    else if let markerID = item.markerID, let marker = store.data.yearMarkers.first(where: { $0.id == markerID }) { onEditMarker(marker) }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(item.day.day)").font(.title3.monospacedDigit()).frame(width: 28, alignment: .trailing)
                        Image(systemName: item.symbol).foregroundStyle(.tint).frame(width: 15)
                        Text(item.title).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(item.taskID == nil && item.markerID == nil)
                    .contextMenu {
                        if let taskID = item.taskID { Button("Show Task") { store.selectedTaskID = taskID; store.requestedSectionRaw = "today" } }
                        if let milestoneID = item.milestoneID, let projectID = item.projectID { Button("Complete Milestone") { store.toggleMilestone(milestoneID, projectID: projectID) } }
                    }
            }
        }.padding(.horizontal, 16).frame(maxHeight: .infinity, alignment: .top).overlay(alignment: .trailing) { Divider() }
    }
}

private enum CompletionPeriod: String, CaseIterable, Identifiable { case today = "Today", week = "This Week", month = "This Month", all = "All"; var id: String { rawValue } }

struct CompletedView: View {
    @EnvironmentObject private var store: AppStore
    let searchText: String
    @State private var period = CompletionPeriod.week
    private var tasks: [TaskItem] {
        let calendar = Calendar.current
        let start: Date? = switch period { case .today: calendar.startOfDay(for: .now); case .week: calendar.dateInterval(of: .weekOfYear, for: .now)?.start; case .month: calendar.dateInterval(of: .month, for: .now)?.start; case .all: nil }
        return store.data.tasks.filter { task in task.isCompleted && !task.isArchived && (searchText.isEmpty || task.title.localizedCaseInsensitiveContains(searchText)) && (start.map { (task.completedAt ?? .distantPast) >= $0 } ?? true) }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) { ScreenHeader(eyebrow: "History", title: "Completed", detail: "A quiet record of finished work."); Spacer(); VStack(alignment: .trailing) { Text("\(tasks.count) finished").font(.headline); Text("\(tasks.reduce(0) { $0 + $1.estimatedMinutes }) min estimated").font(.caption).foregroundStyle(.secondary) } }.padding(24)
            Picker("Period", selection: $period) { ForEach(CompletionPeriod.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.bottom, 14)
            Divider()
            if tasks.isEmpty { QuietEmptyState(title: "No completed tasks", detail: "Finished work in this period will appear here.", symbol: "checkmark.circle") } else { List(tasks) { task in TaskRow(task: task) } }
        }.navigationTitle("Completed")
    }
}

struct HelpView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showWalkthrough = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ScreenHeader(eyebrow: "LifeBoard Help", title: "A small guide", detail: storageDescription(data: store.data, mobileConnected: store.mobileURL != nil))
                Button("Show walkthrough", systemImage: "sparkles.rectangle.stack") { showWalkthrough = true }.buttonStyle(.borderedProminent)
                HelpSection(title: "Capturing Tasks", symbol: "plus", text: "Press Command–N anywhere. Type one task, paste a list, or add a screenshot. Check the single preview, then add everything to To Do with or without a suggested schedule.")
                HelpSection(title: "Scheduling Work", symbol: "calendar", text: "A task can stay in Anytime, belong to a day without a time, or sit at an exact time. Drag tasks between these places whenever plans change. Double-click or right-click an empty calendar time to add something there.")
                HelpSection(title: "Focus", symbol: "timer", text: "Open Focus for an unlinked 25-minute, 50-minute or custom timer, or use the timer button on any To Do. Pause, resume, stop, reset, start a break or complete the linked task.")
                HelpSection(title: "Details & Right-Click", symbol: "cursorarrow.click.2", text: "Click any calendar task or event to edit it in the inspector. Right-click tasks and calendar blocks for scheduling, assignments, duplication, completion and other common actions.")
                HelpSection(title: "Renaming", symbol: "pencil", text: "Task and event titles are editable in the inspector. Open a subject or project and edit its Name field; topic and milestone names are editable in place.")
                HelpSection(title: "Subjects and Projects", symbol: "books.vertical", text: "Subject confidence is your self-assessment from 1 to 5; course and topic progress are manually maintained percentages. Project progress is manually maintained unless you choose task or milestone completion in its details. Projects hold milestones, notes and a progress journal. Completing linked tasks updates recent activity automatically.")
                HelpSection(title: "Backups", symbol: "externaldrive", text: "Open Settings › Data to create or restore a human-readable JSON backup. Backups are saved in your LifeBoard Application Support folder.")
                HelpSection(title: "Desktop Widget", symbol: "widget.medium", text: "Control-click the desktop, choose Edit Widgets, search LifeBoard, then drag the widget onto the desktop.")
                HelpSection(title: "ChatGPT Integration", symbol: "link", text: "Drop a task photo into ChatGPT or Codex and ask it to import the items into LifeBoard. It can create one compact JSON batch and run the bundled helper once. A request such as “Put these on Wednesday but leave them untimed” preserves that distinction. Bulk replacement always requires confirmation inside the app.")
            }
            .padding(30).frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle("Help")
        .sheet(isPresented: $showWalkthrough) { WelcomeWalkthroughView().environmentObject(store) }
    }
}

private struct HelpSection: View { let title: String; let symbol: String; let text: String; var body: some View { HStack(alignment: .top, spacing: 14) { Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 30); VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) } } } }

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var settings = AppSettings()
    @State private var revealPairing = false
    @State private var showTrash = false
    @State private var showConflicts = false
    @State private var backupSummary: AppStore.BackupSummary?
    @State private var backups: [AppStore.AvailableBackup] = []
    private var calendarAccounts: [String] {
        Array(Set(store.externalCalendars.map(\.account))).sorted { left, right in
            if left == "Google" { return true }
            if right == "Google" { return false }
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
    }
    var body: some View {
        TabView {
            Form {
                Stepper("Default task duration: \(settings.defaultTaskMinutes) minutes", value: $settings.defaultTaskMinutes, in: 5...180, step: 5)
                Toggle("Week starts Monday", isOn: $settings.weekStartsMonday)
                Picker("Academic year starts", selection: $settings.academicYearStartMonth) { ForEach(1...12, id: \.self) { month in Text(Calendar.current.monthSymbols[month - 1]).tag(month) } }
            }.tabItem { Label("General", systemImage: "gear") }
            Form {
                DatePicker("Evening starts", selection: timeBinding(\.eveningStartMinutes), displayedComponents: .hourAndMinute)
                DatePicker("Evening ends", selection: timeBinding(\.eveningEndMinutes), displayedComponents: .hourAndMinute)
                Stepper("Maximum focused block: \(settings.maxFocusMinutes) minutes", value: $settings.maxFocusMinutes, in: 20...120, step: 5)
                Stepper("Default break: \(settings.breakMinutes) minutes", value: $settings.breakMinutes, in: 0...30, step: 5)
            }.tabItem { Label("Planning", systemImage: "clock") }
            VStack(alignment: .leading, spacing: 18) {
                Text(storageDescription(data: store.data, mobileConnected: store.mobileURL != nil)).foregroundStyle(.secondary)
                Button("Open Trash…") { showTrash = true }
                Text("Deleted tasks stay in Trash until restored. JSON exports include private task notes and calendar details; store them securely.").font(.caption).foregroundStyle(.secondary)
                Button("Export Backup…") { _ = store.exportBackup() }
                Button("Import Backup…") {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { backupSummary = store.inspectBackup(url) }
                }
                Divider()
                Toggle(LifeBoardEnvironment.isPreview ? "Automatic Backup" : "Automatic iCloud Backup", isOn: $settings.automaticICloudBackup)
                Text(LifeBoardEnvironment.isPreview ? "The Preview keeps a small set of recent backups in its own folder on this Mac, never in iCloud Drive." : "Local storage remains the source of truth. LifeBoard keeps a small set of recent backups in iCloud Drive.").font(.caption).foregroundStyle(.secondary)
                if let last = store.lastAutomaticBackup { Text("Last backup: \(last.formatted(date: .abbreviated, time: .shortened))").font(.callout) }
                else { Text("No automatic iCloud backup yet").font(.callout).foregroundStyle(.secondary) }
                Button("Back Up Now") { store.performICloudBackup(force: true); settings = store.data.settings }.disabled(!settings.automaticICloudBackup)
                Divider(); Text("Backup Centre").font(.headline)
                HStack { Text("Preview a backup before restoring it.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Refresh list") { backups = store.availableBackups() } }
                ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(backups) { backup in
                    Button { backupSummary = store.inspectBackup(backup.url) } label: { VStack(alignment: .leading) { Text(backup.url.lastPathComponent); if let date = backup.date { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) } } }.buttonStyle(.plain).accessibilityHint("Preview backup counts and restore confirmation")
                } } }.frame(maxHeight: 150)
                Divider(); Text("Data location").font(.headline)
                Text(store.repository.fileURL.path).font(.caption).textSelection(.enabled).foregroundStyle(.secondary); Spacer()
            }.padding(24).tabItem { Label("Data", systemImage: "externaldrive") }
            Form {
                Section("Notifications") {
                    Toggle("Scheduled items", isOn: $settings.notificationsScheduledItems)
                    Stepper("Notify \(settings.notificationLeadMinutes) minutes before", value: $settings.notificationLeadMinutes, in: 5...60, step: 5).disabled(!settings.notificationsScheduledItems)
                    Toggle("Deadlines", isOn: $settings.notificationsDeadlines)
                    Toggle("Focus and break completion", isOn: $settings.notificationsFocus)
                }
                Text("LifeBoard asks for permission only when you enable a notification type.").font(.caption).foregroundStyle(.secondary)
            }.tabItem { Label("Notifications", systemImage: "bell") }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                Text("Mobile LifeBoard").font(.title2.bold())
                if let mobileURL = store.mobileURL {
                    Text("Connect your iPhone").font(.headline)
                    Text("On your iPhone, open \(mobileURL.absoluteString) in Safari, then enter the code below once on that phone. Add the page to your Home Screen after connecting.")
                        .font(.callout).textSelection(.enabled)
                    Button("Create one-time pairing code") { revealPairing = false; Task { await store.createPairingChallenge() } }.buttonStyle(.borderedProminent)
                    if let code = store.pairingChallenge?.code {
                        Text("Expires: \(store.pairingChallenge?.expiresAt ?? "soon") · one use only").font(.caption).foregroundStyle(.secondary)
                        Text("A pairing code grants this workspace's tasks, notes, Focus history and selected calendar cache to the connected device.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Reveal pairing code", isOn: $revealPairing)
                        if revealPairing { HStack {
                            Text(code).font(.system(.title2, design: .monospaced).bold()).textSelection(.enabled).accessibilityLabel("Phone pairing code")
                            Button("Copy Code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) }
                        } }
                    }
                    Text("Tip: Copy Code on your Mac, then paste it on your iPhone if Universal Clipboard is enabled.").font(.caption).foregroundStyle(.secondary)
                    Text(store.syncStatus).foregroundStyle(.secondary)
                    Button("Retry Keychain access…") { Task { await store.authoriseStoredConnection() } }
                        .help("Allow this LifeBoard build to use your existing connection after an update. Background sync never opens permission prompts.")
                    if let last = store.lastSuccessfulSync { Text("Last successful sync: \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    if !store.syncConflicts.isEmpty { Button("Resolve \(store.syncConflicts.count) sync conflicts…") { showConflicts = true }.buttonStyle(.borderedProminent) }
                    HStack {
                        Button("Open Mobile App") { NSWorkspace.shared.open(mobileURL) }
                        Button("Sync Now") { Task { await store.syncNow() } }
                    }
                    Divider()
                    HStack { Text("Connected devices").font(.headline); Spacer(); Button("Refresh devices") { Task { await store.refreshConnectedDevices() } } }
                    ForEach(store.connectedDevices) { device in
                        HStack { VStack(alignment: .leading) { Text(device.name); Text("Connected: \(device.createdAt) · expires \(device.expiresAt)").font(.caption).foregroundStyle(.secondary) }; Spacer(); if !device.managesDevices { Button("Revoke", role: .destructive) { Task { await store.revokeConnectedDevice(device.id) } }.accessibilityLabel("Revoke access for \(device.name)") } else { Text("Workspace manager").font(.caption).foregroundStyle(.secondary) } }
                    }
                    Text("Revoking stops server access. Cached offline copies cannot be remotely erased; signing out clears this device's cache.").font(.caption).foregroundStyle(.secondary)
                    Button("Disconnect this Mac", role: .destructive) { store.disconnectSync() }
                    Text("Your Mac keeps working offline. Mobile changes sync when both devices can connect.").font(.caption).foregroundStyle(.secondary)
                } else if !LifeBoardEnvironment.networkSyncAllowed {
                    Label("Mobile sync is off in LifeBoard Preview", systemImage: "iphone.slash").font(.headline)
                    Text("The Preview keeps its own planner on this Mac. It cannot connect to your sync workspace, pair a phone or send data anywhere, so your installed LifeBoard and phone stay exactly as they are.").foregroundStyle(.secondary)
                } else {
                    Text("Connect a private beta workspace").font(.headline)
                    Text("Open the invitation supplied to you on your own Mac. Each tester receives a separate workspace.").foregroundStyle(.secondary)
                    Button("Open workspace invitation…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url { Task { await store.connectInvitation(url) } }
                    }
                }
                Divider()
                Text("Connected Calendars").font(.title2.bold())
                Text("LifeBoard reads the Google, iCloud and Microsoft Exchange calendars you select from macOS Internet Accounts. Selected events are cached locally and included in private mobile sync.").foregroundStyle(.secondary)
                HStack { Button("Connect Calendars") { Task { await store.connectGoogleCalendar() } }.buttonStyle(.borderedProminent); Button("Refresh") { Task { await store.refreshGoogleCalendar() } }.disabled(store.externalCalendars.isEmpty); Button("Add Calendar Account to Mac…") { store.openInternetAccounts() } }
                Text(store.calendarConnectionStatus).font(.callout).foregroundStyle(.secondary)
                if !store.externalCalendars.isEmpty {
                    Divider(); Text("Calendars to show").font(.headline)
                    Text("Choose an account, then fine-tune individual calendars. Your current selections stay as they are until you change them.").font(.caption).foregroundStyle(.secondary)
                    ForEach(calendarAccounts, id: \.self) { account in
                        let calendars = store.externalCalendars.filter { $0.account == account }
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Show \(account) calendars", isOn: Binding(
                                get: { calendars.contains { store.data.settings.selectedExternalCalendarIDs.contains($0.id) } },
                                set: { store.setExternalCalendars(calendars.map(\.id), enabled: $0) }
                            )).font(.headline)
                            Text("\(calendars.filter { store.data.settings.selectedExternalCalendarIDs.contains($0.id) }.count) of \(calendars.count) selected").font(.caption).foregroundStyle(.secondary)
                            ForEach(calendars) { calendar in
                                Toggle(calendar.title, isOn: Binding(
                                    get: { store.data.settings.selectedExternalCalendarIDs.contains(calendar.id) },
                                    set: { store.setExternalCalendar(calendar.id, enabled: $0) }
                                )).padding(.leading, 20)
                            }
                        }.padding(.vertical, 6)
                    }
                }
                Divider(); Text("ChatGPT & Automation").font(.headline)
                Text("Attach a photo or list in ChatGPT or Codex and ask it to add the tasks to LifeBoard. One local batch import adds them to To Do; dates and scheduling remain optional.").foregroundStyle(.secondary)
                Divider(); Text("Add the desktop widget").font(.headline)
                Text("Control-click the desktop, choose Edit Widgets, search for LifeBoard, then drag the widget onto the desktop.").foregroundStyle(.secondary)
                }.frame(maxWidth: 780, alignment: .leading).padding(24)
            }.tabItem { Label("Integrations", systemImage: "link") }
            VStack(alignment: .leading, spacing: 13) {
                Text("LifeBoard").font(.largeTitle.bold())
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.0") · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "5")").font(.headline).foregroundStyle(.secondary)
                Text("A calm place for what you need to do, when you intend to do it, and the work you are doing now.").font(.body)
                Divider()
                Text("Your Mac keeps an editable local copy. When mobile sync is connected, LifeBoard records and selected connected-calendar events are stored in your private sync database and cached on your phone. Optional iCloud backups are separate. LifeBoard has no analytics or ads.")
                    .foregroundStyle(.secondary)
                Spacer()
            }.padding(24).tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(12).navigationTitle("Settings")
        .onAppear { settings = store.data.settings; backups = store.availableBackups() }
        .onChange(of: settings) { _, value in if store.data.settings != value { store.updateSettings(value) } }
        .onChange(of: store.data.settings) { _, value in if settings != value { settings = value } }
        .sheet(isPresented: $showConflicts) { NativeSyncConflictView().environmentObject(store) }
        .sheet(isPresented: $showTrash) { TrashView().environmentObject(store) }
        .alert(item: $backupSummary) { summary in
            Alert(title: Text("Restore this backup?"), message: Text("Schema \(summary.schemaVersion) · \(summary.tasks) tasks · \(summary.projects) projects · \(summary.subjects) subjects · \(summary.focusSessions) focus sessions\n\nLifeBoard will save the current workspace before replacing it."), primaryButton: .destructive(Text("Restore")) { store.replaceWithBackup(summary.url); settings = store.data.settings }, secondaryButton: .cancel())
        }
    }

    private func timeBinding(_ path: WritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(get: { let value = settings[keyPath: path]; return Calendar.current.date(bySettingHour: value / 60, minute: value % 60, second: 0, of: .now) ?? .now }, set: { date in let components = Calendar.current.dateComponents([.hour, .minute], from: date); settings[keyPath: path] = (components.hour ?? 0) * 60 + (components.minute ?? 0) })
    }
}


private func storageDescription(data: LifeBoardData, mobileConnected: Bool) -> String {
    var text = "LifeBoard keeps an editable JSON file on this Mac."
    text += mobileConnected ? " Connected phone sync stores workspace records and selected calendar details in your private sync database and browser cache. Offline edits sync on reconnection." : " Phone sync is not configured; records remain in local storage."
    text += data.settings.automaticICloudBackup ? " Automatic iCloud Drive backups are enabled and are separate from sync." : " Automatic iCloud Drive backups are off. User-created JSON exports remain readable."
    return text
}

struct TrashView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    private var tasks: [TaskItem] { store.data.tasks.filter(\.isArchived).sorted { $0.modifiedAt > $1.modifiedAt } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Trash").font(.title.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Restore a task without replacing unrelated workspace changes.").foregroundStyle(.secondary)
            if tasks.isEmpty { QuietEmptyState(title: "Trash is empty", detail: "Deleted tasks appear here.", symbol: "trash") }
            else { List(tasks) { task in HStack { VStack(alignment: .leading) { Text(task.title); Text(task.modifiedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Restore") { store.restoreTask(task.id) }.accessibilityLabel("Restore \(task.title)") } } }
        }.padding(24).frame(minWidth: 500, minHeight: 360)
    }
}

struct ExternalImportReviewView: View {
    @EnvironmentObject private var store: AppStore
    let preview: AppStore.ExternalImportPreview
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review external import").font(.title.bold())
            Text("Source: \(preview.source) · \(preview.tasks.count) tasks").foregroundStyle(.secondary)
            List(preview.tasks) { task in VStack(alignment: .leading) { Text(task.title).font(.headline); Text("Estimate: \(task.estimatedMinutes) min · Priority: \(task.priority.title)"); if let due = task.dueDay { Text("Due: \(due.id)") }; if let day = task.scheduledDay { Text("Planned: \(day.id) \(task.scheduledStartMinutes.map(timeString) ?? "untimed")") }; if !task.notes.isEmpty { Text(task.notes).foregroundStyle(.secondary) } } }
            HStack { Button("Cancel") { store.cancelExternalImport() }.keyboardShortcut(.cancelAction); Spacer(); Button("Add \(preview.tasks.count) tasks") { store.acceptExternalImport() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(minWidth: 560, minHeight: 400)
    }
}


struct NativeSyncConflictView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [String: Bool] = [:]
    @State private var resolving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Resolve sync conflicts").font(.title.bold())
            Text("Choose the value to keep for each field. Your local workspace remains available while changes are paused.").foregroundStyle(.secondary)
            List(store.syncConflicts) { conflict in
                VStack(alignment: .leading, spacing: 8) {
                    Text(conflict.path).font(.headline)
                    Text("This Mac: \(conflict.localValue)").textSelection(.enabled)
                    Text("Other device: \(conflict.remoteValue)").textSelection(.enabled)
                    Picker("Keep value", selection: Binding<Bool?>(get: { choices[conflict.path] }, set: { choices[conflict.path] = $0 })) { Text("Choose…").tag(Optional<Bool>.none); Text("This Mac").tag(Optional(true)); Text("Other device").tag(Optional(false)) }.pickerStyle(.segmented)
                }.padding(.vertical, 8)
            }
            HStack { Button("Close") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button(resolving ? "Resolving…" : "Apply choices") { resolving = true; Task { await store.resolveSyncConflicts(choices: choices); resolving = false; if store.syncConflicts.isEmpty { dismiss() } } }.disabled(resolving || store.syncConflicts.contains { choices[$0.path] == nil }).buttonStyle(.borderedProminent) }
        }.padding(24).frame(minWidth: 620, minHeight: 440)
    }
}
