import AppKit
import Foundation
import LifeBoardCore
import UserNotifications

final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationCoordinator()
    private let center = UNUserNotificationCenter.current()
    private let refreshLock = NSLock()
    private var generation = 0
    // Requests and their content/trigger are immutable after construction.
    private struct ReminderBatch: @unchecked Sendable { let requests: [UNNotificationRequest] }
    private func nextGeneration() -> Int { refreshLock.lock(); defer { refreshLock.unlock() }; generation += 1; return generation }

    private override init() {
        super.init()
        center.delegate = self
    }

    func requestAndRefresh(_ data: LifeBoardData) {
        guard ProcessInfo.processInfo.environment["LIFEBOARD_DATA_PATH"] == nil else { return }
        let expected = nextGeneration()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            self.refreshLock.lock()
            let current = self.generation == expected
            self.refreshLock.unlock()
            guard granted, current else { return }
            self.refresh(data)
        }
    }

    func refresh(_ data: LifeBoardData) {
        guard ProcessInfo.processInfo.environment["LIFEBOARD_DATA_PATH"] == nil else { return }
        // Compare only reminder inputs. Notes, progress and unrelated records do
        // not rebuild notifications or remove reminders owned by other apps.
        let batch = ReminderBatch(requests: reminderRequests(data))
        let expected = nextGeneration()
        center.getPendingNotificationRequests { pending in
            self.refreshLock.lock(); defer { self.refreshLock.unlock() }
            guard self.generation == expected else { return }
            let desired = batch.requests
            let old = Dictionary(uniqueKeysWithValues: pending.filter { $0.identifier.hasPrefix("lifeboard-") }.map { ($0.identifier, $0) })
            let new = Dictionary(uniqueKeysWithValues: desired.map { ($0.identifier, $0) })
            self.center.removePendingNotificationRequests(withIdentifiers: old.keys.filter { new[$0] == nil })
            for request in desired where old[request.identifier].map({ self.sameReminder($0, request) }) != true { self.center.add(request) }
        }
    }

    private func reminderRequests(_ data: LifeBoardData) -> [UNNotificationRequest] {
        var requests: [UNNotificationRequest] = []
        let now = Date.now
        if data.settings.notificationsScheduledItems {
            for task in data.tasks where !task.isCompleted && !task.isArchived {
                guard let day = task.scheduledDay, let minutes = task.scheduledStartMinutes else { continue }
                if let request = makeReminder(title: task.title, body: "Scheduled in \(data.settings.notificationLeadMinutes) minutes", date: notificationDate(day: day, minutes: minutes, lead: data.settings.notificationLeadMinutes), id: "lifeboard-task-\(task.id)", url: "\(LifeBoardEnvironment.urlScheme)://task/\(task.id)", now: now) { requests.append(request) }
            }
            for event in data.events {
                if let request = makeReminder(title: event.title, body: "Starts in \(data.settings.notificationLeadMinutes) minutes", date: notificationDate(day: event.day, minutes: event.startMinutes, lead: data.settings.notificationLeadMinutes), id: "lifeboard-event-\(event.id)", url: "\(LifeBoardEnvironment.urlScheme)://calendar", now: now) { requests.append(request) }
            }
        }
        if data.settings.notificationsDeadlines {
            for task in data.tasks where !task.isCompleted && !task.isArchived {
                guard let day = task.dueDay else { continue }
                if let request = makeReminder(title: task.title, body: "Due today", date: notificationDate(day: day, minutes: 9 * 60, lead: 0), id: "lifeboard-deadline-\(task.id)", url: "\(LifeBoardEnvironment.urlScheme)://task/\(task.id)", now: now) { requests.append(request) }
            }
        }
        if data.settings.notificationsFocus, let active = data.activeFocus, active.pausedAt == nil {
            let end = active.startedAt.addingTimeInterval(Double(active.plannedMinutes * 60) + active.pausedSeconds)
            if let request = makeReminder(title: active.kind == .shortBreak ? "Break complete" : "Focus complete", body: active.taskTitle, date: end, id: "lifeboard-focus", url: active.taskID.map { "\(LifeBoardEnvironment.urlScheme)://task/\($0)" } ?? "\(LifeBoardEnvironment.urlScheme)://focus", now: now) { requests.append(request) }
        }
        // iOS/macOS has a finite pending-request budget; nearest reminders first.
        let sorted = requests.sorted { left, right in
            let lhs = (left.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? Date.distantFuture
            let rhs = (right.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? Date.distantFuture
            return lhs < rhs
        }
        return Array(sorted.prefix(60))
    }

    private func sameReminder(_ a: UNNotificationRequest, _ b: UNNotificationRequest) -> Bool {
        a.content.title == b.content.title && a.content.body == b.content.body && (a.content.userInfo["url"] as? String) == (b.content.userInfo["url"] as? String) && (a.trigger as? UNCalendarNotificationTrigger)?.dateComponents == (b.trigger as? UNCalendarNotificationTrigger)?.dateComponents
    }

    func scheduleFocus(_ active: ActiveFocusSession, enabled: Bool) {
        guard ProcessInfo.processInfo.environment["LIFEBOARD_DATA_PATH"] == nil else { return }
        let expected = nextGeneration()
        center.removePendingNotificationRequests(withIdentifiers: ["lifeboard-focus"])
        guard enabled, active.pausedAt == nil else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            self.refreshLock.lock(); defer { self.refreshLock.unlock() }
            guard granted, self.generation == expected else { return }
            self.enqueueFocus(active)
        }
    }

    func cancelFocus() { _ = nextGeneration(); center.removePendingNotificationRequests(withIdentifiers: ["lifeboard-focus"]) }

    private func enqueueFocus(_ active: ActiveFocusSession) {
        let remaining = max(1, Double(active.plannedMinutes * 60) - active.elapsedSeconds())
        let content = UNMutableNotificationContent()
        content.title = active.kind == .shortBreak ? "Break complete" : "Focus complete"
        content.body = active.kind == .shortBreak ? "Ready to continue?" : active.taskTitle
        content.sound = .default
        content.userInfo = ["url": active.taskID.map { "\(LifeBoardEnvironment.urlScheme)://task/\($0)" } ?? "\(LifeBoardEnvironment.urlScheme)://focus"]
        center.add(UNNotificationRequest(identifier: "lifeboard-focus", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false)))
    }

    private func makeReminder(title: String, body: String, date: Date, id: String, url: String, now: Date) -> UNNotificationRequest? {
        guard date > now else { return nil }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default; content.userInfo = ["url": url]
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }

    private func notificationDate(day: LocalDay, minutes: Int, lead: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day.date())?.addingTimeInterval(Double(-lead * 60)) ?? day.date()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: raw) else { return }
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}
