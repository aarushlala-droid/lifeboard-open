import Foundation

/// A synthetic student week, relative to today. It contains no personal data
/// and exists so LifeBoard Preview can be tried without touching real plans.
public enum SampleData {
    public static func studentWeek(today: LocalDay = .today, calendar: Calendar = .current) -> LifeBoardData {
        var data = LifeBoardData.seeded()
        let colours = ["blue", "orange", "pink", "green", "teal", "indigo", "purple", "brown", "mint"]
        for index in data.subjects.indices { data.subjects[index].colour = colours[index % colours.count] }
        data.subjects[0].topics = ["Quadratics", "Vectors", "Probability"].map(Topic.init)
        data.subjects[4].topics = ["Rates of reaction", "Organic chemistry"].map(Topic.init)
        data.projects[0].milestones = [ProjectMilestone(title: "Coursework draft", targetDay: today.adding(days: 5))]
        let maths = data.subjects[0].id, english = data.subjects[1].id, chemistry = data.subjects[4].id, history = data.subjects[7].id, physics = data.subjects[5].id
        func task(_ title: String, _ minutes: Int = 30, subject: UUID? = nil, due: Int? = nil, planned: Int? = nil, at: Int? = nil, done: Bool = false, priority: TaskPriority = .none) -> TaskItem {
            var item = TaskItem(title: title)
            item.estimatedMinutes = minutes; item.subjectID = subject; item.priority = priority
            item.dueDay = due.map { today.adding(days: $0) }
            item.scheduledDay = planned.map { today.adding(days: $0) }
            if let at, item.scheduledDay != nil { item.scheduledStartMinutes = at; item.scheduledDurationMinutes = minutes }
            if done { item.isCompleted = true; item.completedAt = .now.addingTimeInterval(-1800); item.completionPercent = 100 }
            return item
        }
        var worksheet = task("Chemistry worksheet: rates of reaction", 40, subject: chemistry, due: 1, planned: 0)
        worksheet.subtasks = [TaskSubtask(title: "Questions 1 to 6"), TaskSubtask(title: "Graph for question 7"), TaskSubtask(title: "Check answers")]
        worksheet.subtasks?[0].isCompleted = true
        var essay = task("English essay plan", 45, subject: english, due: 3, priority: .high)
        essay.notes = "Theme: ambition in Macbeth. Three paragraphs, quotes from Acts 1 and 3."
        var vocab = task("Spanish vocabulary review", 15, planned: 0)
        vocab.recurrence = TaskRecurrence(frequency: "daily", interval: 1, nextDay: today)
        var reading = task("Read history chapter 4", 30, subject: history, planned: 0)
        reading.completionPercent = 40
        data.tasks = [
            task("Hand in physics practical write-up", 20, subject: physics, due: -1),
            task("Maths homework: vectors exercise 5B", 35, subject: maths, planned: -1),
            worksheet, vocab, reading,
            task("Past paper question: probability", 45, subject: maths, planned: 0, at: 17 * 60 + 30),
            task("Revise organic chemistry flashcards", 25, subject: chemistry, planned: 0, at: 19 * 60),
            essay,
            task("Book a library study room", 5, planned: 1),
            task("Print coursework sources", 10, planned: 2),
            task("Biology mind map", 40, subject: data.subjects[3].id, due: 6),
            task("Tidy revision folder", 20),
            task("Email drama teacher about rehearsal", 5),
            task("Look at university open days", 30, priority: .low),
            task("French listening practice", 20, done: true),
            task("Pack PE kit", 5, done: true)
        ]
        data.tasks[14].scheduledDay = today; data.tasks[15].scheduledDay = today
        data.events = [
            CalendarEvent(title: "Drama rehearsal", day: today.adding(days: 1), startMinutes: 16 * 60, endMinutes: 17 * 60 + 30),
            CalendarEvent(title: "Revision group", day: today.adding(days: 3), startMinutes: 18 * 60, endMinutes: 19 * 60)
        ]
        data.events[0].location = "Studio"
        // A read-only connected calendar, as macOS Internet Accounts would supply it.
        let lessons = [("Maths", 9 * 60), ("English", 10 * 60 + 5), ("Chemistry", 11 * 60 + 25), ("History", 13 * 60 + 30), ("Physics", 14 * 60 + 35)]
        var external: [ExternalCalendarEvent] = []
        for offset in -3...10 {
            let day = today.adding(days: offset, calendar: calendar)
            let weekday = calendar.component(.weekday, from: day.date(calendar: calendar))
            guard (2...6).contains(weekday) else { continue }
            for (number, lesson) in lessons.enumerated() where (number + weekday) % 4 != 0 {
                let start = calendar.date(bySettingHour: lesson.1 / 60, minute: lesson.1 % 60, second: 0, of: day.date(calendar: calendar)) ?? day.date()
                external.append(ExternalCalendarEvent(id: "sample-\(day.id)-\(number)", calendarID: "sample-timetable", calendarTitle: "School timetable", title: lesson.0, day: day, startMinutes: lesson.1, endMinutes: lesson.1 + 60, isAllDay: false, location: "Room \(10 + number)", startInstant: start, endInstant: start.addingTimeInterval(3600), timeZoneIdentifier: calendar.timeZone.identifier))
            }
        }
        let trip = today.adding(days: 4, calendar: calendar)
        let tripStart = calendar.startOfDay(for: trip.date(calendar: calendar))
        external.append(ExternalCalendarEvent(id: "sample-trip", calendarID: "sample-timetable", calendarTitle: "School timetable", title: "Geography field trip", day: trip, startMinutes: 0, endMinutes: 1440, isAllDay: true, startInstant: tripStart, endInstant: calendar.date(byAdding: .day, value: 1, to: tripStart), timeZoneIdentifier: calendar.timeZone.identifier))
        data.externalEvents = external
        var test = YearMarker(title: "Chemistry test", startDay: today.adding(days: 6)); test.category = "Test"; test.subjectID = chemistry
        var mocks = YearMarker(title: "Mock exams", startDay: today.adding(days: 30)); mocks.endDay = today.adding(days: 39); mocks.category = "Test"
        data.yearMarkers = [test, mocks]
        data.activity = [ActivityRecord(kind: .taskCompleted, title: "Completed \"Pack PE kit\"")]
        data.settings.hasCompletedOnboarding = true
        data.settings.selectedExternalCalendarIDs = []
        return data
    }
}
