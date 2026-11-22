import AppKit
import SwiftUI
import LifeBoardCore

/// What is happening now or next today, in the lamp colour.
struct NowNextStrip: View {
    @EnvironmentObject private var store: AppStore
    private struct Item { let title: String; let start: Int; let end: Int; let open: () -> Void }

    private func next(after minute: Int) -> Item? {
        let index = store.index
        let agenda = index.agenda(for: index.today)
        return agenda.lanes.compactMap { lane -> Item? in
            guard lane.end > minute else { return nil }
            if let id = UUID(uuidString: lane.id), let task = index.tasksByID[id] { return Item(title: task.title, start: lane.start, end: lane.end) { store.selectedTaskID = task.id } }
            if let id = UUID(uuidString: lane.id), let event = index.eventsByID[id] { return Item(title: event.title, start: lane.start, end: lane.end) { store.selectedEventID = event.id } }
            if let event = index.externalByID[lane.id] { return Item(title: event.title, start: lane.start, end: lane.end) { store.requestedSectionRaw = AppSection.calendar.rawValue } }
            return nil
        }.min { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let minute = CalendarViewport.currentMinute(now: context.date)
            if let item = next(after: minute) {
                let running = item.start <= minute
                Button(action: item.open) {
                    HStack(spacing: 9) {
                        LampDot(size: 7)
                        Text(running ? "Now" : "Next").font(.callout.weight(.semibold)).foregroundStyle(LB.lampText)
                        Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(running ? "until \(timeString(item.end % 1440))" : "\(timeString(item.start)), in \(durationText(item.start - minute))")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(running ? "Now: \(item.title), until \(timeString(item.end % 1440))" : "Next: \(item.title) at \(timeString(item.start))")
            } else {
                Label("Nothing else scheduled today", systemImage: "moon.stars").font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }
}

struct TodayView: View {
    @EnvironmentObject private var store: AppStore
    let searchText: String
    @Binding var focusEntry: Int
    var openDetails: () -> Void
    var onReschedule: (UUID) -> Void
    @State private var planning = false
    @State private var showCarryOver = false
    @State private var showRevision = false
    @State private var nowRequest = UUID()
    @AppStorage("todayCompactPane") private var compactPane = "To Do"

    private var nextImportantDate: YearMarker? {
        store.data.yearMarkers.filter { $0.startDay >= store.index.today }.min { $0.startDay < $1.startDay }
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width > 700
            VStack(spacing: 0) {
                header.padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 12)
                Divider()
                if wide {
                    // A plain stack (not HSplitView) so the inspector can always
                    // take its column; NSSplitView refuses to give space back.
                    HStack(spacing: 0) {
                        taskPane.frame(maxWidth: .infinity)
                        Divider()
                        DayTimeline(day: store.index.today, nowRequest: nowRequest, scrollContext: "today", showsUntimedTasks: false)
                            .frame(width: min(440, max(260, proxy.size.width * 0.4)))
                    }
                } else {
                    Picker("Show", selection: $compactPane) { Text("To Do").tag("To Do"); Text("Schedule").tag("Schedule") }
                        .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 18).padding(.vertical, 8)
                    if compactPane == "To Do" { taskPane } else { DayTimeline(day: store.index.today, nowRequest: nowRequest, scrollContext: "today", showsUntimedTasks: false) }
                }
            }
        }
        .sheet(isPresented: $showCarryOver) { CarryOverReviewView().environmentObject(store) }
        .sheet(isPresented: $showRevision) { RevisionOverviewView().environmentObject(store) }
        .sheet(isPresented: $planning) { EveningPlanView().environmentObject(store) }
        .onChange(of: store.temporalRevision) { _, _ in nowRequest = UUID() }
        .navigationTitle("Today")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Today").font(.system(size: 24, weight: .bold)).accessibilityAddTraits(.isHeader)
                    Text(store.index.today.date().formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Review Missed Plans…") { showCarryOver = true }
                    Button("Revision Overview…") { showRevision = true }
                } label: { Label("Review", systemImage: "list.bullet.clipboard") }
                    .menuStyle(.borderlessButton).fixedSize().help("Review missed plans or revision")
                Button { planning = true } label: { Label("Plan Evening", systemImage: "wand.and.stars") }
                    .help("Suggest times for unscheduled To Dos this evening. Nothing changes until you accept.")
            }
            NowNextStrip()
            if let marker = nextImportantDate {
                Button { store.requestedSectionRaw = AppSection.year.rawValue } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "flag.fill").foregroundStyle(LB.marker)
                        Text(marker.title).lineLimit(1)
                        Text(relativeDayText(marker.startDay, today: store.index.today)).foregroundStyle(.secondary)
                    }
                    .font(.caption).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Open Important Dates")
            }
        }
    }

    private var taskPane: some View {
        let groups = store.index.todayGroups(lingering: store.lingeringCompletions, search: searchText)
        return TaskListView(groups: groups, entry: .today, showsDay: true,
                            emptyTitle: "You're all clear",
                            emptyDetail: "Add something above, or press Command-N to capture several at once.",
                            focusEntry: $focusEntry, openDetails: openDetails, onReschedule: onReschedule)
    }
}

struct ToDoView: View {
    @EnvironmentObject private var store: AppStore
    let searchText: String
    @Binding var focusEntry: Int
    var openDetails: () -> Void
    var onReschedule: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScreenTitle(title: "To Do", subtitle: "Everything active, with or without a date.").padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 10)
            Divider()
            TaskListView(groups: store.index.allGroups(lingering: store.lingeringCompletions, search: searchText), entry: NewTaskContext.none,
                         emptyTitle: "You're clear", emptyDetail: "Capture anything on your mind. Scheduling can wait.",
                         focusEntry: $focusEntry, openDetails: openDetails, onReschedule: onReschedule)
        }
        .navigationTitle("To Do")
    }
}

/// Choose a planned day and optional exact time for one task.
struct RescheduleSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID
    @State private var day = Date.now
    @State private var timed = false
    @State private var time = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose Date").font(.title3.weight(.semibold))
            if let task = store.index.tasksByID[taskID] { Text(task.title).foregroundStyle(.secondary).lineLimit(2) }
            DatePicker("Day", selection: $day, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
            Toggle("At an exact time", isOn: $timed)
            if timed { DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute) }
            HStack {
                Button("Anytime (No Date)") { store.setWhen(taskID, day: nil); dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 340)
        .onAppear {
            guard let task = store.index.tasksByID[taskID] else { return }
            day = (task.scheduledDay ?? task.dueDay ?? store.index.today).date()
            if let start = task.scheduledStartMinutes {
                timed = true
                time = Calendar.current.date(bySettingHour: start / 60, minute: start % 60, second: 0, of: day) ?? day
            } else {
                time = Calendar.current.date(bySettingHour: store.data.settings.eveningStartMinutes / 60, minute: store.data.settings.eveningStartMinutes % 60, second: 0, of: day) ?? day
            }
        }
    }

    private func save() {
        let target = LocalDay(day)
        if timed {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
            store.moveScheduledTask(taskID, day: target, startMinutes: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        } else {
            store.unscheduleTime(taskID, day: target)
        }
        dismiss()
    }
}
