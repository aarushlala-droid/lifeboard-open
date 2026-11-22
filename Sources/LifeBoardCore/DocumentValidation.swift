import Foundation
import CoreFoundation

public struct DocumentValidationError: LocalizedError, Sendable {
    public let fields: [String]
    public var errorDescription: String? { "Invalid LifeBoard data: " + fields.prefix(8).joined(separator: ", ") }
    public init(_ fields: [String]) { self.fields = fields }
}

/// The contract shared by durable files, backups, helper imports and sync.
public enum LifeBoardValidation {
    public static let maximumDocumentBytes = 20 * 1024 * 1024
    public static let maximumCollectionCount = 20_000

    public static func decode(_ bytes: Data) throws -> LifeBoardData {
        guard bytes.count <= maximumDocumentBytes,
              let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw DocumentValidationError(["document must be an object under 20 MB"])
        }
        if let version = root["schemaVersion"] as? NSNumber, version.intValue > 3 {
            throw LifeBoardError.unsupportedSchema(version.intValue)
        }
        // Missing version is supported only for a real legacy workspace.
        for key in ["tasks", "events", "subjects", "projects", "yearMarkers", "activity"] {
            guard root[key] is [Any] else { throw DocumentValidationError([key + " is required"]) }
        }
        guard root["settings"] is [String: Any] else { throw DocumentValidationError(["settings is required"]) }
        if let raw = root["schemaVersion"] {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.rounded() == n.doubleValue, (1...3).contains(n.intValue) else { throw DocumentValidationError(["schemaVersion must be 1, 2 or 3"]) }
        }
        try rejectUnknownFields(root)
        let decoder = LifeBoardJSON.decoder()
        let document = try decoder.decode(LifeBoardData.self, from: bytes)
        try validate(document)
        return document
    }

    private static func rejectUnknownFields(_ root: [String: Any]) throws {
        let sets: [String: Set<String>] = [
            "document": Set("schemaVersion tasks events subjects projects yearMarkers activity focusSessions activeFocus externalEvents settings".split(separator: " ").map(String.init)),
            "tasks": Set("id title notes createdAt modifiedAt isCompleted completedAt completionPercent estimatedMinutes actualMinutes priority dueDay scheduledDay scheduledStartMinutes scheduledDurationMinutes subjectID topicID projectID milestoneID tags sortOrder isArchived archivedAt recurrenceSeriesID subtasks recurrence".split(separator: " ").map(String.init)),
            "events": Set("id title day startMinutes endMinutes notes location projectID".split(separator: " ").map(String.init)),
            "subjects": Set("id title confidence progress notes colour archived lastActivity topics confidenceHistory".split(separator: " ").map(String.init)),
            "topics": Set("id title confidence progress notes lastActivity".split(separator: " ").map(String.init)),
            "projects": Set("id title status progress health summary notes startDay targetDay colour milestones updates progressHistory lastActivity progressMode".split(separator: " ").map(String.init)),
            "milestones": Set("id title targetDay isCompleted notes".split(separator: " ").map(String.init)),
            "updates": Set("id date text confidenceChange progressChange".split(separator: " ").map(String.init)),
            "confidenceHistory": Set(["id", "date", "value"]), "progressHistory": Set(["id", "date", "value"]),
            "yearMarkers": Set("id title startDay endDay category notes subjectID colour".split(separator: " ").map(String.init)),
            "activity": Set("id date kind title subjectID topicID projectID".split(separator: " ").map(String.init)),
            "activeFocus": Set("id kind taskID taskTitle subjectID projectID plannedMinutes startedAt pausedAt pausedSeconds".split(separator: " ").map(String.init)),
            "focusSessions": Set("id kind taskID taskTitle subjectID projectID startedAt endedAt focusedSeconds completedTimer".split(separator: " ").map(String.init)),
            "externalEvents": Set("id calendarID calendarTitle title day startMinutes endMinutes isAllDay location notes startInstant endInstant timeZoneIdentifier".split(separator: " ").map(String.init)),
            "settings": Set("defaultTaskMinutes eveningStartMinutes eveningEndMinutes maxFocusMinutes breakMinutes weekStartsMonday academicYearStartMonth planningHours hasCompletedOnboarding automaticICloudBackup lastICloudBackup notificationsScheduledItems notificationsDeadlines notificationsFocus notificationLeadMinutes selectedExternalCalendarIDs lastExternalCalendarRefresh".split(separator: " ").map(String.init)),
            "planningHours": Set(["weekday", "startMinutes", "endMinutes"]),
            "subtasks": Set(["id", "title", "isCompleted"]), "recurrence": Set(["frequency", "interval", "nextDay"]),
            "day": Set(["year", "month", "day"])
        ]
        let dateKeys = Set(["dueDay", "scheduledDay", "day", "startDay", "endDay", "startDay", "targetDay", "nextDay"])
        func walk(_ object: [String: Any], type: String, path: String) throws {
            guard let keys = sets[type] else { return }
            let unknown = Set(object.keys).subtracting(keys).sorted()
            guard unknown.isEmpty else { throw DocumentValidationError(unknown.map { path + "/" + $0 + " is unsupported" }) }
            for (key, value) in object {
                let childType = dateKeys.contains(key) ? "day" : key
                if let child = value as? [String: Any] { try walk(child, type: childType, path: path + "/" + key) }
                if let array = value as? [[String: Any]] { for (index, child) in array.enumerated() { try walk(child, type: childType, path: path + "/" + key + "/" + String(index)) } }
            }
        }
        try walk(root, type: "document", path: "document")
    }

    public static func validate(_ data: LifeBoardData) throws {
        guard data.schemaVersion == 3 else { throw LifeBoardError.unsupportedSchema(data.schemaVersion) }
        var errors: [String] = []
        func check(_ valid: Bool, _ path: String) { if !valid { errors.append(path) } }
        func title(_ value: String, _ path: String) { check(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 2_000, path) }
        func text(_ value: String, _ path: String) { check(value.count <= 200_000, path) }
        func range(_ value: Double, _ bounds: ClosedRange<Double>, _ path: String) { check(value.isFinite && bounds.contains(value), path) }
        func date(_ day: LocalDay?, _ path: String) {
            guard let day else { return }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let actual = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))
            check((1...9999).contains(day.year) && actual.map { LocalDay($0, calendar: calendar) == day } == true, path)
        }
        func unique<T: Identifiable>(_ records: [T], _ path: String) where T.ID: Hashable {
            check(records.count <= maximumCollectionCount, path + ".count")
            check(Set(records.map(\.id)).count == records.count, path + ".duplicateID")
        }
        unique(data.tasks, "tasks"); unique(data.events, "events"); unique(data.subjects, "subjects"); unique(data.projects, "projects")
        unique(data.yearMarkers, "yearMarkers"); unique(data.activity, "activity"); unique(data.focusSessions, "focusSessions"); unique(data.externalEvents, "externalEvents")
        let subjects = Dictionary(data.subjects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let projects = Dictionary(data.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for task in data.tasks {
            let p = "tasks/\(task.id)"
            title(task.title, p + "/title"); text(task.notes, p + "/notes")
            check((1...1440).contains(task.estimatedMinutes), p + "/estimatedMinutes")
            if let amount = task.actualMinutes { check((0...525600).contains(amount), p + "/actualMinutes") }
            if let amount = task.completionPercent { range(amount, 0...100, p + "/completionPercent") }
            range(task.sortOrder, -1e12...1e12, p + "/sortOrder")
            date(task.dueDay, p + "/dueDay"); date(task.scheduledDay, p + "/scheduledDay")
            if let start = task.scheduledStartMinutes {
                check((0..<1440).contains(start) && task.scheduledDay != nil, p + "/scheduledStartMinutes")
            }
            if let duration = task.scheduledDurationMinutes { check((1...1440).contains(duration), p + "/scheduledDurationMinutes") }
            if let id = task.subjectID { check(subjects[id] != nil, p + "/subjectID") }
            if let id = task.topicID { check(task.subjectID.flatMap { subjects[$0] }?.topics.contains { $0.id == id } == true, p + "/topicID") }
            if let id = task.projectID { check(projects[id] != nil, p + "/projectID") }
            if let id = task.milestoneID { check(task.projectID.flatMap { projects[$0] }?.milestones.contains { $0.id == id } == true, p + "/milestoneID") }
            check(task.tags.count <= 100 && task.tags.allSatisfy { $0.count <= 500 }, p + "/tags")
            if let subtasks = task.subtasks { unique(subtasks, p + "/subtasks"); for subtask in subtasks { title(subtask.title, p + "/subtasks/title") } }
            if let recurrence = task.recurrence { check(["daily", "weekly", "monthly"].contains(recurrence.frequency) && (1...365).contains(recurrence.interval), p + "/recurrence"); date(recurrence.nextDay, p + "/recurrence/nextDay") }
        }
        for subject in data.subjects {
            let p = "subjects/\(subject.id)"; title(subject.title, p + "/title"); text(subject.notes, p + "/notes")
            range(subject.confidence, 0...5, p + "/confidence"); range(subject.progress, 0...100, p + "/progress")
            unique(subject.topics, p + "/topics"); unique(subject.confidenceHistory, p + "/confidenceHistory")
            for topic in subject.topics { title(topic.title, p + "/topics/title"); text(topic.notes, p + "/topics/notes"); range(topic.confidence, 0...5, p + "/topics/confidence"); range(topic.progress, 0...100, p + "/topics/progress") }
            for metric in subject.confidenceHistory { range(metric.value, 0...5, p + "/confidenceHistory/value") }
        }
        for project in data.projects {
            let p = "projects/\(project.id)"; title(project.title, p + "/title"); text(project.notes, p + "/notes"); text(project.summary, p + "/summary")
            range(project.progress, 0...100, p + "/progress"); range(project.health, 0...5, p + "/health")
            check(project.progressMode.map { ["manual", "tasks", "milestones"].contains($0) } ?? true, p + "/progressMode")
            date(project.startDay, p + "/startDay"); date(project.targetDay, p + "/targetDay")
            unique(project.milestones, p + "/milestones"); unique(project.updates, p + "/updates"); unique(project.progressHistory, p + "/progressHistory")
            for milestone in project.milestones { title(milestone.title, p + "/milestones/title"); date(milestone.targetDay, p + "/milestones/targetDay"); text(milestone.notes, p + "/milestones/notes") }
            for update in project.updates { text(update.text, p + "/updates/text"); if let amount = update.confidenceChange { range(amount, -5...5, p + "/updates/confidenceChange") }; if let amount = update.progressChange { range(amount, -100...100, p + "/updates/progressChange") } }
            for metric in project.progressHistory { range(metric.value, 0...100, p + "/progressHistory/value") }
        }
        for event in data.events {
            let p = "events/\(event.id)"; title(event.title, p + "/title"); text(event.notes, p + "/notes"); date(event.day, p + "/day")
            check((0..<1440).contains(event.startMinutes) && (1...1440).contains(event.endMinutes) && event.endMinutes > event.startMinutes, p + "/interval")
            if let id = event.projectID { check(projects[id] != nil, p + "/projectID") }
        }
        for marker in data.yearMarkers {
            let p = "yearMarkers/\(marker.id)"; title(marker.title, p + "/title"); text(marker.notes, p + "/notes"); date(marker.startDay, p + "/startDay"); date(marker.endDay, p + "/endDay")
            check(marker.endDay.map { $0 >= marker.startDay } ?? true, p + "/interval")
            if let id = marker.subjectID { check(subjects[id] != nil, p + "/subjectID") }
        }
        // History retains IDs of work permanently deleted by older versions.
        for record in data.activity { title(record.title, "activity/title") }
        for record in data.focusSessions { check((0...525600 * 60).contains(record.focusedSeconds) && record.endedAt >= record.startedAt, "focusSessions/interval"); title(record.taskTitle, "focusSessions/taskTitle") }
        if let active = data.activeFocus {
            if let id = active.taskID { check(data.tasks.contains(where: { $0.id == id }), "activeFocus/taskID") }
            if let id = active.subjectID { check(subjects[id] != nil, "activeFocus/subjectID") }
            if let id = active.projectID { check(projects[id] != nil, "activeFocus/projectID") }
            title(active.taskTitle, "activeFocus/taskTitle"); check((1...240).contains(active.plannedMinutes), "activeFocus/plannedMinutes")
            range(active.pausedSeconds, 0...Double(525600 * 60), "activeFocus/pausedSeconds")
            check(active.pausedAt.map { $0 >= active.startedAt } ?? true, "activeFocus/pausedAt")
        }
        for event in data.externalEvents {
            check(!event.id.isEmpty && event.id.count <= 2000 && !event.calendarID.isEmpty, "externalEvents/id"); title(event.title, "externalEvents/title"); date(event.day, "externalEvents/day")
            check((0...1440).contains(event.startMinutes) && (0...1440).contains(event.endMinutes) && (event.isAllDay || event.endMinutes > event.startMinutes), "externalEvents/interval")
            text(event.notes, "externalEvents/notes")
            if let start = event.startInstant, let end = event.endInstant { check(end > start, "externalEvents/instantInterval") }
            check((event.startInstant == nil) == (event.endInstant == nil), "externalEvents/instantPair")
            if let zone = event.timeZoneIdentifier { check(TimeZone(identifier: zone) != nil, "externalEvents/timeZoneIdentifier") }
        }
        let s = data.settings
        check((1...1440).contains(s.defaultTaskMinutes), "settings/defaultTaskMinutes"); check((1...240).contains(s.maxFocusMinutes), "settings/maxFocusMinutes")
        check((0...60).contains(s.breakMinutes), "settings/breakMinutes"); check((1...12).contains(s.academicYearStartMonth), "settings/academicYearStartMonth")
        check((0..<1440).contains(s.eveningStartMinutes) && (1...1440).contains(s.eveningEndMinutes) && s.eveningEndMinutes > s.eveningStartMinutes, "settings/eveningInterval")
        check((0...10080).contains(s.notificationLeadMinutes), "settings/notificationLeadMinutes")
        check(s.planningHours.count <= 7 && Set(s.planningHours.map(\.weekday)).count == s.planningHours.count, "settings/planningHours")
        for hours in s.planningHours { check((1...7).contains(hours.weekday) && (0..<1440).contains(hours.startMinutes) && (1...1440).contains(hours.endMinutes) && hours.endMinutes > hours.startMinutes, "settings/planningHours/interval") }
        check(s.selectedExternalCalendarIDs.count <= 100 && s.selectedExternalCalendarIDs.allSatisfy { !$0.isEmpty && $0.count <= 2000 }, "settings/selectedExternalCalendarIDs")
        guard errors.isEmpty else { throw DocumentValidationError(errors) }
    }
}

/// Wire dates from web and calendar APIs may include fractional seconds.
public enum LifeBoardJSON {
    private static let wholeSecond = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, output in
            let interval = date.timeIntervalSinceReferenceDate
            guard interval.isFinite else {
                throw EncodingError.invalidValue(date, .init(codingPath: output.codingPath, debugDescription: "Invalid date"))
            }
            let seconds = floor(interval)
            let fraction = Int(((interval - seconds) * 1_000_000_000).rounded())
            let whole = Date(timeIntervalSinceReferenceDate: seconds + Double(fraction / 1_000_000_000))
            let base = wholeSecond.format(whole).dropLast() // UTC's trailing Z
            let nanos = String(format: "%09d", fraction % 1_000_000_000)
            var value = output.singleValueContainer()
            // Fixed-width UTC strings also retain chronological sort order during merges.
            try value.encode("\(base).\(nanos)Z")
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let raw = try value.singleValueContainer().decode(String.self)
            if let point = raw.firstIndex(of: ".") {
                let digits = raw[raw.index(after: point)...].prefix { $0.isASCII && $0.isNumber }
                let zone = raw[digits.endIndex...]
                if !digits.isEmpty, !zone.isEmpty, let fraction = Double("0.\(digits)"),
                   let whole = try? wholeSecond.parse(String(raw[..<point]) + zone) {
                    return whole.addingTimeInterval(fraction)
                }
            } else if let date = try? wholeSecond.parse(raw) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: value.codingPath, debugDescription: "Invalid ISO date"))
        }
        return decoder
    }
}
