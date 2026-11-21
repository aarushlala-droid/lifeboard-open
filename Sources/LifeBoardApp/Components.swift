import SwiftUI
import UniformTypeIdentifiers
import LifeBoardCore

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.undoManager) private var undoManager
    @Binding var selected: AppSection
    @Binding var showQuickAdd: Bool
    @State private var showInspector = false
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarBeforeInspector: NavigationSplitViewVisibility = .all
    @State private var searchText = ""
    @State private var creationKind: CreationKind?

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            List(selection: $selected) {
                Section("Do") { SidebarRow(section: .today); SidebarRow(section: .inbox) }
                Section("Plan") { SidebarRow(section: .calendar); SidebarRow(section: .focus) }
                Section("Big Picture") { SidebarRow(section: .subjects); SidebarRow(section: .projects); SidebarRow(section: .year) }
                Section { SidebarRow(section: .completed); SidebarRow(section: .settings); SidebarRow(section: .help) }
            }
            .navigationTitle("LifeBoard")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            HStack(spacing: 0) {
                Group {
                    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        switch selected {
                        case .today: TodayView(searchText: searchText)
                        case .calendar: CalendarView(searchText: searchText)
                        case .inbox: InboxView(searchText: searchText)
                        case .focus: FocusDashboardView()
                        case .subjects: SubjectsView(searchText: searchText)
                        case .projects: ProjectsView(searchText: searchText)
                        case .year: YearView()
                        case .completed: CompletedView(searchText: searchText)
                        case .settings: SettingsView()
                        case .help: HelpView()
                        }
                    } else {
                        SearchResultsView(query: searchText, selectedSection: $selected)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showInspector {
                    Divider()
                    Group {
                        if let id = store.selectedTaskID { TaskInspector(taskID: id).id(id) }
                        else if let id = store.selectedEventID { EventInspector(eventID: id).id(id) }
                        else { ContentUnavailableView("Nothing Selected", systemImage: "sidebar.trailing", description: Text("Select a task or event to inspect its details.")) }
                    }
                    .frame(width: 330)
                    .frame(maxHeight: .infinity)
                    .background(.bar)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search LifeBoard")
            .toolbar {
                ToolbarItemGroup {
                    Button("Capture", systemImage: "plus") { showQuickAdd = true }
                        .buttonStyle(.borderedProminent)
                        .help("Capture one task, a list, or an image (⌘N)")
                    Menu {
                        Button("Task…", systemImage: "checklist") { creationKind = .task }
                        Button("Event…", systemImage: "calendar.badge.plus") { creationKind = .event }
                        Button("Project…", systemImage: "folder.badge.plus") { creationKind = .project }
                        Button("Subject…", systemImage: "book.closed") { creationKind = .subject }
                        Button("Milestone…", systemImage: "diamond") { creationKind = .milestone }
                        Button("Year Marker…", systemImage: "flag") { creationKind = .yearMarker }
                    } label: { Label("More", systemImage: "ellipsis.circle") }
                    .help("Create an event or Big Picture item")
                    Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                        .disabled(store.selectedTaskID == nil && store.selectedEventID == nil)
                        .help("Show details")
                }
            }
            .onChange(of: selected) { _, _ in showInspector = false }
            .onChange(of: showInspector) { _, visible in
                if visible { sidebarBeforeInspector = sidebarVisibility; sidebarVisibility = .detailOnly }
                else { sidebarVisibility = sidebarBeforeInspector }
            }
            .onChange(of: store.selectedTaskID) { _, value in if value != nil { showInspector = true } }
            .onChange(of: store.selectedEventID) { _, value in if value != nil { showInspector = true } }
            .onChange(of: store.requestedSectionRaw) { _, raw in if let raw, let section = AppSection(rawValue: raw) { selected = section; store.requestedSectionRaw = nil } }
            .sheet(item: $creationKind) { kind in ItemCreationView(kind: kind).environmentObject(store) }
            .sheet(isPresented: Binding(get: { store.focusRequestTaskID != nil }, set: { if !$0 { store.focusRequestTaskID = nil } })) {
                if let taskID = store.focusRequestTaskID { FocusStartView(taskID: taskID).environmentObject(store) }
            }
            .sheet(item: $store.focusCompletion) { completion in FocusCompletionView(completion: completion).environmentObject(store) }
            .safeAreaInset(edge: .bottom, spacing: 0) { ActiveFocusBar().environmentObject(store) }
            .onAppear { store.undoManager = undoManager }
        }
    }
}

struct SearchResultsView: View {
    @EnvironmentObject private var store: AppStore
    let query: String
    @Binding var selectedSection: AppSection

    private var needle: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func matches(_ values: String...) -> Bool { values.contains { $0.localizedCaseInsensitiveContains(needle) } }
    private var tasks: [TaskItem] { store.data.tasks.filter { !$0.isArchived && matches($0.title, $0.notes, $0.tags.joined(separator: " ")) } }
    private var subjects: [LifeBoardCore.Subject] { store.data.subjects.filter { subject in matches(subject.title, subject.notes) || subject.topics.contains { matches($0.title, $0.notes) } } }
    private var projects: [Project] { store.data.projects.filter { project in matches(project.title, project.summary, project.notes) || project.milestones.contains { matches($0.title, $0.notes) } || project.updates.contains { matches($0.text) } } }
    private var events: [CalendarEvent] { store.data.events.filter { matches($0.title, $0.notes, $0.location) } }
    private var markers: [YearMarker] { store.data.yearMarkers.filter { matches($0.title, $0.notes, $0.category) } }
    private var total: Int { tasks.count + subjects.count + projects.count + events.count + markers.count }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(eyebrow: "Search", title: "Results for “\(needle)”", detail: total == 1 ? "1 result" : "\(total) results").padding(24)
            Divider()
            if total == 0 {
                ContentUnavailableView.search(text: needle)
            } else {
                List {
                    if !tasks.isEmpty { Section("Tasks") { ForEach(tasks) { TaskRow(task: $0) } } }
                    if !subjects.isEmpty { Section("Subjects & Topics") { ForEach(subjects) { subject in SearchDestinationRow(title: subject.title, detail: subject.topics.filter { matches($0.title, $0.notes) }.map(\.title).joined(separator: ", "), symbol: "books.vertical") { selectedSection = .subjects } } } }
                    if !projects.isEmpty { Section("Projects, Milestones & Notes") { ForEach(projects) { project in SearchDestinationRow(title: project.title, detail: project.summary, symbol: "folder") { selectedSection = .projects } } } }
                    if !events.isEmpty { Section("Events") { ForEach(events) { event in SearchDestinationRow(title: event.title, detail: event.day.date().formatted(date: .abbreviated, time: .omitted), symbol: "calendar") { selectedSection = .calendar } } } }
                    if !markers.isEmpty { Section("Year Markers") { ForEach(markers) { marker in SearchDestinationRow(title: marker.title, detail: marker.startDay.date().formatted(date: .abbreviated, time: .omitted), symbol: "flag") { selectedSection = .year } } } }
                }.listStyle(.inset)
            }
        }.navigationTitle("Search")
    }
}

private struct SearchDestinationRow: View {
    let title: String
    let detail: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol).foregroundStyle(.tint).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) { Text(title); if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }
                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

enum CreationKind: String, Identifiable {
    case task, event, project, subject, milestone, yearMarker
    var id: String { rawValue }
    var title: String { switch self { case .task: "New Task"; case .event: "New Event"; case .project: "New Project"; case .subject: "New Subject"; case .milestone: "New Milestone"; case .yearMarker: "New Important Date" } }
}

struct ItemCreationView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let kind: CreationKind
    @State private var title = ""
    @State private var day = Date.now
    @State private var startTime = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: .now) ?? .now
    @State private var duration = 60
    @State private var location = ""
    @State private var notes = ""
    @State private var projectID: UUID?
    @State private var subjectID: UUID?
    @State private var hasDueDate = false
    @State private var markerCategory = "Test"
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(kind.title).font(.title2.bold())
            TextField("Title", text: $title).focused($focused)
            if kind == .task {
                Stepper("Duration: \(duration) minutes", value: $duration, in: 5...480, step: 5)
                Toggle("Due date", isOn: $hasDueDate)
                if hasDueDate { DatePicker("Due", selection: $day, displayedComponents: .date) }
                Picker("Subject", selection: $subjectID) { Text("None").tag(UUID?.none); ForEach(store.data.subjects.filter { !$0.archived }) { Text($0.title).tag(UUID?.some($0.id)) } }
                Picker("Project", selection: $projectID) { Text("None").tag(UUID?.none); ForEach(store.data.projects.filter { $0.status != .archived }) { Text($0.title).tag(UUID?.some($0.id)) } }
                TextField("Notes (optional)", text: $notes, axis: .vertical).lineLimit(2...5)
            }
            if kind == .event || kind == .milestone || kind == .yearMarker { DatePicker("Date", selection: $day, displayedComponents: .date) }
            if kind == .yearMarker {
                Picker("Type", selection: $markerCategory) { Text("Test or exam").tag("Test"); Text("Deadline").tag("Deadline"); Text("Important date").tag("Important Date") }
                Picker("Subject", selection: $subjectID) { Text("None").tag(UUID?.none); ForEach(store.data.subjects.filter { !$0.archived }) { Text($0.title).tag(UUID?.some($0.id)) } }
                TextField("Revision notes (optional)", text: $notes, axis: .vertical).lineLimit(2...5)
            }
            if kind == .event {
                DatePicker("Start", selection: $startTime, displayedComponents: .hourAndMinute)
                Stepper("Duration: \(duration) minutes", value: $duration, in: 15...480, step: 15)
                TextField("Location (optional)", text: $location)
                TextField("Notes (optional)", text: $notes, axis: .vertical).lineLimit(2...5)
            }
            if kind == .milestone { Picker("Project", selection: $projectID) { Text("Choose a project").tag(UUID?.none); ForEach(store.data.projects) { Text($0.title).tag(UUID?.some($0.id)) } } }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Create") { create() }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || (kind == .milestone && projectID == nil)) }
        }.padding(24).frame(width: 460).onAppear { duration = kind == .task ? store.data.settings.defaultTaskMinutes : 60; focused = true }
    }

    private func create() {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .task:
            var task = TaskItem(title: clean); task.estimatedMinutes = duration; task.notes = notes; task.dueDay = hasDueDate ? LocalDay(day) : nil; task.subjectID = subjectID; task.projectID = projectID; _ = store.addTask(task)
        case .event:
            let c = Calendar.current.dateComponents([.hour, .minute], from: startTime); let start = (c.hour ?? 18) * 60 + (c.minute ?? 0)
            var event = CalendarEvent(title: clean, day: LocalDay(day), startMinutes: start, endMinutes: start + duration); event.location = location; event.notes = notes; store.addEvent(event)
        case .project: store.addProject(title: clean)
        case .subject: store.addSubject(title: clean)
        case .milestone: if let projectID { store.addMilestone(title: clean, projectID: projectID, day: LocalDay(day)) }
        case .yearMarker: store.addYearMarker(title: clean, day: LocalDay(day), category: markerCategory, notes: notes, subjectID: subjectID)
        }
        dismiss()
    }
}

private struct SidebarRow: View {
    let section: AppSection
    init(section: AppSection) { self.section = section }
    var body: some View { Label(section.title, systemImage: section.icon).tag(section) }
}

struct QuickAddView: View {
    enum ImportMode: String, CaseIterable, Identifiable { case todo = "Add to To Do", schedule = "Suggest Schedule"; var id: String { rawValue } }

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var drafts: [CapturedTaskDraft] = []
    @State private var mode: ImportMode
    @State private var isInterpreting = false
    @State private var interpretationTask: Task<Void, Never>?
    @State private var note = CaptureIntelligence.availabilityDescription()
    @State private var errorText: String?
    @State private var imageName: String?
    @FocusState private var inputFocused: Bool
    private let initialDay: LocalDay?
    private let initialStartMinutes: Int?

    init(initialDay: LocalDay? = nil, initialStartMinutes: Int? = nil) {
        self.initialDay = initialDay
        self.initialStartMinutes = initialStartMinutes
        _mode = State(initialValue: initialDay == nil ? .todo : .schedule)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Capture").font(.title2.bold())
                    Text("Type naturally, paste a list, or drop a screenshot.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    TextEditor(text: $input)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .topLeading) {
                            if input.isEmpty { Text("chem worksheet tomorrow 30m\nenglish essay friday 45m\nresearch intro tonight").foregroundStyle(.tertiary).padding(16).allowsHitTesting(false) }
                        }
                        .focused($inputFocused)
                        .frame(minHeight: 220)
                        .accessibilityLabel("Tasks to capture")

                    HStack {
                        Button("Paste", systemImage: "doc.on.clipboard") { pasteFromClipboard() }
                        Button("Choose Image…", systemImage: "photo") { chooseImage() }
                        if let imageName { Label(imageName, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                    }

                    RoundedRectangle(cornerRadius: 10)
                        .fill(.quaternary.opacity(0.18))
                        .frame(height: 88)
                        .overlay { Label("Drop a screenshot or photo here", systemImage: "arrow.down.doc").foregroundStyle(.secondary) }
                        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.separator, style: StrokeStyle(lineWidth: 1, dash: [5])) }
                        .dropDestination(for: URL.self) { urls, _ in importDropped(urls); return !urls.isEmpty }

                    if let errorText { Label(errorText, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
                    Text(note).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        interpret()
                    } label: {
                        if isInterpreting { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                        else { Label(drafts.isEmpty ? "Interpret" : "Interpret Again", systemImage: "sparkles").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isInterpreting)
                }
                .padding(20).frame(minWidth: 330, idealWidth: 390)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Preview").font(.headline)
                        if !drafts.isEmpty { Text("\(drafts.filter(\.isIncluded).count) selected").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Picker("Import mode", selection: $mode) { ForEach(ImportMode.allCases) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 270)
                    }

                    if drafts.isEmpty {
                        ContentUnavailableView("Nothing interpreted yet", systemImage: "text.badge.plus", description: Text("LifeBoard will show every task here before it adds anything."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            ForEach($drafts) { $draft in
                                CapturePreviewRow(draft: $draft, scheduling: mode == .schedule)
                            }
                        }.listStyle(.inset)
                    }

                    Divider()
                    HStack {
                        Text(mode == .todo ? "Dates become due dates; calendar scheduling stays optional." : "Suggested times are shown above before they are applied.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Add \(drafts.filter(\.isIncluded).count) Item\(drafts.filter(\.isIncluded).count == 1 ? "" : "s")") { confirmImport() }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(drafts.allSatisfy { !$0.isIncluded } || isInterpreting)
                    }
                }
                .padding(20).frame(minWidth: 480, idealWidth: 580)
            }
        }
        .frame(minWidth: 900, minHeight: 590)
        .onAppear { inputFocused = true }
        .onDisappear { interpretationTask?.cancel(); interpretationTask = nil }
        .onChange(of: mode) { _, value in if value == .schedule { drafts = NaturalLanguageTaskParser.suggestedSchedule(for: drafts, data: store.data) } }
    }

    private func interpret() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isInterpreting = true; errorText = nil
        interpretationTask?.cancel()
        interpretationTask = Task {
            let result = await CaptureIntelligence.interpret(text: text, data: store.data)
            guard !Task.isCancelled else { return }
            var interpreted = result.drafts
            if let initialDay {
                for index in interpreted.indices where interpreted[index].targetDay == nil { interpreted[index].targetDay = initialDay }
                if interpreted.count == 1 { interpreted[0].startMinutes = initialStartMinutes }
            }
            if mode == .schedule { interpreted = NaturalLanguageTaskParser.suggestedSchedule(for: interpreted, data: store.data) }
            drafts = interpreted; note = result.note; isInterpreting = false
        }
    }

    private func confirmImport() {
        let selected = drafts.filter(\.isIncluded)
        let tasks = selected.filter { $0.kind == .task }.map { draft -> TaskItem in
            var task = TaskItem(title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines))
            task.notes = draft.notes
            task.estimatedMinutes = draft.estimatedMinutes
            task.priority = draft.priority
            task.subjectID = draft.subjectID
            task.projectID = draft.projectID
            task.dueDay = draft.targetDay
            if mode == .schedule {
                task.scheduledDay = draft.targetDay ?? .today
                task.scheduledStartMinutes = draft.startMinutes
                task.scheduledDurationMinutes = draft.startMinutes == nil ? nil : draft.estimatedMinutes
            }
            return task
        }.filter { !$0.title.isEmpty }
        let events = selected.filter { $0.kind == .event }.compactMap { draft -> CalendarEvent? in
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let start = draft.startMinutes else { return nil }
            var event = CalendarEvent(title: title, day: draft.targetDay ?? .today, startMinutes: start, endMinutes: start + draft.estimatedMinutes)
            event.notes = draft.notes; event.projectID = draft.projectID
            return event
        }
        if events.contains(where: { $0.endMinutes > 1440 }) { errorText = "An event crosses midnight. Adjust its duration or enter separate day segments before adding."; return }
        if store.addCapturedItems(tasks: tasks, events: events) { dismiss() } else { errorText = "The capture could not be saved. Review conflicting times or invalid fields." }
    }

    private func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let image = NSImage(pasteboard: pasteboard) { process(image: image, name: "Pasted image"); return }
        if let string = pasteboard.string(forType: .string), !string.isEmpty { input = string; interpret(); return }
        errorText = "The clipboard does not contain text or an image."
    }

    private func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { process(url: url) }
    }

    private func importDropped(_ urls: [URL]) {
        guard let url = urls.first else { return }; process(url: url)
    }

    private func process(url: URL) {
        isInterpreting = true; errorText = nil; imageName = url.lastPathComponent
        interpretationTask?.cancel()
        interpretationTask = Task {
            do { let result = try await CaptureIntelligence.interpretImage(at: url, data: store.data); guard !Task.isCancelled else { return }; drafts = result.drafts; note = result.note; isInterpreting = false }
            catch { errorText = error.localizedDescription; isInterpreting = false }
        }
    }

    private func process(image: NSImage, name: String) {
        isInterpreting = true; errorText = nil; imageName = name
        interpretationTask?.cancel()
        interpretationTask = Task {
            do { let result = try await CaptureIntelligence.interpretImage(in: image, data: store.data); guard !Task.isCancelled else { return }; drafts = result.drafts; note = result.note; isInterpreting = false }
            catch { errorText = error.localizedDescription; isInterpreting = false }
        }
    }
}

private struct CapturePreviewRow: View {
    @EnvironmentObject private var store: AppStore
    @Binding var draft: CapturedTaskDraft
    let scheduling: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("Include \(draft.title)", isOn: $draft.isIncluded).labelsHidden().toggleStyle(.checkbox).padding(.top, 4)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    TextField("Title", text: $draft.title).font(.body.weight(.medium)).textFieldStyle(.plain)
                    if draft.needsReview { Label("Review", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
                    Picker("Type", selection: $draft.kind) { ForEach(CapturedItemKind.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 82)
                }
                if let reason = draft.reviewReason { Text(reason).font(.caption).foregroundStyle(.orange) }
                if !draft.originalText.isEmpty { DisclosureGroup("Original text") { Text(draft.originalText).textSelection(.enabled).font(.caption) } }
                HStack(spacing: 10) {
                    Toggle("Date", isOn: Binding(get: { draft.targetDay != nil }, set: { draft.targetDay = $0 ? .today : nil })).toggleStyle(.checkbox)
                    if draft.targetDay != nil {
                        DatePicker("Date", selection: Binding(get: { (draft.targetDay ?? .today).date() }, set: { draft.targetDay = LocalDay($0) }), displayedComponents: .date).labelsHidden().fixedSize()
                    }
                    Stepper("\(draft.estimatedMinutes) min", value: $draft.estimatedMinutes, in: 5...480, step: 5).fixedSize()
                    if scheduling {
                        Toggle("Exact time", isOn: Binding(get: { draft.startMinutes != nil }, set: { draft.startMinutes = $0 ? 18 * 60 : nil }))
                        if draft.startMinutes != nil {
                            DatePicker("Time", selection: Binding(get: {
                                let minute = draft.startMinutes ?? 0
                                return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: (draft.targetDay ?? .today).date()) ?? .now
                            }, set: { draft.startMinutes = Calendar.current.component(.hour, from: $0) * 60 + Calendar.current.component(.minute, from: $0) }), displayedComponents: .hourAndMinute)
                        }
                    }
                }.font(.caption)
                if !draft.notes.isEmpty { TextField("Notes", text: $draft.notes, axis: .vertical).font(.caption).foregroundStyle(.secondary).lineLimit(1...3) }
                HStack(spacing: 8) {
                    Picker("Subject", selection: $draft.subjectID) { Text("No subject").tag(UUID?.none); ForEach(store.data.subjects.filter { !$0.archived }) { Text($0.title).tag(UUID?.some($0.id)) } }.labelsHidden().frame(maxWidth: 170)
                    Picker("Project", selection: $draft.projectID) { Text("No project").tag(UUID?.none); ForEach(store.data.projects.filter { $0.status != .archived }) { Text($0.title).tag(UUID?.some($0.id)) } }.labelsHidden().frame(maxWidth: 170)
                    Picker("Priority", selection: $draft.priority) { ForEach(TaskPriority.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 95)
                }.font(.caption)
            }.opacity(draft.isIncluded ? 1 : 0.45)
        }
        .padding(.vertical, 6).contentShape(Rectangle())
    }
}

struct TaskRow: View {
    @EnvironmentObject private var store: AppStore
    let task: TaskItem
    var compact = false
    @State private var isHovering = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                completionButton
                taskDetails.frame(minWidth: 180)
                rowControls
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) { completionButton; taskDetails }
                HStack(spacing: 8) { rowControls; Spacer(minLength: 0) }.padding(.leading, 38)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, compact ? 5 : 8).frame(minHeight: compact ? 44 : 52)
        .background(store.selectedTaskID == task.id ? Color.accentColor.opacity(0.14) : isHovering ? Color.primary.opacity(0.055) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
        .onDrag { NSItemProvider(object: task.id.uuidString as NSString) }
        .contextMenu {
            Button("Show Details", systemImage: "info.circle") { store.selectedTaskID = task.id }
            Button(task.isCompleted ? "Mark Incomplete" : "Complete") { store.toggleTask(task.id) }
            Button("Start Focus…", systemImage: "timer") { store.requestFocus(task.id) }
            Menu("Schedule") {
                Button("Anytime") { store.moveToInbox(task.id) }
                Button("Today, Untimed") { store.unscheduleTime(task.id, day: .today) }
                Button("Tomorrow, Untimed") { store.unscheduleTime(task.id, day: .today.adding(days: 1)) }
            }
            Menu("Due") {
                Button("Today") { store.setDueDay(task.id, day: .today) }
                Button("Tomorrow") { store.setDueDay(task.id, day: .today.adding(days: 1)) }
                Button("Clear Due Date") { store.setDueDay(task.id, day: nil) }.disabled(task.dueDay == nil)
            }
            Menu("Assign Subject") {
                Button("None") { store.setSubject(task.id, subjectID: nil) }
                ForEach(store.data.subjects) { subject in Button(subject.title) { store.setSubject(task.id, subjectID: subject.id) } }
            }
            Menu("Assign Project") {
                Button("None") { store.setProject(task.id, projectID: nil) }
                ForEach(store.data.projects) { project in Button(project.title) { store.setProject(task.id, projectID: project.id) } }
            }
            if task.scheduledStartMinutes != nil { Button("Remove Exact Time") { store.unscheduleTime(task.id) } }
            if task.scheduledDay != nil { Button("Remove from Calendar") { store.moveToInbox(task.id) } }
            Divider(); Button("Duplicate") { store.duplicateTask(task.id) }; Button("Archive") { store.archiveTask(task.id) }; Button("Delete", role: .destructive) { store.deleteTask(task.id) }
        }
    }

    private var completionButton: some View {
            Button { store.toggleTask(task.id) } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(task.isCompleted ? Color.accentColor : .secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain).accessibilityLabel(task.isCompleted ? "Mark \(task.title) incomplete" : "Mark \(task.title) complete")

    }
    private var taskDetails: some View {
            Button { store.selectedTaskID = task.id } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title).font(.body.weight(.medium)).strikethrough(task.isCompleted).foregroundStyle(task.isCompleted ? .secondary : .primary).lineLimit(compact ? 1 : 2)
                    Text(metadata).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("Open task details")

    }
    private var rowControls: some View {
        HStack(spacing: 8) {
            TaskProgressControl(task: task).frame(width: compact ? 95 : 110)

            Menu {
                Button("Today") { store.setDueDay(task.id, day: .today) }
                Button("Tomorrow") { store.setDueDay(task.id, day: .today.adding(days: 1)) }
                Button("Anytime") { store.setDueDay(task.id, day: nil); store.moveToInbox(task.id) }
                Divider()
                Button("Schedule Today, Untimed") { store.unscheduleTime(task.id, day: .today) }
                Button("Schedule Tomorrow, Untimed") { store.unscheduleTime(task.id, day: .today.adding(days: 1)) }
                if task.scheduledDay != nil { Button("Remove from Calendar") { store.moveToInbox(task.id) } }
            } label: { Image(systemName: "calendar").frame(width: 30, height: 30) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).help("Change date or scheduling")

            Button { store.requestFocus(task.id) } label: { Image(systemName: "timer").frame(width: 30, height: 30) }
                .buttonStyle(.plain).help("Start Focus")

            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary).frame(width: 28, height: 30).contentShape(Rectangle())
                .help("Drag onto Calendar")
        }
    }
    private var metadata: String {
        var parts = [String]()
        if let association { parts.append(association) }
        parts.append("\(task.estimatedMinutes) min")
        if let due = task.dueDay { parts.append(due == .today ? "Due today" : "Due \(due.date().formatted(.dateTime.day().month(.abbreviated)))") }
        if task.scheduledDay == .today, task.scheduledStartMinutes == nil { parts.append("Today") }
        if task.priority == .high { parts.append("High priority") }
        return parts.joined(separator: " · ")
    }

    private var association: String? {
        if let id = task.subjectID { return store.data.subjects.first(where: { $0.id == id })?.title }
        if let id = task.projectID { return store.data.projects.first(where: { $0.id == id })?.title }
        return nil
    }
}

private struct TaskProgressControl: View {
    @EnvironmentObject private var store: AppStore
    let task: TaskItem
    @State private var amount = 0.0
    var body: some View {
        VStack(spacing: 0) {
            Slider(value: $amount, in: 0...100, step: 5) { Text("Completion for \(task.title)") } onEditingChanged: { editing in
                if !editing { store.setTaskProgress(task.id, percent: amount) }
            }.labelsHidden()
            Text("\(Int(amount))% done").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
        .onAppear { amount = task.completionPercent ?? (task.isCompleted ? 100 : 0) }
        .onChange(of: task.completionPercent) { _, value in amount = value ?? (task.isCompleted ? 100 : 0) }
    }
}

struct QuietEmptyState: View {
    let title: String; let detail: String; let symbol: String
    var body: some View { ContentUnavailableView { Label(title, systemImage: symbol) } description: { Text(detail) } }
}

struct TaskInspector: View {
    @EnvironmentObject private var store: AppStore
    let taskID: UUID
    @State private var task = TaskItem(title: "")
    @State private var newSubtask = ""
    @FocusState private var checklistEntryFocused: Bool
    @State private var baseline: TaskItem?
    @State private var draftWarning: String?
    @State private var hasDueDate = false
    @State private var hasScheduledDay = false

    var body: some View {
        Form {
            if let draftWarning { Section { Label(draftWarning, systemImage: "exclamationmark.triangle"); Button("Reload Latest Task") { refresh() } } }
            Section("Task") { TextField("Title", text: $task.title); TextEditor(text: $task.notes).frame(minHeight: 80) }
            Section("Completion") {
                HStack {
                    Slider(value: Binding(get: { task.completionPercent ?? (task.isCompleted ? 100 : 0) }, set: { task.completionPercent = $0 }), in: 0...100, step: 5).accessibilityLabel("Task completion").accessibilityValue("\(Int(task.completionPercent ?? 0)) percent")
                    Text("\(Int(task.completionPercent ?? (task.isCompleted ? 100 : 0)))%").monospacedDigit().frame(width: 42)
                }
            }
            Section("Planning") {
                Stepper("Estimated: \(task.estimatedMinutes) min", value: $task.estimatedMinutes, in: 5...480, step: 5)
                Picker("Priority", selection: $task.priority) { ForEach(TaskPriority.allCases) { Text($0.title).tag($0) } }
                Toggle("Due date", isOn: $hasDueDate)
                if hasDueDate { DatePicker("Due", selection: Binding(get: { (task.dueDay ?? .today).date() }, set: { task.dueDay = LocalDay($0) }), displayedComponents: .date) }
                Toggle("Scheduled day", isOn: $hasScheduledDay)
                if hasScheduledDay { DatePicker("Scheduled", selection: Binding(get: { (task.scheduledDay ?? .today).date() }, set: { task.scheduledDay = LocalDay($0) }), displayedComponents: .date) }
                if hasScheduledDay {
                    Toggle("Exact time", isOn: Binding(get: { task.scheduledStartMinutes != nil }, set: { task.scheduledStartMinutes = $0 ? 18 * 60 : nil; task.scheduledDurationMinutes = $0 ? task.estimatedMinutes : nil }))
                    if task.scheduledStartMinutes != nil {
                        DatePicker("Time", selection: Binding(get: {
                            let minute = task.scheduledStartMinutes ?? 0
                            return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: (task.scheduledDay ?? .today).date()) ?? .now
                        }, set: { task.scheduledStartMinutes = Calendar.current.component(.hour, from: $0) * 60 + Calendar.current.component(.minute, from: $0) }), displayedComponents: .hourAndMinute)
                    }
                }
            }
            Section("Checklist") {
                ForEach(Array((task.subtasks ?? []).enumerated()), id: \.element.id) { index, subtask in
                    HStack {
                        Toggle(subtask.title, isOn: Binding(get: { task.subtasks?[index].isCompleted ?? false }, set: { task.subtasks?[index].isCompleted = $0 }))
                        Button("Remove", systemImage: "minus.circle") { task.subtasks?.removeAll { $0.id == subtask.id } }.labelStyle(.iconOnly).accessibilityLabel("Remove \(subtask.title)")
                    }
                }
                TextField("Type a checklist item", text: $newSubtask)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("New checklist item")
                    .focused($checklistEntryFocused)
                    .onSubmit(addSubtask)
                HStack {
                    Button("Add Checklist Item", systemImage: "plus", action: addSubtask)
                    Spacer()
                    Text("Return to add").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Recurrence") {
                Picker("Repeats", selection: Binding(get: { task.recurrence?.frequency ?? "none" }, set: { task.recurrence = $0 == "none" ? nil : TaskRecurrence(frequency: $0, nextDay: task.scheduledDay ?? task.dueDay) })) {
                    Text("Does not repeat").tag("none"); Text("Daily").tag("daily"); Text("Weekly").tag("weekly"); Text("Monthly").tag("monthly")
                }
                if task.recurrence != nil { Stepper("Every \(task.recurrence?.interval ?? 1) intervals", value: Binding(get: { task.recurrence?.interval ?? 1 }, set: { task.recurrence?.interval = $0 }), in: 1...365) }
                Text("Completing this task creates the next occurrence once. Dates and checklist estimates remain editable.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Associations") {
                Picker("Subject", selection: $task.subjectID) { Text("None").tag(UUID?.none); ForEach(store.data.subjects) { Text($0.title).tag(UUID?.some($0.id)) } }
                if let subjectID = task.subjectID, let subject = store.data.subjects.first(where: { $0.id == subjectID }), !subject.topics.isEmpty {
                    Picker("Topic", selection: $task.topicID) { Text("None").tag(UUID?.none); ForEach(subject.topics) { Text($0.title).tag(UUID?.some($0.id)) } }
                }
                Picker("Project", selection: $task.projectID) { Text("None").tag(UUID?.none); ForEach(store.data.projects) { Text($0.title).tag(UUID?.some($0.id)) } }
            }
            Section { Button("Move to Inbox") { store.moveToInbox(taskID); refresh() }; Button("Delete Task", role: .destructive) { store.deleteTask(taskID) } }
        }
        .formStyle(.grouped).navigationTitle("Task Details")
        .onAppear { refresh() }
        .onChange(of: taskID) { _, _ in baseline = nil; newSubtask = ""; checklistEntryFocused = false; refresh() }
        .onChange(of: store.data.tasks.first(where: { $0.id == taskID })) { _, incoming in
            guard let incoming, !incoming.isArchived else { baseline = nil; store.selectedTaskID = nil; return }
            guard let baseline, task != baseline else { refresh(); return }
            do {
                var before = LifeBoardData(); before.tasks = [baseline]
                var after = LifeBoardData(); after.tasks = [task]
                let merged = try LifeBoardDataPatch(before: before, after: after).applying(to: store.data)
                if let current = merged.tasks.first(where: { $0.id == taskID }) { self.baseline = incoming; task = current }
            } catch { draftWarning = "This task changed elsewhere. Review your draft or reload the latest task." }
        }
        .onChange(of: task) { _, edited in
            guard let baseline, edited.id == taskID, edited != baseline else { return }
            if store.updateTask(edited, basedOn: baseline) { refresh() }
            else { draftWarning = "This draft has not been saved. A field is invalid or changed elsewhere." }
        }
        .onChange(of: hasDueDate) { _, value in if !value { task.dueDay = nil } else if task.dueDay == nil { task.dueDay = .today } }
        .onChange(of: hasScheduledDay) { _, value in if !value { task.scheduledDay = nil; task.scheduledStartMinutes = nil; task.scheduledDurationMinutes = nil } else if task.scheduledDay == nil { task.scheduledDay = .today } }
    }

    private func addSubtask() {
        checklistEntryFocused = true
        let title = newSubtask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if task.subtasks == nil { task.subtasks = [] }
        task.subtasks?.append(TaskSubtask(title: title))
        newSubtask = ""
    }

    private func refresh() { guard let current = store.data.tasks.first(where: { $0.id == taskID && !$0.isArchived }) else { baseline = nil; store.selectedTaskID = nil; return }; baseline = current; task = current; draftWarning = nil; hasDueDate = current.dueDay != nil; hasScheduledDay = current.scheduledDay != nil }
}

struct EventInspector: View {
    @EnvironmentObject private var store: AppStore
    let eventID: UUID
    @State private var event = CalendarEvent(title: "", day: .today, startMinutes: 18 * 60, endMinutes: 19 * 60)
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section("Event") {
                TextField("Title", text: $event.title)
                TextField("Location", text: $event.location)
                TextEditor(text: $event.notes).frame(minHeight: 90).accessibilityLabel("Event notes")
            }
            Section("When") {
                DatePicker("Date", selection: Binding(get: { event.day.date() }, set: { event.day = LocalDay($0) }), displayedComponents: .date)
                DatePicker("Start", selection: timeBinding(for: \CalendarEvent.startMinutes), displayedComponents: .hourAndMinute)
                DatePicker("End", selection: timeBinding(for: \CalendarEvent.endMinutes), displayedComponents: .hourAndMinute)
            }
            Section("Association") {
                Picker("Project", selection: $event.projectID) { Text("None").tag(UUID?.none); ForEach(store.data.projects) { Text($0.title).tag(UUID?.some($0.id)) } }
            }
            Section { Button("Duplicate Event") { store.duplicateEvent(eventID) }; Button("Delete Event", role: .destructive) { confirmDelete = true } }
        }
        .formStyle(.grouped).navigationTitle("Event Details")
        .onAppear(perform: refresh).onChange(of: eventID) { _, _ in refresh() }
        .onChange(of: event) { _, edited in
            guard edited.id == eventID, let current = store.data.events.first(where: { $0.id == eventID }), edited != current else { return }
            store.updateEvent(edited)
        }
        .alert("Delete this event?", isPresented: $confirmDelete) { Button("Cancel", role: .cancel) {}; Button("Delete", role: .destructive) { store.deleteEvent(eventID) } } message: { Text("The event will be removed from your calendar.") }
    }

    private func refresh() { if let current = store.data.events.first(where: { $0.id == eventID }) { event = current } }
    private func timeBinding(for keyPath: WritableKeyPath<CalendarEvent, Int>) -> Binding<Date> {
        Binding(get: {
            let minutes = event[keyPath: keyPath]
            return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: event.day.date()) ?? event.day.date()
        }, set: { value in
            let pieces = Calendar.current.dateComponents([.hour, .minute], from: value)
            event[keyPath: keyPath] = (pieces.hour ?? 0) * 60 + (pieces.minute ?? 0)
            if event.endMinutes <= event.startMinutes { event.endMinutes = min(24 * 60 - 1, event.startMinutes + 60) }
        })
    }
}

struct CalendarSlot: Identifiable {
    let id = UUID()
    let day: LocalDay
    let startMinutes: Int
}

struct CalendarSlotCreationView: View {
    enum ItemKind: String, CaseIterable, Identifiable { case task = "Task", event = "Event"; var id: String { rawValue } }
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let slot: CalendarSlot
    @State private var kind = ItemKind.task
    @State private var title = ""
    @State private var duration = 30
    @State private var subjectID: UUID?
    @State private var projectID: UUID?
    @State private var location = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add to Calendar").font(.title2.bold())
            Text("\(slot.day.date().formatted(date: .abbreviated, time: .omitted)) at \(timeString(slot.startMinutes))").foregroundStyle(.secondary)
            Picker("Type", selection: $kind) { ForEach(ItemKind.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            TextField(kind == .task ? "Task title" : "Event title", text: $title).focused($focused).onSubmit(create)
            Stepper("Duration: \(duration) minutes", value: $duration, in: 15...480, step: 15)
            if kind == .task {
                Picker("Subject", selection: $subjectID) { Text("None").tag(UUID?.none); ForEach(store.data.subjects) { Text($0.title).tag(UUID?.some($0.id)) } }
                Picker("Project", selection: $projectID) { Text("None").tag(UUID?.none); ForEach(store.data.projects) { Text($0.title).tag(UUID?.some($0.id)) } }
            } else {
                TextField("Location (optional)", text: $location)
                Picker("Project", selection: $projectID) { Text("None").tag(UUID?.none); ForEach(store.data.projects) { Text($0.title).tag(UUID?.some($0.id)) } }
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Add") { create() }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 460).onAppear { duration = store.data.settings.defaultTaskMinutes; focused = true }
    }

    private func create() {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty else { return }
        switch kind {
        case .task:
            var task = TaskItem(title: clean); task.estimatedMinutes = duration; task.scheduledDay = slot.day; task.scheduledStartMinutes = slot.startMinutes; task.scheduledDurationMinutes = duration; task.subjectID = subjectID; task.projectID = projectID; _ = store.addTask(task)
        case .event:
            var event = CalendarEvent(title: clean, day: slot.day, startMinutes: slot.startMinutes, endMinutes: min(24 * 60 - 1, slot.startMinutes + duration)); event.location = location; event.projectID = projectID; store.addEvent(event)
        }
        dismiss()
    }
}

func timeString(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

extension View {
    func acceptsTaskDrop(_ action: @escaping @MainActor (UUID) -> Void) -> some View {
        onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let raw = value as? String, let id = UUID(uuidString: raw) else { return }
                Task { @MainActor in action(id) }
            }
            return true
        }
    }

    func acceptsCalendarDrop(isTargeted: Binding<Bool>? = nil, task taskAction: @escaping @MainActor (UUID) -> Void, event eventAction: @escaping @MainActor (UUID) -> Void) -> some View {
        onDrop(of: [UTType.plainText], isTargeted: isTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let raw = value as? String else { return }
                if raw.hasPrefix("event:"), let id = UUID(uuidString: String(raw.dropFirst("event:".count))) {
                    Task { @MainActor in eventAction(id) }
                } else if let id = UUID(uuidString: raw) {
                    Task { @MainActor in taskAction(id) }
                }
            }
            return true
        }
    }
}
