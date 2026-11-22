import Foundation
import Darwin
import CryptoKit

public struct WidgetAgendaItem: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var startMinutes: Int
    public var endMinutes: Int
    public var isTask: Bool
}

public struct WidgetToDoItem: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var dueDay: LocalDay?
    public var completionPercent: Double
}

public struct LifeBoardWidgetSnapshot: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var agenda: [WidgetAgendaItem]
    public var remainingToDos: Int
    public var toDos: [WidgetToDoItem]
    public var activeFocusTitle: String?
    public var activeFocusEnd: Date?

    public init(data: LifeBoardData, now: Date = .now) {
        let today = LocalDay(now)
        let currentMinutes = Calendar.current.component(.hour, from: now) * 60 + Calendar.current.component(.minute, from: now)
        let taskItems = data.tasks.compactMap { task -> WidgetAgendaItem? in
            guard let span = SchedulingEngine.taskSegment(task, on: today) else { return nil }
            return WidgetAgendaItem(id: task.id, title: task.title, startMinutes: span.start, endMinutes: span.end, isTask: true)
        }
        let eventItems = data.events.filter { $0.day == today }.map { WidgetAgendaItem(id: $0.id, title: $0.title, startMinutes: $0.startMinutes, endMinutes: $0.endMinutes, isTask: false) }
        let externalItems = data.externalEvents.compactMap { event -> WidgetAgendaItem? in
            guard let span = SchedulingEngine.externalSegment(event, on: today) else { return nil }
            let hash = Array(SHA256.hash(data: Data(event.id.utf8)))
            let id = UUID(uuid: (hash[0],hash[1],hash[2],hash[3],hash[4],hash[5],hash[6],hash[7],hash[8],hash[9],hash[10],hash[11],hash[12],hash[13],hash[14],hash[15]))
            return WidgetAgendaItem(id: id, title: event.isAllDay ? "All day · " + event.title : event.title, startMinutes: span.start, endMinutes: span.end, isTask: false)
        }
        agenda = (taskItems + eventItems + externalItems).filter { $0.endMinutes >= currentMinutes }.sorted { $0.startMinutes < $1.startMinutes }
        let openTasks = data.tasks.filter { !$0.isCompleted && !$0.isArchived }
        remainingToDos = openTasks.count
        toDos = openTasks.sorted { left, right in
            let leftDue = left.dueDay ?? LocalDay(year: 9999, month: 12, day: 31)
            let rightDue = right.dueDay ?? LocalDay(year: 9999, month: 12, day: 31)
            if leftDue != rightDue { return leftDue < rightDue }
            let rank: [TaskPriority: Int] = [.high: 0, .medium: 1, .low: 2, .none: 3]
            if left.priority != right.priority { return (rank[left.priority] ?? 3) < (rank[right.priority] ?? 3) }
            return left.sortOrder < right.sortOrder
        }.prefix(3).map { WidgetToDoItem(id: $0.id, title: $0.title, dueDay: $0.dueDay, completionPercent: $0.completionPercent ?? 0) }
        if let active = data.activeFocus {
            activeFocusTitle = active.kind == .shortBreak ? "Short break" : active.taskTitle
            activeFocusEnd = active.pausedAt == nil ? active.startedAt.addingTimeInterval(active.pausedSeconds + Double(active.plannedMinutes * 60)) : nil
        } else {
            activeFocusTitle = nil
            activeFocusEnd = nil
        }
        generatedAt = now
    }

    private enum CodingKeys: String, CodingKey { case generatedAt, agenda, remainingToDos, toDos, activeFocusTitle, activeFocusEnd }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try values.decode(Date.self, forKey: .generatedAt)
        agenda = try values.decode([WidgetAgendaItem].self, forKey: .agenda)
        remainingToDos = try values.decode(Int.self, forKey: .remainingToDos)
        toDos = try values.decodeIfPresent([WidgetToDoItem].self, forKey: .toDos) ?? []
        activeFocusTitle = try values.decodeIfPresent(String.self, forKey: .activeFocusTitle)
        activeFocusEnd = try values.decodeIfPresent(Date.self, forKey: .activeFocusEnd)
    }
}

public enum LifeBoardSharedStore {
    public static let appGroupIdentifier = LifeBoardEnvironment.appGroupIdentifier

    /// The extension has a read-only entitlement for this exact folder.
    public static func directory(fileManager: FileManager = .default) -> URL { LifeBoardEnvironment.supportDirectory }

    public static func snapshotURL(fileManager: FileManager = .default) -> URL {
        directory(fileManager: fileManager).appendingPathComponent("WidgetSnapshot.json")
    }

    @discardableResult public static func writeSnapshot(_ data: LifeBoardData, fileManager: FileManager = .default) throws -> Bool {
        let url = snapshotURL(fileManager: fileManager)
        try LifeBoardPrivateFiles.directory(url.deletingLastPathComponent())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let snapshot = LifeBoardWidgetSnapshot(data: data)
        if var previous = readSnapshot(fileManager: fileManager) {
            previous.generatedAt = snapshot.generatedAt
            if previous == snapshot { return false }
        }
        try LifeBoardPrivateFiles.write(encoder.encode(snapshot), to: url)
        return true
    }

    public static func readSnapshot(fileManager: FileManager = .default) -> LifeBoardWidgetSnapshot? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LifeBoardWidgetSnapshot.self, from: Data(contentsOf: snapshotURL(fileManager: fileManager)))
    }
}
