import SwiftUI
import UniformTypeIdentifiers
import LifeBoardCore

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

struct QuickAddView: View {
    enum ImportMode: String, CaseIterable, Identifiable { case todo = "Add to To Do", schedule = "Suggest Schedule"; var id: String { rawValue } }

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var drafts: [CapturedTaskDraft] = []
    @State private var mode: ImportMode
    @State private var isInterpreting = false
    @State private var interpretationTask: Task<Void, Never>?
    @State private var liveParse: Task<Void, Never>?
    @AppStorage("captureUsesAppleIntelligence") private var usesAppleIntelligence = true
    @State private var note = ""
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
                    Toggle("Use on-device Apple Intelligence", isOn: $usesAppleIntelligence)
                        .toggleStyle(.switch).controlSize(.small).disabled(isInterpreting)
                    Text(note).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        interpret()
                    } label: {
                        if isInterpreting { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                        else { Label(usesAppleIntelligence ? "Refine Titles with Apple Intelligence" : "Interpret Again", systemImage: "sparkles").frame(maxWidth: .infinity) }
                    }
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [.command, .option])
                    .help("The preview updates as you type using the on-device parser. Refining also checks titles with Apple Intelligence when it is available.")
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
                            .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                            .help("Add the selected items (Command-Return)")
                            .disabled(drafts.allSatisfy { !$0.isIncluded } || isInterpreting)
                    }
                }
                .padding(20).frame(minWidth: 480, idealWidth: 580)
            }
        }
        .frame(minWidth: 900, minHeight: 590)
        .onAppear { inputFocused = true; updateEngineNote() }
        .onChange(of: usesAppleIntelligence) { _, _ in if drafts.isEmpty { updateEngineNote() } }
        .onDisappear { interpretationTask?.cancel(); interpretationTask = nil; liveParse?.cancel() }
        .onChange(of: mode) { _, value in if value == .schedule { drafts = NaturalLanguageTaskParser.suggestedSchedule(for: drafts, data: store.data) } }
        .onChange(of: input) { _, value in scheduleLivePreview(value) }
    }

    /// Text previews update as you type with the fast on-device parser, so a
    /// single line needs no extra step: type, check the preview, Command-Return.
    private func scheduleLivePreview(_ value: String) {
        liveParse?.cancel()
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { if imageName == nil { drafts = [] }; return }
        liveParse = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, !isInterpreting else { return }
            var interpreted = NaturalLanguageTaskParser.parse(text, data: store.data)
            if let initialDay {
                for index in interpreted.indices where interpreted[index].targetDay == nil { interpreted[index].targetDay = initialDay }
                if interpreted.count == 1, interpreted[0].startMinutes == nil { interpreted[0].startMinutes = initialStartMinutes }
            }
            imageName = nil
            drafts = mode == .schedule ? NaturalLanguageTaskParser.suggestedSchedule(for: interpreted, data: store.data) : interpreted
            note = "Preview from the on-device parser. Check it, then press Command-Return."
        }
    }

    private func updateEngineNote() {
        note = CaptureIntelligence.availabilityDescription(useAppleIntelligence: usesAppleIntelligence)
    }

    private func interpret() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        imageName = nil
        preparePreview { data, useAI in
            await CaptureIntelligence.interpret(text: text, data: data, useAppleIntelligence: useAI)
        }
    }

    private func preparePreview(_ operation: @escaping @MainActor (LifeBoardData, Bool) async throws -> CaptureInterpretation) {
        interpretationTask?.cancel()
        isInterpreting = true
        errorText = nil
        drafts = []
        let data = store.data
        let useAI = usesAppleIntelligence
        note = "Preparing your preview…"
        interpretationTask = Task {
            do {
                let result = try await operation(data, useAI)
                guard !Task.isCancelled else { return }
                var interpreted = result.drafts
                if let initialDay {
                    for index in interpreted.indices where interpreted[index].targetDay == nil {
                        interpreted[index].targetDay = initialDay
                    }
                    if interpreted.count == 1, interpreted[0].startMinutes == nil {
                        interpreted[0].startMinutes = initialStartMinutes
                    }
                }
                drafts = mode == .schedule ? NaturalLanguageTaskParser.suggestedSchedule(for: interpreted, data: store.data) : interpreted
                note = result.note
            } catch {
                guard !Task.isCancelled else { return }
                errorText = error.localizedDescription
                updateEngineNote()
            }
            isInterpreting = false
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
        imageName = url.lastPathComponent
        preparePreview { data, useAI in
            try await CaptureIntelligence.interpretImage(at: url, data: data, useAppleIntelligence: useAI)
        }
    }

    private func process(image: NSImage, name: String) {
        imageName = name
        preparePreview { data, useAI in
            try await CaptureIntelligence.interpretImage(in: image, data: data, useAppleIntelligence: useAI)
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

struct QuietEmptyState: View {
    let title: String; let detail: String; let symbol: String
    var body: some View { ContentUnavailableView { Label(title, systemImage: symbol) } description: { Text(detail) } }
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
            var event = CalendarEvent(title: clean, day: slot.day, startMinutes: slot.startMinutes, endMinutes: min(1440, slot.startMinutes + duration)); event.location = location; event.projectID = projectID; store.addEvent(event)
        }
        dismiss()
    }
}


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
}
