import SwiftUI
import LifeBoardCore

enum AppSection: String, CaseIterable, Identifiable {
    // Raw values are stored in preferences and used by deep links; keep them.
    case today, inbox, calendar, focus, subjects, projects, year, completed, settings, help
    var id: String { rawValue }
    var title: String {
        switch self {
        case .inbox: "To Do"; case .year: "Important Dates"
        default: rawValue.capitalized
        }
    }
    var icon: String {
        switch self {
        case .today: "sun.max"; case .inbox: "checklist"; case .calendar: "calendar"
        case .focus: "timer"; case .subjects: "books.vertical"; case .projects: "folder"; case .year: "flag"
        case .completed: "checkmark.circle"; case .settings: "gearshape"; case .help: "questionmark.circle"
        }
    }
    /// Command-1 to Command-8 keep their original meaning.
    var shortcut: Character? {
        switch self {
        case .today: "1"; case .inbox: "2"; case .calendar: "3"; case .focus: "4"; case .subjects: "5"
        case .projects: "6"; case .year: "7"; case .completed: "8"; default: nil
        }
    }
    static let navigable: [AppSection] = [.today, .inbox, .calendar, .focus, .subjects, .projects, .year, .completed]
}

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selected: AppSection
    @Binding var showCapture: Bool
    @AppStorage("showInspector") private var showInspector = true
    @State private var searchText = ""
    @State private var creationKind: CreationKind?

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { selected }, set: { value in
                // Choosing another section starts fresh, as before: details
                // for a task on a different screen would be confusing.
                guard let value, value != selected else { return }
                selected = value; store.selectedTaskID = nil; store.selectedEventID = nil
            })) {
                Section {
                    row(.today, badge: store.index.todayCount())
                    row(.inbox, badge: store.index.activeTasks.count)
                }
                Section("Plan") { row(.calendar); row(.focus) }
                Section("Big Picture") { row(.subjects); row(.projects); row(.year) }
                Section { row(.completed) }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                if LifeBoardEnvironment.isPreview {
                    Label("Preview: separate data, sync off", systemImage: "testtube.2").font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                        .help("LifeBoard Preview keeps its own planner and never writes to your installed LifeBoard or its mobile sync.")
                }
            }
        } detail: {
            // Details appear for a selection (as before) unless hidden with
            // Option-Command-I, and an empty panel never takes up room. This is a
            // plain side panel, not the .inspector modifier: that one lays the
            // detail out with AppKit constraints, and any screen taller than the
            // window then loops until AppKit aborts the app.
            HStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showInspector && hasSelection {
                    Divider()
                    inspector
                        .frame(width: 340)
                        .frame(maxHeight: .infinity)
                        .background(.background)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(Motion.move(reduceMotion), value: showInspector && hasSelection)
            .modifier(HideToolbarTitle())
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { newToDo() } label: { Label("New To Do", systemImage: "plus") }
                            .help("New To Do (Shift-Command-N)")
                        Button { showCapture = true } label: { Label("Capture", systemImage: "square.and.pencil") }
                            .help("Capture a list or an image (Command-N)")
                        Menu {
                            Button("Event…", systemImage: "calendar.badge.plus") { creationKind = .event }
                            Button("Project…", systemImage: "folder.badge.plus") { creationKind = .project }
                            Button("Subject…", systemImage: "book.closed") { creationKind = .subject }
                            Button("Milestone…", systemImage: "diamond") { creationKind = .milestone }
                            Button("Important Date…", systemImage: "flag") { creationKind = .yearMarker }
                        } label: { Label("New", systemImage: "ellipsis.circle") }
                            .help("Create an event or a Big Picture item")
                        Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                            .help(showInspector ? "Hide details (Option-Command-I)" : "Show details (Option-Command-I)")
                    }
                }
        }
        .sheet(item: $creationKind) { kind in ItemCreationView(kind: kind).environmentObject(store) }
        .sheet(item: Binding(get: { store.rescheduleRequest.map(IdentifiedID.init) }, set: { store.rescheduleRequest = $0?.id })) { item in
            RescheduleSheet(taskID: item.id).environmentObject(store)
        }
        .sheet(isPresented: Binding(get: { store.focusRequestTaskID != nil }, set: { if !$0 { store.focusRequestTaskID = nil } })) {
            if let taskID = store.focusRequestTaskID { FocusStartView(taskID: taskID).environmentObject(store) }
        }
        .sheet(item: $store.focusCompletion) { completion in FocusCompletionView(completion: completion).environmentObject(store) }
        .safeAreaInset(edge: .bottom, spacing: 0) { ActiveFocusBar().environmentObject(store) }
        .onChange(of: store.requestedSectionRaw) { _, raw in
            if let raw, let section = AppSection(rawValue: raw) {
                if section == .settings { openSettingsFallback() } else { selected = section }
                store.requestedSectionRaw = nil
            }
        }
        .onChange(of: store.newTaskFocusRequest) { _, _ in newToDo() }
        .onChange(of: store.selectedTaskID) { _, value in if value != nil, store.revealInspectorOnSelect { showInspector = true; store.revealInspectorOnSelect = false } }
        .onAppear { store.undoManager = undoManager; undoManager?.levelsOfUndo = 200 }
    }

    private func row(_ section: AppSection, badge: Int = 0) -> some View {
        Label(section.title, systemImage: section.icon)
            .badge(badge)
            .tag(section)
            .calendarDropIfDay(section)
    }

    @State private var entryFocus = 0

    private var hasSelection: Bool {
        (store.selectedTaskID.map { store.index.tasksByID[$0] != nil } ?? false) || (store.selectedEventID.map { store.index.eventsByID[$0] != nil } ?? false)
    }

    @ViewBuilder private var detail: some View {
        let open = { showInspector = true; store.inspectorFocusPending = true; store.inspectorFocusRequest += 1 }
        let reschedule: (UUID) -> Void = { store.rescheduleRequest = $0 }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            SearchResultsView(query: searchText, selectedSection: $selected)
        } else {
            switch selected {
            case .today: TodayView(searchText: "", focusEntry: $entryFocus, openDetails: open, onReschedule: reschedule)
            case .inbox: ToDoView(searchText: "", focusEntry: $entryFocus, openDetails: open, onReschedule: reschedule)
            case .calendar: CalendarView()
            case .focus: FocusDashboardView()
            case .subjects: SubjectsView(searchText: "")
            case .projects: ProjectsView(searchText: "")
            case .year: YearView()
            case .completed: CompletedView(searchText: "")
            case .settings: SettingsView()
            case .help: HelpView()
            }
        }
    }

    @ViewBuilder private var inspector: some View {
        if let id = store.selectedTaskID, store.index.tasksByID[id] != nil { TaskInspector(taskID: id).id(id) }
        else if let id = store.selectedEventID, store.index.eventsByID[id] != nil { EventInspector(eventID: id).id(id) }
        else {
            ContentUnavailableView {
                Label("No Selection", systemImage: "sidebar.trailing")
            } description: {
                Text("Select a To Do or an event to see and edit its details.")
            }
        }
    }

    /// Focus the inline field where there is one; otherwise open the form.
    private func newToDo() {
        switch selected {
        case .today, .inbox: entryFocus += 1
        default: creationKind = .task
        }
    }

    private func openSettingsFallback() { selected = .settings }
}

struct IdentifiedID: Identifiable { let id: UUID }

/// Each screen shows its own large title, so the toolbar title is redundant
/// where the system allows removing it (macOS 15 and later).
private struct HideToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.toolbar(removing: .title) } else { content }
    }
}

private extension View {
    /// Dropping a task on Today in the sidebar plans it for today.
    @ViewBuilder func calendarDropIfDay(_ section: AppSection) -> some View {
        if section == .today { self.calendarDrop(day: .today, destination: .untimed) } else { self }
    }
}
