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
    /// The text asked for no date ("anytime", "someday", "no date"), so the
    /// item stays undated instead of being planned for today.
    public var isAnytime = false

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

/// Reads one-line planner entries. mobile/web/capture.js is its JavaScript
/// twin: keep the rewrite rules, subject table and title cleaning identical.
public enum NaturalLanguageTaskParser {
    public static func parse(_ text: String, referenceDay: LocalDay = .today, data: LifeBoardData) -> [CapturedTaskDraft] {
        let lines = text
            .replacingOccurrences(of: "•", with: "\n")
            .components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: ";") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var inheritedDay: LocalDay?
        var expanded: [(source: String, line: String, inheritedDay: LocalDay?)] = []
        for source in lines {
            // Abbreviations are rewritten to their full forms first, so every
            // later rule only has to know one spelling.
            let line = normalised(source, subjects: data.subjects)
            if has(line, headingPattern) {
                inheritedDay = date(in: line, referenceDay: referenceDay); continue
            }
            if has(line, #"^[x✓✗✔☒]"#) { continue }
            if has(line, #"\beach\b"#), let match = pairRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let first = Range(match.range(at: 1), in: line), let second = Range(match.range(at: 2), in: line), let date = Range(match.range(at: 3), in: line), let suffix = Range(match.range(at: 4), in: line) {
                expanded += [first, second].map { let item = "\(line[$0]) \(line[date]) \(line[suffix])"; return (source: item, line: item, inheritedDay: inheritedDay) }
            } else { expanded.append((source, line, inheritedDay)) }
        }
        return expanded.map { source, line, inheritedDay in
            let duration = durationMinutes(in: line) ?? data.settings.defaultTaskMinutes
            let explicitDay = date(in: line, referenceDay: referenceDay)
            let dateMentioned = has(line, numericDatePattern) || has(line, namedDatePattern)
            // A typed date always wins; "anytime" only clears an inherited heading day.
            let isAnytime = explicitDay == nil && !dateMentioned && has(line, #"\banytime\b"#)
            let targetDay = isAnytime ? nil : explicitDay ?? inheritedDay
            let noSchedule = has(line, #"\b(don['’]t schedule|do not schedule|no schedule|unscheduled)\b"#)
            let start = noSchedule ? nil : time(in: line)
            let subject = bestSubject(in: source, subjects: data.subjects)
            let project = data.projects.first { matchesAssociation(source, names: [$0.title]) }
            let priority: TaskPriority = has(line, #"\b(urgent|high priority|important)\b"#) ? .high : has(line, #"\bmedium priority\b"#) ? .medium : has(line, #"\blow priority\b"#) ? .low : .none
            let title = cleanedTitle(line)
            let kind: CapturedItemKind = isLikelyEvent(line) ? .event : .task
            var draft = CapturedTaskDraft(title: title.isEmpty ? source : title, estimatedMinutes: duration, targetDay: targetDay, startMinutes: start, priority: priority, subjectID: subject?.id, projectID: project?.id, kind: kind, needsReview: dateMentioned && targetDay == nil)
            draft.originalText = source
            draft.isAnytime = isAnytime
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

    private static let headingPattern = #"^(today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|this weekend)(\s+(planner|plan|tasks|to-?do))?\s*:?$"#
    private static let pairRegex = try! NSRegularExpression(pattern: #"(?i)^\s*([\w ]+?)\s+and\s+([\w ]+?)\s+(tonight|today|tomorrow|this weekend)\b(.+)$"#)
    private static let numericDatePattern = #"\b(\d{1,2})[/.](\d{1,2})(?:[/.](\d{2,4}))?\b"#
    private static let namedDateBody = #"(?<![:.])\b(\d{1,2})(?:st|nd|rd|th)?\s+(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)(?:\s+(\d{4}))?\b"#
    private static let namedDatePattern = "(?i)" + namedDateBody
    private static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
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

    private static func comingSaturday(from referenceDay: LocalDay) -> LocalDay {
        let weekday = Calendar.current.component(.weekday, from: referenceDay.date()) - 1
        return referenceDay.adding(days: (6 - weekday + 7) % 7)
    }

    private static func date(in text: String, referenceDay: LocalDay) -> LocalDay? {
        let lower = text.lowercased()
        if has(lower, #"\bday after tomorrow\b"#) { return referenceDay.adding(days: 2) }
        if has(lower, #"\btomorrow\b"#) { return referenceDay.adding(days: 1) }
        if has(lower, #"\b(today|tonight)\b"#) { return referenceDay }
        if has(lower, #"\bthis weekend\b"#) { return comingSaturday(from: referenceDay) }
        if has(lower, #"\bnext weekend\b"#) { return comingSaturday(from: referenceDay).adding(days: 7) }
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
        // English names, matching the rest of the parser and the web twin.
        for (offset, weekday) in weekdayNames.enumerated() where lower.range(of: #"\b\#(weekday)\b"#, options: .regularExpression) != nil {
            let current = Calendar.current.component(.weekday, from: referenceDay.date()) - 1
            let delta = ((offset - current + 7) % 7)
            return referenceDay.adding(days: delta == 0 ? 7 : delta)
        }
        return nil
    }

    // MARK: Title cleaning

    /// Marks where a recognised token was removed, so a preposition left
    /// dangling in front of it ("due", "by", "at") can go too.
    private static let removedMark = "\u{1}"
    private static let titleTokenPatterns = [
        #"\b(?:for\s+)?(?:(?:around|about|roughly|approx(?:imately)?\.?)\s*)?\d{1,3}\s*(?:minutes?|mins?|m|hours?|hrs?|h)\b"#,
        #"\b(?:the\s+day\s+after\s+tomorrow|day\s+after\s+tomorrow|sometime\s+this\s+weekend|sometime\s+this\s+week|this\s+weekend|next\s+weekend|this\s+week|next\s+week|today|tonight|tomorrow|(?:(?:this|next)\s+)?(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b"#,
        namedDateBody,
        numericDatePattern,
        #"\b(?:urgent|high priority|medium priority|low priority|important)\b"#,
        #"\b(?:at\s*)?\d{1,2}:\d{2}\s*(?:am|pm)?\b|\b(?:at\s*)?\d{1,2}\s*(?:am|pm)\b"#,
        #"\banytime\b"#
    ]
    private static let titleFillerPattern = #"\b(?:don['’]t schedule|do not schedule|no schedule|unscheduled|around|each)\b"#
    private static let danglingPattern = #"(?:\b(?:due|by|on|at|until|before)\s+)*"# + removedMark

    private static func cleanedTitle(_ text: String) -> String {
        var result = text
        for pattern in titleTokenPatterns {
            result = result.replacingOccurrences(of: "(?i)" + pattern, with: " \(removedMark) ", options: .regularExpression)
        }
        result = result.replacingOccurrences(of: "(?i)" + titleFillerPattern, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?i)" + danglingPattern, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^[\s\-•☐□*\d.)]+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—,")))
        guard let first = result.first else { return result }
        return String(first).uppercased() + result.dropFirst()
    }

    private static func isLikelyEvent(_ text: String) -> Bool {
        let lower = text.lowercased()
        let eventWords = ["meeting", "appointment", "lesson", "class", "call", "dinner", "lunch", "exam", "match", "rehearsal"]
        return eventWords.contains(where: lower.contains) && time(in: text) != nil
    }

    // MARK: Abbreviations

    private typealias Rewrite = (regex: NSRegularExpression, replace: @Sendable ([String?]) -> String?)
    /// Not preceded or followed by a letter, digit, apostrophe or hyphen, so
    /// "c'mon", "sat-nav" and "re-read" never match inside the word.
    private static let wordStart = #"(?<![\p{L}\p{N}'’-])"#
    private static let wordEnd = #"(?![\p{L}\p{N}'’-])"#

    private static func rewrite(_ pattern: String, _ replace: @escaping @Sendable ([String?]) -> String?) -> Rewrite {
        (try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), replace)
    }
    private static func rewrite(_ pattern: String, to value: String) -> Rewrite { rewrite(pattern) { _ in value } }
    private static func minutesPhrase(_ total: Int) -> String { "\(min(total, 480)) minutes" }

    /// Full weekday name for an abbreviation, or nil when it is written in
    /// capitals (SAT, SUN), which is far more often an acronym than a day.
    private static func weekdayName(_ token: String) -> String? {
        guard token != token.uppercased() else { return nil }
        let lower = token.lowercased()
        return weekdayNames.first { $0.hasPrefix(String(lower.prefix(2))) }
    }

    /// Ordered rewrites from shorthand to the one spelling the parser reads.
    /// Each rewritten token is removed from the title later, so subject words
    /// and everything else stay exactly as typed.
    private static let rewrites: [Rewrite] = [
        rewrite(#"[ \t]+"#, to: " "),
        rewrite(#"!{2,}"#, to: " high priority "),
        rewrite(#"(^|\s)@\s*(?=\d|noon\b|midday\b)"#) { ($0[1] ?? "") + "at " },
        rewrite(#"\b12\s*(?:noon|midday)\b"#, to: "12pm"),
        rewrite(#"\b(?:noon|midday)\b"#, to: "12pm"),
        rewrite(#"\b(\d{1,2}(?::\d{2})?)\s*([ap])\.\s?m\.?(?![\p{L}\p{N}])"#) { $0[1]! + $0[2]!.lowercased() + "m" },
        // "3p" alone is a time; "3a" needs "at" or minutes because "ex 3a" is usually a question part.
        rewrite(#"(?<![\p{L}\p{N}:])(at\s+)?(\d{1,2}(?::\d{2})?)([ap])(?![\p{L}\p{N}.'’-])"#) { groups in
            let letter = groups[3]!.lowercased()
            guard groups[1] != nil || groups[2]!.contains(":") || letter == "p" else { return nil }
            return (groups[1] ?? "") + groups[2]! + letter + "m"
        },
        rewrite(#"\b(?:a\s+)?quarter\s+(?:of\s+an\s+)?hour\b"#, to: "15 minutes"),
        rewrite(#"\b(?:an|one)\s+hour\s+and\s+a\s+half\b"#, to: "90 minutes"),
        rewrite(#"\b(?:a\s+)?half\s+(?:an\s+)?hour\b"#, to: "30 minutes"),
        rewrite(#"\b(?:an|one)\s+hour\b"#, to: "60 minutes"),
        rewrite(#"\b(\d{1,2})\.(\d{1,2})\s*(?:h|hrs?|hours?)\b"#) { groups in
            Double(groups[1]! + "." + groups[2]!).map { minutesPhrase(Int(($0 * 60).rounded())) }
        },
        rewrite(#"\b(\d{1,2})\s*(?:h|hrs?|hours?)\s*(?:and\s+)?(\d{1,2})\s*(?:m|mins?|minutes?)\b"#) { minutesPhrase(Int($0[1]!)! * 60 + Int($0[2]!)!) },
        rewrite(#"\b(\d{1,2})\s*(?:h|hrs?)(\d{1,2})\b"#) { minutesPhrase(Int($0[1]!)! * 60 + Int($0[2]!)!) },
        rewrite(wordStart + #"(?:tmrw?|tmw|tmro|tomo|2moro|2mrw)"# + wordEnd, to: "tomorrow"),
        rewrite(wordStart + #"(?:tdy|2day)"# + wordEnd, to: "today"),
        rewrite(wordStart + #"(?:tonite|2nite)"# + wordEnd, to: "tonight"),
        rewrite(#"\b(?:next|nxt)\s+(?:weekend|wknd|wkend)\b"#, to: "next weekend"),
        rewrite(#"\b(?:(?:at|on|over)\s+)?(?:the|this)\s+(?:weekend|wknd|wkend)\b"#, to: "this weekend"),
        rewrite(#"(?<!next\s)(?<!last\s)(?<!this\s)(?<!every\s)"# + wordStart + #"(?:weekend|wknd|wkend)"# + wordEnd, to: "this weekend"),
        rewrite(#"\b(?:next|nxt)\s+(?:wk|week)\b"#, to: "next week"),
        rewrite(#"\bthis\s+wk\b"#, to: "this week"),
        rewrite(wordStart + #"(mon|tues?|weds?|thu(?:rs?)?|fri)\.?"# + wordEnd) { weekdayName($0[1]!) },
        // "sat" and "sun" are ordinary words too, so they need a date word before them or the end of the line.
        rewrite(#"\b(on|by|due|this|next|until|before)(\s+)(sat|sun)\.?"# + wordEnd) { groups in weekdayName(groups[3]!).map { groups[1]! + groups[2]! + $0 } },
        rewrite(#"(?<!the\s)"# + wordStart + #"(sat|sun)\.?(?=\s*[.!?:]?\s*$)"#) { weekdayName($0[1]!) },
        // Month first ("nov 3rd") becomes day first, unless a day number already precedes the month ("3 nov 4").
        rewrite(#"(?<![^\d:.]\d\s)(?<![^\d:.]\d\d\s)(?<!^\d\s)(?<!^\d\d\s)(?<!\d(?:st|nd|rd|th)\s)"# + wordStart + #"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?![\p{L}\p{N}:'’-]|\.\d)(?!\s*(?:[ap]\.?m\b|minutes?\b|mins?\b|hours?\b|hrs?\b|h\b|m\b))(?:,?\s+(\d{4})(?![\p{L}\p{N}]))?"#) { groups in
            groups[2]! + " " + groups[1]! + (groups[3].map { " " + $0 } ?? "")
        },
        rewrite(#"\basap\b"#, to: "high priority"),
        rewrite(#"\b(?:hi|high)\s+pri(?:o|ority)?\b"#, to: "high priority"),
        rewrite(#"\b(?:med|medium)\s+pri(?:o|ority)?\b"#, to: "medium priority"),
        rewrite(#"\blow\s+pri(?:o|ority)?\b"#, to: "low priority"),
        rewrite(#"\b(?:anytime|any\s+time|someday|some\s+day|no\s+date|whenever|undated)\b"#, to: "anytime")
    ]

    private static func apply(_ rewrite: Rewrite, to text: String) -> String {
        let source = text as NSString
        let matches = rewrite.regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            let groups = (0..<match.numberOfRanges).map { index -> String? in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : source.substring(with: range)
            }
            if let replacement = rewrite.replace(groups) { result.replaceCharacters(in: match.range, with: replacement) }
        }
        return result as String
    }

    private static func normalised(_ text: String, subjects: [Subject]) -> String {
        rewrites.reduce(replacingPriorityCode(in: text, subjects: subjects)) { apply($1, to: $0) }
    }

    private static let priorityCodeRegex = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}'’-])p([123])[.!]?\s*$"#, options: [.caseInsensitive])
    /// Words that make a trailing "P1" read as Paper 1 rather than a priority.
    private static let priorityCodeGuards: Set<String> = Set(subjectAliasGroups.flatMap { ($0.forms + $0.aliases).flatMap { $0.split(separator: " ").map(String.init) } })
        .union(["paper", "papers", "pp", "past", "mock", "mocks", "exam", "exams", "test", "tests", "unit", "component", "section", "q", "question", "questions", "qs", "ch", "chapter", "ex", "exercise", "pg", "page", "and", "or",
                "art", "drama", "dance", "media", "science", "sciences", "ict", "it", "re", "rs", "pe", "dt", "religious", "studies", "technology", "design"])

    /// "p1", "p2" and "p3" set the priority only as the last word, and never
    /// straight after a subject or exam word ("Maths P1" is Paper 1).
    private static func replacingPriorityCode(in text: String, subjects: [Subject]) -> String {
        let source = text as NSString
        guard let match = priorityCodeRegex.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else { return text }
        let words = tokens(text)
        if let previous = words.lastIndex(where: { $0.end <= match.range.location }) {
            if priorityCodeGuards.contains(words[previous].lower) { return text }
            if subjectCandidates(words, subjects: subjects).contains(where: { $0.last == previous }) { return text }
        }
        let level = ["1": "high", "2": "medium", "3": "low"][source.substring(with: match.range(at: 1))] ?? "high"
        return source.replacingCharacters(in: match.range, with: " \(level) priority")
    }

    // MARK: Subjects

    /// Title forms and the shorthand students use for them. A subject whose
    /// title contains a form also answers to every name in its group.
    private static let subjectAliasGroups: [(forms: [String], aliases: [String])] = [
        (["further mathematics", "further maths", "further math"], ["fm"]),
        (["mathematics", "maths", "math"], []),
        (["english language", "english lang"], ["eng lang", "lang", "english", "eng"]),
        (["english literature", "english lit"], ["eng lit", "lit"]),
        (["english"], ["eng"]),
        (["chemistry"], ["chem"]),
        (["physics"], ["phys"]),
        (["biology"], ["bio"]),
        (["geography"], ["geog", "geo"]),
        (["history"], ["hist"]),
        (["economics"], ["econ", "econs"]),
        (["psychology"], ["psych"]),
        (["sociology"], ["soc"]),
        (["politics"], ["pol"]),
        (["philosophy"], ["phil", "philo"]),
        (["music"], ["mus"]),
        (["computer science"], ["comp sci", "compsci", "cs"]),
        (["french"], ["fr"]),
        (["spanish"], ["sp", "span"]),
        (["german"], ["ger"]),
        (["latin"], ["lat"]),
        (["business"], ["bus", "biz"]),
        (["statistics"], ["stats"])
    ]
    private static let initialsConnectors: Set<String> = ["and", "of", "the", "for"]
    /// Lower-case initials that are ordinary words; typed in capitals they still count.
    private static let initialsStoplist: Set<String> = ["re", "am", "pm", "to", "in", "on", "at", "by", "of", "it", "is", "as", "an", "or", "do", "go", "me", "my", "no", "so", "up", "we", "us", "be", "he", "if",
                                                        "id", "ok", "hi", "oh", "ah", "eh", "ex", "ch", "pg", "pp", "qs", "hw", "ws", "nb", "eg", "ie", "vs", "mr", "ms", "dr", "st"]

    private struct Word { let text: String; let lower: String; let start: Int; let end: Int }
    private struct SubjectCandidate { let index: Int; let first: Int; let last: Int; let length: Int; let extra: Int }
    private static let wordRegex = try! NSRegularExpression(pattern: #"[\p{L}\p{N}'’-]+"#)
    private static let edgeMarks: Set<unichar> = [39, 45, 8217]

    /// Words with UTF-16 offsets (shared with JavaScript string indices).
    /// Edge apostrophes and hyphens and a possessive "'s" are not part of the word.
    private static func tokens(_ text: String) -> [Word] {
        let source = text as NSString
        return wordRegex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            var start = match.range.location, end = match.range.location + match.range.length
            while start < end, edgeMarks.contains(source.character(at: start)) { start += 1 }
            while end > start, edgeMarks.contains(source.character(at: end - 1)) { end -= 1 }
            if end - start > 2, [115, 83].contains(source.character(at: end - 1)), [39, 8217].contains(source.character(at: end - 2)) { end -= 2 }
            guard end > start else { return nil }
            let word = source.substring(with: NSRange(location: start, length: end - start))
            return Word(text: word, lower: word.lowercased(), start: start, end: end)
        }
    }

    private static func isLetters(_ text: String) -> Bool { !text.isEmpty && text.allSatisfy(\.isLetter) }

    private static func subjectNames(_ title: String) -> (words: [String], names: [(words: [String], extra: Int)]) {
        let titleWords = tokens(title).map(\.lower)
        guard !titleWords.isEmpty else { return ([], []) }
        var names: [(words: [String], extra: Int)] = [(titleWords, 0)]
        func contains(_ part: [String]) -> Bool {
            guard !part.isEmpty, part.count <= titleWords.count else { return false }
            return (0...(titleWords.count - part.count)).contains { Array(titleWords[$0..<($0 + part.count)]) == part }
        }
        for group in subjectAliasGroups {
            let extras = group.forms.map { tokens($0).map(\.lower) }.filter(contains).map { titleWords.count - $0.count }
            guard let extra = extras.min() else { continue }
            names += (group.forms + group.aliases).map { (tokens($0).map(\.lower), extra) }
        }
        return (titleWords, names)
    }

    private static func subjectCandidates(_ words: [Word], subjects: [Subject]) -> [SubjectCandidate] {
        var candidates: [SubjectCandidate] = []
        for (index, subject) in subjects.enumerated() {
            let (titleWords, names) = subjectNames(subject.title)
            guard !titleWords.isEmpty else { continue }
            for name in names where !name.words.isEmpty && name.words.count <= words.count {
                for first in 0...(words.count - name.words.count) where (0..<name.words.count).allSatisfy({ words[first + $0].lower == name.words[$0] }) {
                    let last = first + name.words.count - 1
                    candidates.append(SubjectCandidate(index: index, first: first, last: last, length: words[last].end - words[first].start, extra: name.extra))
                }
            }
            if titleWords.count == 1 {
                // "chem" or "hist": four or more letters that begin a one-word title.
                let title = titleWords[0]
                for (position, word) in words.enumerated() where word.lower.count >= 4 && word.lower.count < title.count && isLetters(word.lower) && title.hasPrefix(word.lower) {
                    candidates.append(SubjectCandidate(index: index, first: position, last: position, length: word.end - word.start, extra: 0))
                }
            } else {
                // "CS", "DT", "PE": initials of a multi-word title.
                let initials = String(titleWords.filter { !initialsConnectors.contains($0) }.compactMap(\.first))
                guard initials.count >= 2 else { continue }
                for (position, word) in words.enumerated() where word.lower == initials && isLetters(word.text) {
                    let capitals = word.text == word.text.uppercased()
                    guard capitals || !initialsStoplist.contains(word.lower) else { continue }
                    if ["am", "pm"].contains(word.lower), position > 0, words[position - 1].text.allSatisfy(\.isNumber) { continue }
                    candidates.append(SubjectCandidate(index: index, first: position, last: position, length: word.end - word.start, extra: 0))
                }
            }
        }
        return candidates
    }

    /// The most specific subject named in the text: the longest matched text,
    /// then the title with the fewest extra words, then the first listed.
    private static func bestSubject(in text: String, subjects: [Subject]) -> Subject? {
        let best = subjectCandidates(tokens(text), subjects: subjects).min { lhs, rhs in
            (-lhs.length, lhs.extra, lhs.index) < (-rhs.length, rhs.extra, rhs.index)
        }
        return best.map { subjects[$0.index] }
    }
}
