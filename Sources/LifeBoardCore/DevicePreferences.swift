import Foundation

/// Retain legacy schema-3 fields for old backups, but keep device choices local.
public struct DevicePreferences: Codable, Sendable {
    public var automaticICloudBackup: Bool
    public var notificationsScheduledItems: Bool
    public var notificationsDeadlines: Bool
    public var notificationsFocus: Bool
    public var notificationLeadMinutes: Int
    public var selectedExternalCalendarIDs: [String]
    public var lastExternalCalendarRefresh: Date?
    public init(_ settings: AppSettings) {
        automaticICloudBackup = settings.automaticICloudBackup
        notificationsScheduledItems = settings.notificationsScheduledItems
        notificationsDeadlines = settings.notificationsDeadlines
        notificationsFocus = settings.notificationsFocus
        notificationLeadMinutes = settings.notificationLeadMinutes
        selectedExternalCalendarIDs = settings.selectedExternalCalendarIDs
        lastExternalCalendarRefresh = settings.lastExternalCalendarRefresh
    }
    public func apply(to settings: inout AppSettings) {
        settings.automaticICloudBackup = automaticICloudBackup
        settings.notificationsScheduledItems = notificationsScheduledItems
        settings.notificationsDeadlines = notificationsDeadlines
        settings.notificationsFocus = notificationsFocus
        settings.notificationLeadMinutes = notificationLeadMinutes
        settings.selectedExternalCalendarIDs = selectedExternalCalendarIDs
        settings.lastExternalCalendarRefresh = lastExternalCalendarRefresh
    }
    public static func sharedProjection(_ data: LifeBoardData) -> LifeBoardData {
        var projected = data
        DevicePreferences(AppSettings()).apply(to: &projected.settings)
        projected.settings.lastICloudBackup = nil
        return projected
    }
}
