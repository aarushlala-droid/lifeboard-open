import Foundation

public struct TaskClassification: Sendable {
    public let carryOver: Bool
    public let overdue: Bool
    public let today: Bool
    public let tomorrow: Bool
    public let upcoming: Bool
    public let anytime: Bool
    public let todayUntimed: Bool
    public init(_ task: TaskItem, day: LocalDay = .today) {
        let active = !task.isCompleted && !task.isArchived
        carryOver = active && task.scheduledDay.map { $0 < day } == true
        overdue = active && task.dueDay.map { $0 < day } == true
        today = active && (carryOver || overdue || task.scheduledDay == day || task.dueDay == day)
        tomorrow = active && !today && (task.scheduledDay == day.adding(days: 1) || task.dueDay == day.adding(days: 1))
        upcoming = active && !today && !tomorrow && (task.scheduledDay != nil || task.dueDay != nil)
        anytime = active && task.scheduledDay == nil && task.dueDay == nil
        todayUntimed = today && !carryOver && !overdue && task.scheduledStartMinutes == nil
    }
}
