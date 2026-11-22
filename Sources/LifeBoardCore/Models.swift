import Foundation

public struct LocalDay: Codable, Hashable, Comparable, Sendable, Identifiable {
    public var year: Int
    public var month: Int
    public var day: Int
    public var id: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public init(year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    public init?(iso: String) {
        let pieces = iso.split(separator: "-").compactMap { Int($0) }
        guard iso.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil, pieces.count == 3 else { return nil }
        self.init(year: pieces[0], month: pieces[1], day: pieces[2])
        guard isValid else { return nil }
    }

    public var isValid: Bool {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else { return false }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return parts.year == year && parts.month == month && parts.day == day
    }

    public static var today: LocalDay { LocalDay(Date()) }
    public static func < (lhs: LocalDay, rhs: LocalDay) -> Bool { lhs.id < rhs.id }

    public func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .now
    }

    public func adding(days: Int, calendar: Calendar = .current) -> LocalDay {
        LocalDay(calendar.date(byAdding: .day, value: days, to: date(calendar: calendar)) ?? date(calendar: calendar), calendar: calendar)
    }
}

public enum TaskPriority: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, low, medium, high
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum ProjectStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case notStarted, active, paused, complete, archived
    public var id: String { rawValue }
    public var title: String {
        switch self { case .notStarted: "Not Started"; case .active: "Active"; case .paused: "Paused"; case .complete: "Complete"; case .archived: "Archived" }
    }
}

public struct MetricRecord: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var date = Date()
    public var value: Double
    public init(value: Double, date: Date = .now) { self.value = value; self.date = date }
}

public struct Topic: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var title: String
    public var confidence: Double = 3
    public var progress: Double = 0
    public var notes: String = ""
    public var lastActivity: Date?
    public init(title: String) { self.title = title }
}

public struct Subject: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var title: String
    public var confidence: Double = 3
    public var progress: Double = 0
    public var notes: String = ""
    public var colour: String = "blue"
    public var archived = false
    public var lastActivity: Date?
    public var topics: [Topic] = []
    public var confidenceHistory: [MetricRecord] = []
    public init(title: String) { self.title = title }
}

public struct ProjectMilestone: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var title: String
    public var targetDay: LocalDay
    public var isCompleted = false
    public var notes = ""
    public init(title: String, targetDay: LocalDay) { self.title = title; self.targetDay = targetDay }
}

public struct ProgressUpdate: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var date = Date()
    public var text: String
    public var confidenceChange: Double?
    public var progressChange: Double?
    public init(text: String, date: Date = .now, confidenceChange: Double? = nil, progressChange: Double? = nil) {
        self.text = text; self.date = date; self.confidenceChange = confidenceChange; self.progressChange = progressChange
    }
}

public struct Project: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var title: String
    public var status: ProjectStatus = .active
    public var progress: Double = 0
    public var health: Double = 3
    public var summary = ""
    public var notes = ""
    public var startDay: LocalDay?
    public var targetDay: LocalDay?
    public var colour = "indigo"
    public var milestones: [ProjectMilestone] = []
    public var updates: [ProgressUpdate] = []
    public var progressHistory: [MetricRecord] = []
    public var lastActivity: Date?
    public var progressMode: String?
    public init(title: String) { self.title = title }
}

public struct TaskSubtask: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var title: String
    public var isCompleted = false
    public init(title: String) { self.title = title }
}

public struct TaskRecurrence: Codable, Hashable, Sendable {
    public var frequency: String
    public var interval: Int
    public var nextDay: LocalDay?
    public init(frequency: String, interval: Int = 1, nextDay: LocalDay? = nil) { self.frequency = frequency; self.interval = interval; self.nextDay = nextDay }
}

public struct TaskItem: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var title: String
    public var notes = ""
    public var createdAt = Date()
    public var modifiedAt = Date()
    public var isCompleted = false
    public var completedAt: Date?
    public var completionPercent: Double?
    public var estimatedMinutes = 30
    public var actualMinutes: Int?
    public var priority: TaskPriority = .none
    public var dueDay: LocalDay?
    public var scheduledDay: LocalDay?
    public var scheduledStartMinutes: Int?
    public var scheduledDurationMinutes: Int?
    public var subjectID: UUID?
    public var topicID: UUID?
    public var projectID: UUID?
    public var milestoneID: UUID?
    public var tags: [String] = []
    public var sortOrder: Double = 0
    public var isArchived = false
    public var archivedAt: Date?
    public var recurrenceSeriesID: UUID?
    public var subtasks: [TaskSubtask]?
    public var recurrence: TaskRecurrence?
    public init(title: String) { self.title = title }
}

public struct CalendarEvent: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var title: String
    public var day: LocalDay
    public var startMinutes: Int
    public var endMinutes: Int
    public var notes = ""
    public var location = ""
    public var projectID: UUID?
    public init(title: String, day: LocalDay, startMinutes: Int, endMinutes: Int) {
        self.title = title; self.day = day; self.startMinutes = startMinutes; self.endMinutes = endMinutes
    }
}

public struct YearMarker: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var title: String
    public var startDay: LocalDay
    public var endDay: LocalDay?
    public var category = "Important Date"
    public var notes = ""
    public var subjectID: UUID?
    public var colour = "orange"
    public init(title: String, startDay: LocalDay) { self.title = title; self.startDay = startDay }
}

public enum ActivityKind: String, Codable, Sendable { case taskCompleted, progressAdded, confidenceChanged, milestoneCompleted }

public struct ActivityRecord: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var date = Date()
    public var kind: ActivityKind
    public var title: String
    public var subjectID: UUID?
    public var topicID: UUID?
    public var projectID: UUID?
    public init(kind: ActivityKind, title: String, subjectID: UUID? = nil, topicID: UUID? = nil, projectID: UUID? = nil) {
        self.kind = kind; self.title = title; self.subjectID = subjectID; self.topicID = topicID; self.projectID = projectID
    }
}

public struct WeekdayHours: Codable, Hashable, Sendable, Identifiable {
    public var weekday: Int
    public var startMinutes: Int
    public var endMinutes: Int
    public var id: Int { weekday }
    public init(weekday: Int, startMinutes: Int = 1020, endMinutes: Int = 1320) { self.weekday = weekday; self.startMinutes = startMinutes; self.endMinutes = endMinutes }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var defaultTaskMinutes = 30
    public var eveningStartMinutes = 1020
    public var eveningEndMinutes = 1320
    public var maxFocusMinutes = 50
    public var breakMinutes = 10
    public var weekStartsMonday = true
    public var academicYearStartMonth = 9
    public var planningHours = (1...7).map { WeekdayHours(weekday: $0) }
    public var hasCompletedOnboarding = false
    public var automaticICloudBackup = false
    public var lastICloudBackup: Date?
    public var notificationsScheduledItems = false
    public var notificationsDeadlines = false
    public var notificationsFocus = true
    public var notificationLeadMinutes = 10
    public var selectedExternalCalendarIDs: [String] = []
    public var lastExternalCalendarRefresh: Date?
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case defaultTaskMinutes, eveningStartMinutes, eveningEndMinutes, maxFocusMinutes
        case breakMinutes, weekStartsMonday, academicYearStartMonth, planningHours, hasCompletedOnboarding
        case automaticICloudBackup, lastICloudBackup, notificationsScheduledItems, notificationsDeadlines
        case notificationsFocus, notificationLeadMinutes, selectedExternalCalendarIDs, lastExternalCalendarRefresh
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        defaultTaskMinutes = try values.decodeIfPresent(Int.self, forKey: .defaultTaskMinutes) ?? 30
        eveningStartMinutes = try values.decodeIfPresent(Int.self, forKey: .eveningStartMinutes) ?? 1020
        eveningEndMinutes = try values.decodeIfPresent(Int.self, forKey: .eveningEndMinutes) ?? 1320
        maxFocusMinutes = try values.decodeIfPresent(Int.self, forKey: .maxFocusMinutes) ?? 50
        breakMinutes = try values.decodeIfPresent(Int.self, forKey: .breakMinutes) ?? 10
        weekStartsMonday = try values.decodeIfPresent(Bool.self, forKey: .weekStartsMonday) ?? true
        academicYearStartMonth = try values.decodeIfPresent(Int.self, forKey: .academicYearStartMonth) ?? 9
        planningHours = try values.decodeIfPresent([WeekdayHours].self, forKey: .planningHours) ?? (1...7).map { WeekdayHours(weekday: $0) }
        hasCompletedOnboarding = try values.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        automaticICloudBackup = try values.decodeIfPresent(Bool.self, forKey: .automaticICloudBackup) ?? false
        lastICloudBackup = try values.decodeIfPresent(Date.self, forKey: .lastICloudBackup)
        notificationsScheduledItems = try values.decodeIfPresent(Bool.self, forKey: .notificationsScheduledItems) ?? false
        notificationsDeadlines = try values.decodeIfPresent(Bool.self, forKey: .notificationsDeadlines) ?? false
        notificationsFocus = try values.decodeIfPresent(Bool.self, forKey: .notificationsFocus) ?? true
        notificationLeadMinutes = try values.decodeIfPresent(Int.self, forKey: .notificationLeadMinutes) ?? 10
        selectedExternalCalendarIDs = try values.decodeIfPresent([String].self, forKey: .selectedExternalCalendarIDs) ?? []
        lastExternalCalendarRefresh = try values.decodeIfPresent(Date.self, forKey: .lastExternalCalendarRefresh)
    }
}

public enum FocusSessionKind: String, Codable, Hashable, Sendable { case focus, shortBreak }

public struct ActiveFocusSession: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var kind: FocusSessionKind
    public var taskID: UUID?
    public var taskTitle: String
    public var subjectID: UUID?
    public var projectID: UUID?
    public var plannedMinutes: Int
    public var startedAt = Date()
    public var pausedAt: Date?
    public var pausedSeconds: TimeInterval = 0

    public init(kind: FocusSessionKind, taskID: UUID?, taskTitle: String, subjectID: UUID? = nil, projectID: UUID? = nil, plannedMinutes: Int) {
        self.kind = kind
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.subjectID = subjectID
        self.projectID = projectID
        self.plannedMinutes = plannedMinutes
    }

    public func elapsedSeconds(at date: Date = .now) -> TimeInterval {
        let effectiveEnd = pausedAt ?? date
        return max(0, effectiveEnd.timeIntervalSince(startedAt) - pausedSeconds)
    }
}

public struct FocusSessionRecord: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var kind: FocusSessionKind
    public var taskID: UUID?
    public var taskTitle: String
    public var subjectID: UUID?
    public var projectID: UUID?
    public var startedAt: Date
    public var endedAt: Date
    public var focusedSeconds: Int
    public var completedTimer: Bool

    public init(from active: ActiveFocusSession, endedAt: Date = .now, completedTimer: Bool) {
        id = active.id
        kind = active.kind
        taskID = active.taskID
        taskTitle = active.taskTitle
        subjectID = active.subjectID
        projectID = active.projectID
        startedAt = active.startedAt
        self.endedAt = completedTimer ? active.startedAt.addingTimeInterval(active.pausedSeconds + Double(active.plannedMinutes * 60)) : endedAt
        focusedSeconds = completedTimer ? active.plannedMinutes * 60 : Int(active.elapsedSeconds(at: endedAt))
        self.completedTimer = completedTimer
    }
}

public struct ExternalCalendarEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var calendarID: String
    public var calendarTitle: String
    public var title: String
    public var day: LocalDay
    public var startMinutes: Int
    public var endMinutes: Int
    public var isAllDay: Bool
    public var location: String
    public var notes: String

    public var startInstant: Date?
    public var endInstant: Date?
    public var timeZoneIdentifier: String?

    public init(id: String, calendarID: String, calendarTitle: String, title: String, day: LocalDay, startMinutes: Int, endMinutes: Int, isAllDay: Bool, location: String = "", notes: String = "", startInstant: Date? = nil, endInstant: Date? = nil, timeZoneIdentifier: String? = nil) {
        self.id = id; self.calendarID = calendarID; self.calendarTitle = calendarTitle; self.title = title
        self.day = day; self.startMinutes = startMinutes; self.endMinutes = endMinutes; self.isAllDay = isAllDay
        self.location = location; self.notes = notes
        self.startInstant = startInstant; self.endInstant = endInstant; self.timeZoneIdentifier = timeZoneIdentifier
    }
}

public struct LifeBoardData: Codable, Sendable {
    public var schemaVersion = 3
    public var tasks: [TaskItem] = []
    public var events: [CalendarEvent] = []
    public var subjects: [Subject] = []
    public var projects: [Project] = []
    public var yearMarkers: [YearMarker] = []
    public var activity: [ActivityRecord] = []
    public var focusSessions: [FocusSessionRecord] = []
    public var activeFocus: ActiveFocusSession?
    public var externalEvents: [ExternalCalendarEvent] = []
    public var settings = AppSettings()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, tasks, events, subjects, projects, yearMarkers, activity, focusSessions, activeFocus, externalEvents, settings
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...3).contains(version) else { throw LifeBoardError.unsupportedSchema(version) }
        schemaVersion = 3
        tasks = try values.decodeIfPresent([TaskItem].self, forKey: .tasks) ?? []
        events = try values.decodeIfPresent([CalendarEvent].self, forKey: .events) ?? []
        subjects = try values.decodeIfPresent([Subject].self, forKey: .subjects) ?? []
        projects = try values.decodeIfPresent([Project].self, forKey: .projects) ?? []
        yearMarkers = try values.decodeIfPresent([YearMarker].self, forKey: .yearMarkers) ?? []
        activity = try values.decodeIfPresent([ActivityRecord].self, forKey: .activity) ?? []
        focusSessions = try values.decodeIfPresent([FocusSessionRecord].self, forKey: .focusSessions) ?? []
        activeFocus = try values.decodeIfPresent(ActiveFocusSession.self, forKey: .activeFocus)
        externalEvents = try values.decodeIfPresent([ExternalCalendarEvent].self, forKey: .externalEvents) ?? []
        settings = try values.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
    }

    public static func seeded() -> LifeBoardData {
        var value = LifeBoardData()
        value.subjects = ["Mathematics", "English Literature", "English Language", "Biology", "Chemistry", "Physics", "Drama", "History", "Geography"].map(Subject.init)
        value.projects = ["Coursework", "Personal Project", "Creative Project", "Team Project"].map(Project.init)
        return value
    }
}

// Value equality lets the app skip no-op saves without serialising the workspace.
extension LifeBoardData: Equatable {}

public struct TaskImportPayload: Codable, Sendable {
    public var title: String
    public var notes: String?
    public var estimatedMinutes: Int?
    public var dueDate: String?
    public var scheduledDate: String?
    public var scheduledStart: String?
    public var priority: String?
    public var subject: String?
    public var topic: String?
    public var project: String?
    public init(title: String) { self.title = title }
}
