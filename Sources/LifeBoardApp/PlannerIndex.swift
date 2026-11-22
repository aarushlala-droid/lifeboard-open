import Foundation
import SwiftUI
import LifeBoardCore

/// Everything a calendar day shows, computed once per data version.
struct DayAgenda {
    var lanes: [CalendarLane] = []
    var untimedTasks: [TaskItem] = []
    var allDay: [ExternalCalendarEvent] = []
    var milestones: [(projectID: UUID, milestone: ProjectMilestone)] = []
    var markers: [YearMarker] = []
    var deadlines: [TaskItem] = []
    var isEmpty: Bool { lanes.isEmpty && untimedTasks.isEmpty && allDay.isEmpty && milestones.isEmpty && markers.isEmpty && deadlines.isEmpty }
}

struct TaskGroup: Identifiable {
    enum Kind { case overdue, today, done, upcoming, anytime }
    let id: String
    let title: String
    let kind: Kind
    var tasks: [TaskItem]
}

/// Derived, read-only lookups. It is rebuilt when the planner changes or the
/// day rolls over; per-day calendar layouts are memoised on first use.
@MainActor final class PlannerIndex {
    let today: LocalDay
    let data: LifeBoardData
    let tasksByID: [UUID: TaskItem]
    let eventsByID: [UUID: CalendarEvent]
    let externalByID: [String: ExternalCalendarEvent]
    let subjectsByID: [UUID: LifeBoardCore.Subject]
    let projectsByID: [UUID: Project]
    let activeTasks: [TaskItem]
    private let scheduledByDay: [LocalDay: [TaskItem]]
    private let eventsByDay: [LocalDay: [CalendarEvent]]
    private let externalByDay: [LocalDay: [ExternalCalendarEvent]]
    private var agendaCache: [LocalDay: DayAgenda] = [:]

    init(data: LifeBoardData, today: LocalDay = .today, calendar: Calendar = .current) {
        self.today = today
        self.data = data
        tasksByID = Dictionary(data.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        eventsByID = Dictionary(data.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        externalByID = Dictionary(data.externalEvents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        subjectsByID = Dictionary(data.subjects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        projectsByID = Dictionary(data.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        activeTasks = data.tasks.filter { !$0.isCompleted && !$0.isArchived }
        var scheduled: [LocalDay: [TaskItem]] = [:]
        for task in data.tasks where !task.isArchived { if let day = task.scheduledDay { scheduled[day, default: []].append(task) } }
        scheduledByDay = scheduled
        eventsByDay = Dictionary(grouping: data.events, by: \.day)
        var external: [LocalDay: [ExternalCalendarEvent]] = [:]
        for event in data.externalEvents {
            if let start = event.startInstant, let end = event.endInstant, end > start {
                // Bucket by every local day the instant range touches; the
                // exact clipping is done by SchedulingEngine for each day.
                var day = LocalDay(start, calendar: calendar)
                let last = LocalDay(end.addingTimeInterval(-1), calendar: calendar)
                var guardCount = 0
                while day <= last && guardCount < 400 { external[day, default: []].append(event); day = day.adding(days: 1, calendar: calendar); guardCount += 1 }
            } else {
                external[event.day, default: []].append(event)
            }
        }
        externalByDay = external
    }

    func agenda(for day: LocalDay) -> DayAgenda {
        if let cached = agendaCache[day] { return cached }
        var agenda = DayAgenda()
        let candidates = (scheduledByDay[day] ?? []) + (scheduledByDay[day.adding(days: -1)] ?? [])
        let taskIntervals = candidates.compactMap { SchedulingEngine.taskSegment($0, on: day) }
        let eventIntervals = (eventsByDay[day] ?? []).map { BusyInterval(id: $0.id.uuidString, start: $0.startMinutes, end: $0.endMinutes) }
        let externals = externalByDay[day] ?? []
        var externalIntervals: [BusyInterval] = []
        for event in externals {
            guard let segment = SchedulingEngine.externalSegment(event, on: day) else { continue }
            if event.isAllDay { agenda.allDay.append(event) } else { externalIntervals.append(segment) }
        }
        agenda.lanes = SchedulingEngine.lanes(taskIntervals + eventIntervals + externalIntervals)
        agenda.untimedTasks = (scheduledByDay[day] ?? []).filter { !$0.isCompleted && $0.scheduledStartMinutes == nil }
        agenda.deadlines = activeTasks.filter { $0.dueDay == day }
        agenda.markers = data.yearMarkers.filter { marker in marker.startDay == day || (marker.endDay.map { marker.startDay <= day && day <= $0 } ?? false) }
        agenda.milestones = data.projects.flatMap { project in project.milestones.filter { !$0.isCompleted && $0.targetDay == day }.map { (project.id, $0) } }
        agendaCache[day] = agenda
        return agenda
    }

    /// Busy intervals for the scheduling engine, derived from the same buckets.
    func timedItemCount(on day: LocalDay) -> Int { agenda(for: day).lanes.count }

    // MARK: Task groups

    /// Today is the hub: it lists every active To Do, with today's work first,
    /// then undated (Anytime) and later dated work, then what was done today.
    /// `lingering` tasks were completed moments ago; they stay where they were
    /// for a beat so a click never makes a row jump away unexpectedly.
    func todayGroups(lingering: Set<UUID>, search: String) -> [TaskGroup] {
        let pool = candidates(lingering: lingering, search: search)
        var overdue: [TaskItem] = [], todays: [TaskItem] = [], anytime: [TaskItem] = [], upcoming: [TaskItem] = []
        for (task, view) in pool {
            let c = TaskClassification(view, day: today)
            if c.carryOver || c.overdue { overdue.append(task) }
            else if c.today { todays.append(task) }
            else if c.anytime { anytime.append(task) }
            else { upcoming.append(task) }
        }
        let done = data.tasks.filter { task in
            task.isCompleted && !task.isArchived && !lingering.contains(task.id) && matches(task, search)
                && task.completedAt.map { LocalDay($0) == today } == true
        }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        return [
            TaskGroup(id: "overdue", title: "Overdue", kind: .overdue, tasks: overdue.sorted(by: Self.order)),
            TaskGroup(id: "today", title: "Today", kind: .today, tasks: todays.sorted(by: Self.order)),
            TaskGroup(id: "anytime", title: "Anytime", kind: .anytime, tasks: anytime.sorted(by: Self.order)),
            TaskGroup(id: "upcoming", title: "Upcoming", kind: .upcoming, tasks: upcoming.sorted(by: Self.byDate)),
            TaskGroup(id: "done", title: "Done today", kind: .done, tasks: done)
        ]
    }

    func allGroups(lingering: Set<UUID>, search: String) -> [TaskGroup] {
        let pool = candidates(lingering: lingering, search: search)
        var overdue: [TaskItem] = [], todays: [TaskItem] = [], upcoming: [TaskItem] = [], anytime: [TaskItem] = []
        for (task, view) in pool {
            let c = TaskClassification(view, day: today)
            if c.carryOver || c.overdue { overdue.append(task) }
            else if c.today { todays.append(task) }
            else if c.tomorrow || c.upcoming { upcoming.append(task) }
            else if c.anytime { anytime.append(task) }
        }
        return [
            TaskGroup(id: "overdue", title: "Overdue", kind: .overdue, tasks: overdue.sorted(by: Self.order)),
            TaskGroup(id: "today", title: "Today", kind: .today, tasks: todays.sorted(by: Self.order)),
            TaskGroup(id: "upcoming", title: "Upcoming", kind: .upcoming, tasks: upcoming.sorted(by: Self.byDate)),
            TaskGroup(id: "anytime", title: "Anytime", kind: .anytime, tasks: anytime.sorted(by: Self.order))
        ]
    }

    func overdueCount() -> Int { activeTasks.filter { let c = TaskClassification($0, day: today); return c.carryOver || c.overdue }.count }
    func todayCount() -> Int { activeTasks.filter { TaskClassification($0, day: today).today }.count }

    func association(for task: TaskItem) -> (title: String, colour: Color)? {
        if let id = task.subjectID, let subject = subjectsByID[id] { return (subject.title, LB.subjectColour(subject.colour)) }
        if let id = task.projectID, let project = projectsByID[id] { return (project.title, LB.subjectColour(project.colour)) }
        return nil
    }

    private func candidates(lingering: Set<UUID>, search: String) -> [(TaskItem, TaskItem)] {
        data.tasks.compactMap { task in
            guard !task.isArchived, matches(task, search) else { return nil }
            if !task.isCompleted { return (task, task) }
            guard lingering.contains(task.id) else { return nil }
            var view = task; view.isCompleted = false
            return (task, view)
        }
    }

    private func matches(_ task: TaskItem, _ search: String) -> Bool {
        search.isEmpty || task.title.localizedCaseInsensitiveContains(search) || task.notes.localizedCaseInsensitiveContains(search)
    }

    static func planningDay(_ task: TaskItem) -> LocalDay? {
        switch (task.scheduledDay, task.dueDay) {
        case let (scheduled?, due?): min(scheduled, due)
        case let (scheduled?, nil): scheduled
        case let (nil, due?): due
        default: nil
        }
    }

    private static func rank(_ priority: TaskPriority) -> Int { switch priority { case .high: 3; case .medium: 2; case .low: 1; case .none: 0 } }
    /// The original LifeBoard order: priority first, then the nearest date.
    static func order(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        if lhs.priority != rhs.priority { return rank(lhs.priority) > rank(rhs.priority) }
        let far = LocalDay(year: 9999, month: 12, day: 31)
        let l = lhs.dueDay ?? lhs.scheduledDay ?? far, r = rhs.dueDay ?? rhs.scheduledDay ?? far
        if l != r { return l < r }
        if lhs.scheduledStartMinutes != rhs.scheduledStartMinutes { return (lhs.scheduledStartMinutes ?? 9999) < (rhs.scheduledStartMinutes ?? 9999) }
        return lhs.createdAt < rhs.createdAt
    }
    static func byDate(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        let far = LocalDay(year: 9999, month: 12, day: 31)
        let l = planningDay(lhs) ?? far, r = planningDay(rhs) ?? far
        return l == r ? order(lhs, rhs) : l < r
    }
}

// MARK: - Inline entry

enum NewTaskContext: Equatable {
    case none, today, day(LocalDay)
    var day: LocalDay? { switch self { case .none: nil; case .today: .today; case .day(let day): day } }
}

struct QuickEntryPlan {
    var chips: [String] = []
    var problem: String?
    var task: TaskItem?
    var event: CalendarEvent?
}

/// Turns one parsed line into exactly what will be saved. Pure, so it is
/// covered by tests: a typed date is a due date (as in Capture); no date means
/// the day in view, if any, unless the text says "anytime"; a time uses that
/// same day; events cannot cross midnight; anything the parser flags for
/// review must be clarified first.
enum QuickEntryPlanner {
    @MainActor static func plan(_ draft: CapturedTaskDraft, context: NewTaskContext, index: PlannerIndex) -> QuickEntryPlan {
        var plan = QuickEntryPlan()
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { plan.problem = "Add a title"; return plan }
        let start = draft.startMinutes
        // Without a typed date, a new To Do is for the day in view (Today or a
        // calendar day); in To Do, or when the text says "anytime", it stays undated.
        let defaultDay: LocalDay? = draft.isAnytime ? nil : context.day
        var day = draft.targetDay
        if start != nil && day == nil { day = defaultDay }
        let timeResolvedByContext = draft.startMinutes != nil && draft.targetDay == nil && day != nil
        if draft.needsReview && !timeResolvedByContext {
            plan.problem = draft.reviewReason ?? "Check the date or time"; return plan
        }
        if draft.kind == .event, let startMinutes = start, let eventDay = day {
            guard startMinutes + draft.estimatedMinutes <= 1440 else { plan.problem = "Events can't cross midnight"; return plan }
            var event = CalendarEvent(title: title, day: eventDay, startMinutes: startMinutes, endMinutes: startMinutes + draft.estimatedMinutes)
            event.projectID = draft.projectID
            plan.event = event
            plan.chips = ["Event", relativeDayText(eventDay, today: index.today), "\(timeString(startMinutes))–\(timeString(event.endMinutes % 1440))"]
            return plan
        }
        var task = TaskItem(title: title)
        task.estimatedMinutes = draft.estimatedMinutes
        task.priority = draft.priority
        task.subjectID = draft.subjectID
        task.projectID = draft.projectID
        if let startMinutes = start, let plannedDay = day {
            task.scheduledDay = plannedDay; task.scheduledStartMinutes = startMinutes; task.scheduledDurationMinutes = draft.estimatedMinutes
            plan.chips.append("\(relativeDayText(plannedDay, today: index.today)) \(timeString(startMinutes))")
        } else if let due = draft.targetDay {
            task.dueDay = due
            plan.chips.append("Due \(relativeDayText(due, today: index.today))")
        } else if let planned = defaultDay {
            task.scheduledDay = planned
            plan.chips.append(relativeDayText(planned, today: index.today))
        } else {
            plan.chips.append("Anytime")
        }
        plan.chips.append(durationText(task.estimatedMinutes))
        if let id = task.subjectID, let subject = index.subjectsByID[id] { plan.chips.append(subject.title) }
        if let id = task.projectID, let project = index.projectsByID[id] { plan.chips.append(project.title) }
        if task.priority == .high { plan.chips.append("High priority") }
        plan.task = task
        return plan
    }
}
