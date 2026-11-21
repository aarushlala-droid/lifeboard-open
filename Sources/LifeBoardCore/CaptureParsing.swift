import Foundation

public enum CapturedItemKind: String, CaseIterable, Hashable, Sendable, Identifiable {
    case task = "Task"
    case event = "Event"
    public var id: String { rawValue }
}

public struct CapturedTaskDraft: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var isIncluded = true
    public var title: String
    public var estimatedMinutes: Int
    public var targetDay: LocalDay?
    public var startMinutes: Int?
    public var priority: TaskPriority
    public var subjectID: UUID?
    public var projectID: UUID?
    public var kind: CapturedItemKind
    public var notes: String
    public var originalText: String = ""
    public var reviewReason: String?
    public var needsReview: Bool

    public init(title: String, estimatedMinutes: Int = 30, targetDay: LocalDay? = nil, startMinutes: Int? = nil, priority: TaskPriority = .none, subjectID: UUID? = nil, projectID: UUID? = nil, kind: CapturedItemKind = .task, notes: String = "", needsReview: Bool = false) {
        self.title = title
        self.estimatedMinutes = estimatedMinutes
        self.targetDay = targetDay
        self.startMinutes = startMinutes
        self.priority = priority
        self.subjectID = subjectID
        self.projectID = projectID
        self.kind = kind
        self.notes = notes
        self.needsReview = needsReview
    }
}

public enum NaturalLanguageTaskParser {
    public static func parse(_ text: String, referenceDay: LocalDay = .today, data: LifeBoardData) -> [CapturedTaskDraft] {
        let lines = text
            .replacingOccurrences(of: "•", with: "\n")
            .components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: ";") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var inheritedDay: LocalDay?
        var expanded: [(String, LocalDay?)] = []
        for line in lines {
            if has(line, #"^(today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|this weekend)(\s+(planner|plan|tasks|to-?do))?\s*:?$"#) {
                inheritedDay = date(in: line, referenceDay: referenceDay); continue
            }
            if has(line, #"^[x✓✗✔☒]"#) { continue }
            let pairPattern = #"(?i)^\s*([\w ]+?)\s+and\s+([\w ]+?)\s+(tonight|today|tomorrow|this weekend)\b(.+)$"#
            if has(line, #"\beach\b"#), let regex = try? NSRegularExpression(pattern: pairPattern), let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let first = Range(match.range(at: 1), in: line), let second = Range(match.range(at: 2), in: line), let date = Range(match.range(at: 3), in: line), let suffix = Range(match.range(at: 4), in: line) {
                expanded += [first, second].map { ("\(line[$0]) \(line[date]) \(line[suffix])", inheritedDay) }
            } else { expanded.append((line, inheritedDay)) }
        }
        return expanded.map { line, inheritedDay in
            let duration = durationMinutes(in: line) ?? data.settings.defaultTaskMinutes
            let targetDay = date(in: line, referenceDay: referenceDay) ?? inheritedDay
            let noSchedule = has(line, #"\b(don['’]t schedule|do not schedule|no schedule|unscheduled)\b"#)
            let start = has(line, #"\b(don['’]t schedule|do not schedule|no schedule|unscheduled)\b"#) ? nil : time(in: line)
            let subject = data.subjects.first { matchesAssociation(line, names: [$0.title] + subjectAliases($0.title)) }
            let project = data.projects.first { matchesAssociation(line, names: [$0.title]) }
            let priority: TaskPriority = has(line, #"\b(urgent|high priority|important)\b"#) ? .high : has(line, #"\bmedium priority\b"#) ? .medium : has(line, #"\blow priority\b"#) ? .low : .none
            let title = cleanedTitle(line)
            let kind: CapturedItemKind = isLikelyEvent(line) ? .event : .task
            let dateMentioned = has(line, numericDatePattern) || has(line, namedDatePattern)
            var draft = CapturedTaskDraft(title: title.isEmpty ? line : title, estimatedMinutes: duration, targetDay: targetDay, startMinutes: start, priority: priority, subjectID: subject?.id, projectID: project?.id, kind: kind, needsReview: dateMentioned && targetDay == nil)
            draft.originalText = line
            if draft.needsReview { draft.reviewReason = "The date is invalid. Check the original input." }
            if !noSchedule && start == nil && has(line, #"\bat\s+\d{1,2}(?::\d{2})?\b"#) { draft.needsReview = true; draft.reviewReason = "The time is invalid or ambiguous. Check the original input." }
            if start != nil && targetDay == nil { draft.needsReview = true; draft.reviewReason = "A time needs a planned day. The due date does not schedule work." }
            return draft
        }
    }

    public static func suggestedSchedule(for drafts: [CapturedTaskDraft], data: LifeBoardData, referenceDay: LocalDay = .today, now: Date = .now) -> [CapturedTaskDraft] {
        var result = drafts
        let days = Set(result.filter(\.isIncluded).map { $0.targetDay ?? referenceDay })
        for day in days {
            let indices = result.indices.filter { result[$0].isIncluded && (result[$0].targetDay ?? referenceDay) == day }
            let requests = indices.map { ScheduleRequest(id: result[$0].id, duration: result[$0].estimatedMinutes, explicitStart: result[$0].startMinutes) }
            let suggestions = SchedulingEngine.suggest(requests, data: data, day: day, now: now)
            for index in indices {
                guard let suggestion = suggestions.first(where: { $0.id == result[index].id }) else { continue }
                if let start = suggestion.start { result[index].targetDay = day; result[index].startMinutes = start }
                else { result[index].startMinutes = nil; result[index].needsReview = true; result[index].reviewReason = suggestion.reason }
            }
        }
        return result
    }

    private static let numericDatePattern = #"\b(\d{1,2})[/.](\d{1,2})(?:[/.](\d{2,4}))?\b"#
    private static let namedDatePattern = #"(?i)\b(\d{1,2})(?:st|nd|rd|th)?\s+(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)(?:\s+(\d{4}))?\b"#
    private static func has(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
    private static func matchesAssociation(_ text: String, names: [String]) -> Bool {
        names.contains { has(text, #"\b"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"#) }
    }

    private static func durationMinutes(in text: String) -> Int? {
        let pattern = #"(?i)\b(\d{1,3})\s*(minutes?|mins?|m|hours?|hrs?|h)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text), let value = Int(text[numberRange]) else { return nil }
        let unit = text[unitRange].lowercased()
        return min(480, max(5, unit.hasPrefix("h") ? value * 60 : value))
    }

    private static func time(in text: String) -> Int? {
        let pattern = #"(?i)\b(?:at\s*)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let hourRange = Range(match.range(at: 1), in: text), var hour = Int(text[hourRange]) else { continue }
            let minute = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? 0
            let suffix = Range(match.range(at: 3), in: text).map { text[$0].lowercased() }
            if suffix == nil && !text[hourRange].contains(":") && match.range(at: 2).location == NSNotFound { continue }
            if suffix != nil && !(1...12).contains(hour) { continue }
            if suffix == "pm", hour < 12 { hour += 12 }
            if suffix == "am", hour == 12 { hour = 0 }
            if (0..<24).contains(hour), (0..<60).contains(minute) { return hour * 60 + minute }
        }
        return nil
    }

    private static func date(in text: String, referenceDay: LocalDay) -> LocalDay? {
        let lower = text.lowercased()
        if has(lower, #"\btomorrow\b"#) { return referenceDay.adding(days: 1) }
        if has(lower, #"\b(today|tonight)\b"#) { return referenceDay }
        if has(lower, #"\bthis weekend\b"#) {
            let weekday = Calendar.current.component(.weekday, from: referenceDay.date()) - 1
            return referenceDay.adding(days: (6 - weekday + 7) % 7)
        }
        if lower.contains("this week") {
            let weekday = Calendar.current.component(.weekday, from: referenceDay.date())
            return referenceDay.adding(days: max(1, 8 - weekday))
        }
        if lower.contains("next week") { return referenceDay.adding(days: 7) }
        let numericPattern = numericDatePattern
        if let regex = try? NSRegularExpression(pattern: numericPattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let dayRange = Range(match.range(at: 1), in: text), let monthRange = Range(match.range(at: 2), in: text),
           let day = Int(text[dayRange]), let month = Int(text[monthRange]) {
            let rawYear = Range(match.range(at: 3), in: text).flatMap { Int(text[$0]) }
            let year = rawYear.map { $0 < 100 ? 2000 + $0 : $0 } ?? referenceDay.year
            let candidate = LocalDay(year: year, month: month, day: day)
            return candidate.isValid ? candidate : nil
        }
        if let regex = try? NSRegularExpression(pattern: namedDatePattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let dayRange = Range(match.range(at: 1), in: text), let monthRange = Range(match.range(at: 2), in: text), let day = Int(text[dayRange]) {
            let monthText = String(text[monthRange]).lowercased()
            let month = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex { monthText.hasPrefix($0) }.map { $0 + 1 } ?? 0
            let explicitYear = Range(match.range(at: 3), in: text).flatMap { Int(text[$0]) }
            var candidate = LocalDay(year: explicitYear ?? referenceDay.year, month: month, day: day)
            guard candidate.isValid else { return nil }
            if explicitYear == nil && candidate < referenceDay { candidate.year += 1 }
            return candidate.isValid ? candidate : nil
        }
        let weekdays = Calendar.current.weekdaySymbols.map { $0.lowercased() }
        for (offset, weekday) in weekdays.enumerated() where lower.range(of: #"\b\#(weekday)\b"#, options: .regularExpression) != nil {
            let current = Calendar.current.component(.weekday, from: referenceDay.date()) - 1
            let delta = ((offset - current + 7) % 7)
            return referenceDay.adding(days: delta == 0 ? 7 : delta)
        }
        return nil
    }

    private static func cleanedTitle(_ text: String) -> String {
        var result = text
        let patterns = [
            #"(?i)\b(?:for\s+)?(?:around\s+|about\s+|roughly\s+)?\d{1,3}\s*(minutes?|mins?|m|hours?|hrs?|h)\b"#,
            #"(?i)\b(?:(?:on|by|due)\s+)?(today|tonight|tomorrow|sometime this week|this week|this weekend|monday|tuesday|wednesday|thursday|friday|saturday|sunday|next week)\b"#,
            #"(?i)\b(?:on\s+|by\s+|due\s+)?"# + namedDatePattern.replacingOccurrences(of: "(?i)", with: ""),
            #"(?i)\b(?:on\s+|by\s+|due\s+)?"# + numericDatePattern,
            #"(?i)\b(urgent|high priority|medium priority|low priority|important|don['’]t schedule|do not schedule|no schedule|unscheduled|around|each)\b"#,
            #"(?i)\b(?:at\s*)?\d{1,2}:\d{2}\s*(?:am|pm)?\b|\b(?:at\s*)?\d{1,2}\s*(?:am|pm)\b"#
        ]
        for pattern in patterns { result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }
        result = result.replacingOccurrences(of: #"^[\s\-•☐□*\d.)]+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—,")))
        guard let first = result.first else { return result }
        return String(first).uppercased() + result.dropFirst()
    }

    private static func subjectAliases(_ title: String) -> [String] {
        switch title.lowercased() {
        case "english language": return ["english", "english lang"]
        case "english literature": return ["english lit"]
        case "mathematics": return ["maths", "math"]
        case "chemistry": return ["chem"]
        case "physics": return ["phys"]
        case "biology": return ["bio"]
        case "geography": return ["geog"]
        default: return []
        }
    }

    private static func isLikelyEvent(_ text: String) -> Bool {
        let lower = text.lowercased()
        let eventWords = ["meeting", "appointment", "lesson", "class", "call", "dinner", "lunch", "exam", "match", "rehearsal"]
        return eventWords.contains(where: lower.contains) && time(in: text) != nil
    }
}
