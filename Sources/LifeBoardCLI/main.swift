import Foundation
import LifeBoardCore

struct CLI {
    let arguments: [String]
    let repository: LifeBoardRepository

    init(arguments: [String]) {
        self.arguments = arguments
        let override = ProcessInfo.processInfo.environment["LIFEBOARD_DATA_PATH"].map { URL(fileURLWithPath: $0) }
        repository = LifeBoardRepository(fileURL: override)
    }

    func value(_ flag: String) -> String? { guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }; return arguments[i + 1] }

    func run() throws {
        guard arguments.count >= 2 else { return help() }
        let group = arguments[0], action = arguments[1]
        if group == "data", action == "path" { print(repository.fileURL.path); return }
        var data = try repository.loadThrowing()
        switch (group, action) {
        case ("import", _):
            let json: String
            if let path = value("--file") { json = try String(contentsOfFile: path, encoding: .utf8) }
            else if let inline = value("--json") { json = inline }
            else if action != "-" { json = action }
            else { json = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
            let payloads = try repository.decodePayloads(json)
            for payload in payloads { data.tasks.append(try repository.makeTask(from: payload, in: data)) }
            try persist(data)
            print("imported \(payloads.count) task\(payloads.count == 1 ? "" : "s")")
        case ("tasks", "list"):
            let rows = data.tasks.filter { !$0.isArchived }.map { ["id": $0.id.uuidString, "title": $0.title, "completed": String($0.isCompleted), "scheduledDate": $0.scheduledDay?.id ?? "", "time": $0.scheduledStartMinutes.map(time) ?? ""] }
            printJSON(rows)
        case ("tasks", "import"):
            let json: String
            if let path = value("--file") { json = try String(contentsOfFile: path, encoding: .utf8) }
            else if let inline = value("--json") { json = inline }
            else { json = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
            let payloads = try repository.decodePayloads(json)
            for payload in payloads { data.tasks.append(try repository.makeTask(from: payload, in: data)) }
            try persist(data)
            print("imported \(payloads.count) task\(payloads.count == 1 ? "" : "s")")
        case ("task", "add"):
            guard let title = value("--title"), !title.isEmpty else { throw LifeBoardError.invalidPayload }
            var payload = TaskImportPayload(title: title); payload.notes = value("--notes"); payload.estimatedMinutes = value("--estimated").flatMap(Int.init); payload.dueDate = value("--due"); payload.scheduledDate = value("--scheduled-date"); payload.scheduledStart = value("--time"); payload.priority = value("--priority"); payload.subject = value("--subject"); payload.topic = value("--topic"); payload.project = value("--project")
            let task = try repository.makeTask(from: payload, in: data); data.tasks.append(task); try persist(data); print(task.id.uuidString)
        case ("task", "complete"):
            guard let id = value("--id").flatMap(UUID.init(uuidString:)), let index = data.tasks.firstIndex(where: { $0.id == id }) else { throw LifeBoardError.itemNotFound }
            data.tasks[index].isCompleted = true; data.tasks[index].completedAt = .now
            let task = data.tasks[index]; data.activity.insert(ActivityRecord(kind: .taskCompleted, title: "Completed \"\(task.title)\"", subjectID: task.subjectID, topicID: task.topicID, projectID: task.projectID), at: 0)
            if let sid = task.subjectID, let subjectIndex = data.subjects.firstIndex(where: { $0.id == sid }) {
                data.subjects[subjectIndex].lastActivity = .now
                if let tid = task.topicID, let topicIndex = data.subjects[subjectIndex].topics.firstIndex(where: { $0.id == tid }) { data.subjects[subjectIndex].topics[topicIndex].lastActivity = .now }
            }
            if let pid = task.projectID, let projectIndex = data.projects.firstIndex(where: { $0.id == pid }) { data.projects[projectIndex].lastActivity = .now }
            RecurrenceEngine.appendNextOccurrence(after: data.tasks[index], in: &data)
            try persist(data); print("completed")
        case ("task", "delete"):
            guard let id = value("--id").flatMap(UUID.init(uuidString:)), data.tasks.contains(where: { $0.id == id }) else { throw LifeBoardError.itemNotFound }
            if let index = data.tasks.firstIndex(where: { $0.id == id }) { data.tasks[index].isArchived = true; data.tasks[index].archivedAt = .now; data.tasks[index].modifiedAt = .now }; try persist(data); print("moved to trash")
        case ("task", "restore"):
            guard let id = value("--id").flatMap(UUID.init(uuidString:)), let index = data.tasks.firstIndex(where: { $0.id == id && $0.isArchived }) else { throw LifeBoardError.itemNotFound }
            data.tasks[index].isArchived = false; data.tasks[index].archivedAt = nil; data.tasks[index].modifiedAt = .now; try persist(data); print("restored")
        case ("trash", "list"):
            printJSON(data.tasks.filter(\.isArchived).map { ["id": $0.id.uuidString, "title": $0.title] })
        case ("task", "update"):
            guard let id = value("--id").flatMap(UUID.init(uuidString:)), let index = data.tasks.firstIndex(where: { $0.id == id }) else { throw LifeBoardError.itemNotFound }
            if let title = value("--title") { data.tasks[index].title = title }
            if let date = value("--scheduled-date") { guard let day = LocalDay(iso: date) else { throw LifeBoardError.invalidPayload }; data.tasks[index].scheduledDay = day }
            if let raw = value("--time") { guard let minute = parseTime(raw) else { throw LifeBoardError.invalidPayload }; data.tasks[index].scheduledStartMinutes = minute }
            if arguments.contains("--unschedule-time") { data.tasks[index].scheduledStartMinutes = nil }
            if arguments.contains("--inbox") { data.tasks[index].scheduledDay = nil; data.tasks[index].scheduledStartMinutes = nil }
            data.tasks[index].modifiedAt = .now; try persist(data); print("updated")
        case ("projects", "list"):
            printJSON(data.projects.map { ["id": $0.id.uuidString, "title": $0.title, "status": $0.status.rawValue, "progress": String(Int($0.progress))] })
        case ("subjects", "list"):
            printJSON(data.subjects.map { ["id": $0.id.uuidString, "title": $0.title, "confidence": String($0.confidence), "progress": String(Int($0.progress))] })
        case ("progress", "add"):
            guard let id = value("--project-id").flatMap(UUID.init(uuidString:)), let text = value("--text"), let index = data.projects.firstIndex(where: { $0.id == id }) else { throw LifeBoardError.itemNotFound }
            data.projects[index].updates.insert(ProgressUpdate(text: text), at: 0); try persist(data); print("added")
        case ("milestone", "add"):
            guard let id = value("--project-id").flatMap(UUID.init(uuidString:)), let title = value("--title"), let day = value("--date").flatMap(LocalDay.init(iso:)), let index = data.projects.firstIndex(where: { $0.id == id }) else { throw LifeBoardError.invalidPayload }
            data.projects[index].milestones.append(ProjectMilestone(title: title, targetDay: day)); try persist(data); print("added")
        case ("calendar", "today"):
            printCalendar(data, day: .today)
        case ("calendar", "day"):
            guard let day = value("--date").flatMap(LocalDay.init(iso:)) else { throw LifeBoardError.invalidPayload }; printCalendar(data, day: day)
        case ("events", "list"):
            let rows = data.events.map { ["id": $0.id.uuidString, "title": $0.title, "date": $0.day.id, "start": time($0.startMinutes), "end": time($0.endMinutes)] }; printJSON(rows)
        case ("event", "delete"):
            guard let id = value("--id").flatMap(UUID.init(uuidString:)), data.events.contains(where: { $0.id == id }) else { throw LifeBoardError.itemNotFound }
            data.events.removeAll { $0.id == id }; try persist(data); print("deleted")
        case ("activity", "delete"):
            guard let id = value("--id").flatMap(UUID.init(uuidString:)), data.activity.contains(where: { $0.id == id }) else { throw LifeBoardError.itemNotFound }
            data.activity.removeAll { $0.id == id }; try persist(data); print("deleted")
        default: help()
        }
    }

    func printCalendar(_ data: LifeBoardData, day: LocalDay) {
        let tasks = data.tasks.filter { !$0.isCompleted && !$0.isArchived && $0.scheduledDay == day }.map { ["id": $0.id.uuidString, "title": $0.title, "time": $0.scheduledStartMinutes.map(time) ?? "unscheduled"] }
        printJSON(tasks)
    }
    func printJSON(_ object: Any) { if let bytes = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: bytes, as: UTF8.self)) } }
    func persist(_ data: LifeBoardData) throws {
        let durable = try repository.saveReturning(data)
        if ProcessInfo.processInfo.environment["LIFEBOARD_DATA_PATH"] == nil { _ = try? LifeBoardSharedStore.writeSnapshot(durable) }
    }
    func help() { print("lifeboard import '<json or JSON array>' | import --file tasks.json · task add|update|complete|delete|restore · trash list · tasks list|import · events list · event delete · activity delete · projects list · subjects list · progress add · milestone add · calendar today|day") }
    func parseTime(_ value: String) -> Int? { let parts = value.split(separator: ":").compactMap { Int($0) }; guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }; return parts[0] * 60 + parts[1] }
    func time(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}

do {
    try CLI(arguments: Array(CommandLine.arguments.dropFirst())).run()
    fflush(stdout)
    exit(0)
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
